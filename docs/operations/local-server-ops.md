# local-server (CT 200) 運用手順

法執行対応ログ集約用 LXC コンテナ (`local-server`, Proxmox CT 200, 192.168.11.2) の日常運用・障害対応手順。

設計全体は [`../design/logging-compliance.md`](../design/logging-compliance.md) および [`../design/venue-proxmox.md`](../design/venue-proxmox.md) を参照。

## 前提

- SSH: `ssh root@192.168.11.2` (公開鍵認証、6 鍵配備済み)
- TZ: **UTC** (出力する時刻は全て UTC、file 名も UTC の `Z` suffix)
- 主要サービス: `rsyslog`, `nfcapd` (forensic), `gcs-forensic-push.timer`, `nfcapd-bw@r1` / `nfcapd-bw@r2` (bw 分析), `netflow-bw-summary.timer`, `netflow-summary.timer`
- データ: `/mnt/data` (NVMe #2, 458GB, ext4, noatime)
  - `/mnt/data/nfcapd/` — forensic NetFlow (pmacctd、180 日)
  - `/mnt/data/nfcapd-bw-r1/` — 帯域分析用 wg0 経由 (softflowd、short-term)
  - `/mnt/data/nfcapd-bw-r2/` — 帯域分析用 wg1 経由 (softflowd、short-term)

## 稼働確認 (5 分で完走)

```bash
ssh root@192.168.11.2 "
systemctl is-active rsyslog nfcapd nfcapd-bw@r1 nfcapd-bw@r2 \
  gcs-forensic-push.timer netflow-summary.timer netflow-bw-summary.timer
ss -lnp | grep -E ':(514|2055|2056|2057)'
df -h /mnt/data
cat /mnt/data/.gcs-state/last-push.json
wc -l /mnt/data/.gcs-state/errors.log
"
```

期待:
- すべて `active`
- TCP 514 / UDP 514 / UDP 2055 / UDP 2056 / UDP 2057 すべて listen
- `/mnt/data` 使用量 80% 未満
- `last-push.json` の `end` が直近 5 分以内、`errors: 0`
- `errors.log` が 0 行

## ログ到達状況の確認

```bash
# 直近 10 分で更新されたファイル (どのホストからログが来ているか)
find /mnt/data/syslog-archive -type f -mmin -10 -printf '%TY-%Tm-%Td %TH:%TM %f\n' | sort

# ホスト別最新 mtime
for h in r1-home r2-gcp r3-vyos 192.168.11.10 192.168.11.12 sw-162; do
  f=$(ls -t /mnt/data/syslog-archive/all/${h}-*.log 2>/dev/null | head -1)
  [ -n "$f" ] && printf "%-20s %s\n" "$h" "$(stat -c '%y' "$f")"
done
```

不達ホスト検知: 指定 mtime が古い / ファイルが存在しない → 送信側の syslog 設定 or ネットワーク経路を調査。

## NetFlow ダンプ

```bash
# 全 rotated ファイルの集計
nfdump -R /mnt/data/nfcapd -I

# 直近 5 分のフロー先頭 20 行
LATEST=$(ls -t /mnt/data/nfcapd/nfcapd.20* | head -1)
nfdump -r "$LATEST" -c 20 -o extended

# 特定 IP のフロー抽出
nfdump -R /mnt/data/nfcapd "src ip 192.168.40.123 or dst ip 192.168.40.123" -o extended | head -30
```

## 帯域分析パイプライン (softflowd → nfcapd-bw → netflow-bw-summary)

forensic 用 NetFlow とは独立した系統。Grafana「BwAI NetFlow Analytics」の Bandwidth 3 ロウ (All routes / r1 / r2) に供給する。

```
r3 softflowd-bw@wg0 ──NetFlow v9──▶ 192.168.11.2:2056 ──▶ nfcapd-bw@r1 ──▶ /mnt/data/nfcapd-bw-r1/
r3 softflowd-bw@wg1 ──NetFlow v9──▶ 192.168.11.2:2057 ──▶ nfcapd-bw@r2 ──▶ /mnt/data/nfcapd-bw-r2/
                                                                           │
                                                                           ▼  5 min
                                                             netflow-bw-summary.py
                                                                           │
                                                                           ▼ HTTP push
                                                             Loki {source="netflow", type="bw"}
```

### 動作確認

```bash
# r3 側 exporter
ssh r3-venue 'systemctl is-active softflowd-bw@wg0 softflowd-bw@wg1'

# local-server 側 collector + summarizer
systemctl is-active nfcapd-bw@r1 nfcapd-bw@r2 netflow-bw-summary.timer
ls -la /mnt/data/nfcapd-bw-r1 /mnt/data/nfcapd-bw-r2

# 最新の bw 集計結果
tail -5 /var/log/netflow/netflow-bw-$(date -u +%Y%m%d).json | python3 -m json.tool
```

### 障害対応

**r3 の softflowd が落ちている** (image rolling update 直後に多い):

```bash
ssh r3-venue '/config/scripts/softflowd-bw/bootstrap.sh'
```

`/usr/sbin/softflowd` が消えていれば `/config/scripts/softflowd-bw/softflowd_*.deb` から自動で dpkg -i、systemd unit を `/etc/systemd/system/` に再配置、enable + start する。

**nfcapd-bw が port bind エラー**:

```bash
ss -ulnp | grep -E '2056|2057'   # 既存プロセス特定
systemctl restart nfcapd-bw@r1 nfcapd-bw@r2
```

**Loki に bw が来ない**:

```bash
journalctl -u netflow-bw-summary.service --since '30 min ago'
curl -sG 'http://192.168.11.6:3100/loki/api/v1/query_range' \
  --data-urlencode 'query={source="netflow", type="bw"}' \
  --data-urlencode 'since=30m' | python3 -m json.tool | head -20
```

## 障害対応

### rsyslog が停止

```bash
systemctl status rsyslog
journalctl -u rsyslog -n 50
# 設定 validate
rsyslogd -N1
# 再起動
systemctl restart rsyslog
```

`octal mode` エラー: `/etc/rsyslog.d/60-bwai-forensic.conf` の `dirCreateMode` / `fileCreateMode` は **5 桁** `02750` / 4 桁 `0640` の先頭 `0` 必須。

### nfcapd が Address already in use

Debian パッケージの SysV init が競合起動している可能性。
```bash
systemctl stop nfcapd nfdump
pkill -9 nfcapd
systemctl disable nfdump.service
systemctl start nfcapd
```

### gcs-forensic-push が停滞

```bash
# 直近実行履歴
systemctl list-timers gcs-forensic-push.timer
journalctl -u gcs-forensic-push.service --since '1 hour ago'

# 手動再実行
/usr/local/sbin/gcs-forensic-push.sh
cat /mnt/data/.gcs-state/last-push.json
```

詳細は [`gcs-upload-ops.md`](gcs-upload-ops.md) を参照。

### /mnt/data 逼迫

想定容量 (6 日運用で ~10GB) に対し 458GB は過剰余裕のため、使用率 > 50% は「想定外バースト or 古いファイルの異常累積」を意味する。

```bash
# 肥大ディレクトリ特定
du -sh /mnt/data/*
# ファイル数が多いディレクトリ
find /mnt/data -type f | awk -F/ '{print $3,$4}' | sort | uniq -c | sort -rn | head
```

**削除してよいのは prep 期間のテストファイルのみ**。本番日のファイルは GCS 転送 + 封印の前に削除厳禁。

### SSH 鍵更新

```bash
# 追加
cat >> ~/.ssh/authorized_keys << EOF
ssh-ed25519 AAAA... user@host
EOF
# 削除
sed -i '/user@host/d' ~/.ssh/authorized_keys
```

## 定期チェック (事前準備期間の Day -5 から Day -1)

| Day | チェック内容 |
|---|---|
| -5 | rsyslog 受信疎通 (r1/r2/r3 全部からログ到達)、CT 200 起動・systemd unit 全 active |
| -4 | GCS 転送健全性 (`last-push.json` の `pushed` > 0、`errors` = 0)、SA 権限 |
| -3 | Zabbix トリガー動作確認 (意図的にログ断を起こしてアラート発火) |
| -2 | nfcapd 5 分ローテ + GCS 転送のエンドツーエンド確認 |
| -1 | 模擬封印リハーサル (TSA 取得 + SHA-256 manifest 生成) |

## 関連

- [`../design/logging-compliance.md`](../design/logging-compliance.md) — 設計全体
- [`../design/venue-proxmox.md`](../design/venue-proxmox.md) — CT リソース・ネットワーク
- [`gcs-upload-ops.md`](gcs-upload-ops.md) — GCS 転送詳細
- [`zabbix-forensic-monitoring.md`](zabbix-forensic-monitoring.md) — 監視トリガー対応
- [`log-sealing.md`](log-sealing.md) — イベント終了後の封印手順
- [`log-query-cookbook.md`](log-query-cookbook.md) — 照会対応クエリ
