# Zabbix 監視 (BwAI Forensic local-server) 運用手順

CT 200 `local-server` の法執行対応ログ系統を Zabbix で監視するトリガー一覧と対応 runbook。

Zabbix server: CT 201 (`http://192.168.11.6/`, テンプレート **"BwAI Forensic local-server"**)
設計全体: [`../design/logging-compliance.md`](../design/logging-compliance.md) §9

## テンプレート / アイテム一覧

| アイテム | Zabbix key | 値型 | 間隔 | 保存 |
|---|---|---|---|---|
| rsyslog active state | `systemd.unit.info[rsyslog.service,ActiveState]` | 文字列 | 60s | 7d |
| nfcapd active state | `systemd.unit.info[nfcapd.service,ActiveState]` | 文字列 | 60s | 7d |
| gcs timer active state | `systemd.unit.info[gcs-forensic-push.timer,ActiveState]` | 文字列 | 60s | 7d |
| GCS errors.log size | `vfs.file.size[/mnt/data/.gcs-state/errors.log]` | 整数 | 60s | 30d |
| GCS last-push.json mtime | `vfs.file.time[/mnt/data/.gcs-state/last-push.json,modify]` | UNIX epoch | 60s | 30d |

加えて **Linux by Zabbix agent** 標準テンプレートから `/mnt/data` の使用率・inode・read-only 状態を取得。

### ホストマクロ (local-server)

| マクロ | 値 | 意味 |
|---|---|---|
| `{$VFS.FS.PUSED.MAX.WARN:"/mnt/data"}` | 50 | Warning 閾値 (%) |
| `{$VFS.FS.PUSED.MAX.CRIT:"/mnt/data"}` | 80 | High 閾値 (%) |

## トリガー一覧と対応

### 1. rsyslog not active on local-server (High)

- 条件: `systemd.unit.info[rsyslog.service,ActiveState]` != `"active"`
- **即応**: ログ集約が全面停止。全送信元からのログが CT 200 ファイルに落ちない

対応:
```bash
ssh root@192.168.11.2 systemctl status rsyslog
ssh root@192.168.11.2 "journalctl -u rsyslog -n 50; rsyslogd -N1"
ssh root@192.168.11.2 systemctl restart rsyslog
```

配信側 (r1/r2/r3) の TCP 接続は自動再接続されるが、`persistent-queue` が大きく貯まる可能性があるため復旧後に送信元の `show log` で backlog 確認。

### 2. nfcapd not active on local-server (High)

- 条件: `systemd.unit.info[nfcapd.service,ActiveState]` != `"active"`
- **即応**: NetFlow 受信停止。r3 が送出した v9 パケットは UDP で drop される (UDP は再送なし)

対応:
```bash
ssh root@192.168.11.2 systemctl status nfcapd
ssh root@192.168.11.2 "ss -unlp | grep :2055; pgrep -a nfcapd"
ssh root@192.168.11.2 systemctl restart nfcapd
```

`Address already in use` → Debian パッケージの SysV init 経由で別インスタンスが起動している可能性。`systemctl stop nfdump; pkill -9 nfcapd; systemctl start nfcapd`。

### 3. gcs-forensic-push timer not active (Warning)

- 条件: `systemd.unit.info[gcs-forensic-push.timer,ActiveState]` != `"active"`
- **影響**: GCS への継続アップロード停止、搬送中の物理障害リスク増

対応:
```bash
ssh root@192.168.11.2 systemctl status gcs-forensic-push.timer
ssh root@192.168.11.2 systemctl restart gcs-forensic-push.timer
# 即時 catch-up
ssh root@192.168.11.2 /usr/local/sbin/gcs-forensic-push.sh
```

### 4. GCS upload errors detected (Warning)

- 条件: `vfs.file.size[/mnt/data/.gcs-state/errors.log]` > 0
- **影響**: 一部ファイルの GCS 到達未完了。ただし次回 timer でリトライされる (pushed.list に無ければ再試行)

対応:
```bash
ssh root@192.168.11.2 "tail -30 /mnt/data/.gcs-state/errors.log"
```

HTTP コードごとの対応は [`gcs-upload-ops.md`](gcs-upload-ops.md) の「障害対応」を参照。

エラー解消後に次の再発を検出するため:
```bash
# 確認済みエラーを確認してクリア (Info level で記録を GCS 側にも残したいなら別対応)
ssh root@192.168.11.2 "> /mnt/data/.gcs-state/errors.log"
```

### 5. GCS push timer stalled (>10min) (Warning)

- 条件: `(now() - vfs.file.time[last-push.json,modify])` > 600 秒
- **影響**: タイマーは active だがスクリプトが完走していない (ハング、zombie、gcloud 認証失敗等)

対応:
```bash
ssh root@192.168.11.2 "
systemctl status gcs-forensic-push.service --no-pager -n 30
journalctl -u gcs-forensic-push.service --since '30 min ago' | tail -30
"
# 手動実行で再現確認
ssh root@192.168.11.2 /usr/local/sbin/gcs-forensic-push.sh
```

スクリプト先頭から実行時間が異常に長い場合、対象ファイル数が急増した可能性 (`find` 結果が大きい)。6 日運用想定を超えた量なら pushed.list が膨張していないか確認。

### 6. /mnt/data Space is critically low (standard Linux template, Warning/High)

- 条件: `vfs.fs.dependent.size[/mnt/data,pused]` > マクロ値
- 閾値: Warning 50%、High 80% (本プロジェクト設定)

対応:
- 想定容量 (10GB) に対し 458GB なので 50% 超過は異常
- 先頭の `find /mnt/data -type f -size +100M` でサイズ大のファイル特定
- 本番日のファイル削除は **GCS 転送 + 封印完了まで厳禁**

## 誤検知を避けるための知見

### `errors.log` が存在しないと unsupported 表示

`vfs.file.size[...]` は対象ファイル不在で state=1 (unsupported) となる。本設計では `gcs-forensic-push.sh` が起動時に `touch` して 0 byte ファイルを保証している。

### systemd.unit.info の値が空

`.timer` unit は `.service` と同じく取得できるが、systemd-agent2 プラグインが生成するキーは `Timer` オブジェクトで ActiveState を返す。空の場合は agent restart で回復 (初期化タイミング問題)。

### 夜間のログ断

事前準備期間は夜間トラフィックが少なく、syslog 最新ファイル mtime が伸びやすい。今回のテンプレートには syslog 停滞トリガーは含めていないが、追加する場合は閾値を **30 分以上** にする。

## Zabbix トリガー追加・変更

冪等スクリプト: `scripts/ops/zabbix-setup-forensic.py`

```bash
python scripts/ops/zabbix-setup-forensic.py
```

既存テンプレート/アイテム/トリガーは重複作成されない (存在確認ロジック内蔵)。

## API トークン

メモリの `reference_zabbix-api.md` を参照。API URL `http://192.168.11.6/api_jsonrpc.php`、トークンは Bearer で送信。

## 関連

- [`../design/logging-compliance.md`](../design/logging-compliance.md) §9 — 監視設計
- [`local-server-ops.md`](local-server-ops.md) — local-server 全体運用
- [`gcs-upload-ops.md`](gcs-upload-ops.md) — GCS 転送障害対応
