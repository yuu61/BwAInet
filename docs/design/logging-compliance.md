# 通信ログ保存設計 (法執行機関対応)

法執行機関からの照会に対応するためのログ収集・相関・保存設計。基本ポリシー (記録対象、保存期間、ランダム MAC の扱い) は [`../policy/logging-policy.md`](../policy/logging-policy.md) を参照。

## 1. ログ相関モデル

### ログ種別と役割

```
[誰が]
  VyOS DHCP リースログ    → timestamp + IPv4 ↔ MAC ↔ hostname
  NDP テーブルダンプ       → timestamp + IPv6 ↔ MAC (全デバイス)
  ※ DHCPv6 リースログは廃止 (SLAAC 一本化、NDP ダンプで代替)

[何を調べた]
  VyOS DNS クエリログ     → timestamp + client IP + qname + rcode

[どこと通信した]
  NetFlow v9              → timestamp + 5-tuple + bytes/packets

[NAT 変換]
  Conntrack イベント (r1)     → NAPT 変換マッピング (内部 IP:port ↔ グローバル IP:port)
  Conntrack イベント (r2-gcp) → NAT66 変換 + v4 NAPT (MASQUERADE)
```

### 共通結合キー

**タイムスタンプ + IP アドレス + MAC アドレス (ランダム MAC 含む)**

ランダム MAC であっても per-SSID 固定のため、イベント期間中は一意のデバイス識別子として機能する。hostname ("〇〇のiPhone" 等) が補助的な識別情報となる。

### 追跡例

「2026-08-10 14:30 に example.com にアクセスしたデバイスは?」

1. DNS クエリログから `example.com` を引いた client IP を特定
2. NetFlow から当該 IP の通信フローを確認
3. DHCP リースログ / NDP ダンプから IP → MAC → hostname を特定
4. Conntrack ログから NAT 変換を特定 (r1: NAPT / r2-gcp: NAT66 + v4 NAPT)

詳細なクエリパターンは [`../operations/log-query-cookbook.md`](../operations/log-query-cookbook.md) を参照。

## 2. 収集経路 (設計方針)

### VyOS 内蔵機能で完結

- **DNS**: `service dns forwarding` (PowerDNS Recursor)。`quiet=no` でクエリログ個別出力を有効化
- **DHCPv4**: `service dhcp-server` (内部 Kea)。標準 syslog 出力 (`kea-dhcp4`) で MAC/IP/interface が取得できるため forensic hook は**不要**
- **NetFlow**: `system flow-accounting netflow` v9 (対象 interface は `eth2.30` / `eth2.40` / `wg0` / `wg1`)
- **NDP**: `ip -6 neigh show` を 1 分間隔の task-scheduler でロギング、facility local1
- **Conntrack NAT**: `conntrack -E` を systemd サービスで syslog に出力 (r1, r2-gcp 両方)、facility local2

### 対象インターフェース (NetFlow)

- `eth2.30` — staff + live トラフィック
- `eth2.40` — user トラフィック
- `wg0` — 自宅 r1 向け VPN トンネル
- `wg1` — GCP r2-gcp 向け VPN トンネル

`eth2.11` (mgmt) は対象外。

### DNS クエリログの永続化

VyOS 2026.03 (Circinus) で `service dns forwarding` の `options` 自由キーが廃止されたため、CLI から `quiet=no` を設定できない。pdns-recursor 設定ファイル `/run/pdns-recursor/recursor.conf` は commit のたびに再生成されるので、`/config/scripts/commit/post-hooks.d/99-pdns-quiet-no.sh` で **quiet=no 追記 + pdns-recursor restart** を強制する。

スクリプトは `/config/` 配下にあるため VyOS のイメージ更新でも保持される。

## 3. DHCPv6 廃止の方針

DHCPv6 サーバーは廃止し SLAAC に一本化。理由:

- iOS/Android が DHCPv6 IA_NA 非対応 → SLAAC 必須
- RFC 6724 によるソースアドレス選択が OS 依存 → DHCPv6 アドレスが PBR に使われる保証なし
- MAC ↔ IPv6 追跡は NDP テーブルダンプでカバー済み
- kea が VIF の `interface` 指定に VyOS CLI で対応しておらず運用が複雑

SLAAC (A flag) に統一、DNS は RDNSS + O flag で配布。詳細は [`../policy/logging-policy.md`](../policy/logging-policy.md) を参照。

## 4. Conntrack NAT ログ設計

### なぜ必要か

会場側 NetFlow は NAT 前の内部 IP を記録するが、法執行機関からの照会は「**グローバル IP X.X.X.X のポート Y から Z 時刻に通信があった**」という形式で来る。NAT 変換テーブルがないと、グローバル IP 起点での内部デバイス特定ができない。

### r1 (NAPT 変換)

`conntrack -E` で NEW/DESTROY イベントをリアルタイム syslog 出力。対象は会場サブネット (192.168.11/30/40) のみ、家族用 LAN (192.168.10.0/24) は除外。facility local2、programname `conntrack-nat`。

### r2-gcp (NAT66 + v4 NAPT)

同様に conntrack イベントを記録。対象:

| NAT 種別 | 変換内容 |
|----------|---------|
| NAT66 (IPv6) | 会場 GCP /64 src (`2600:1900:41d1:92::/64`) → r2-gcp /96 (`2600:1900:41d0:9d::/96`)、IID 下位 32bit 保持 |
| v4 NAPT (MASQUERADE) | 会場サブネット src (`192.168.0.0/16`) + WG transfer (`10.255.0.0/16`) → GCE 内部 IP (`10.174.0.7`) にポート変換付き多対一変換。GCE 外部 IP (`34.97.197.104`) へは GCP 側で 1:1 NAT |

v4 側は `conntrack-nat`、v6 側は `conntrack-nat6` という別 programname で出力。rsyslog の programname マッチに影響しない分離。

syslog 転送 (wg 経由で local-server 192.168.11.2 に集約) は VyOS config で `system syslog remote 192.168.11.2 protocol tcp port 514`。

## 5. タイムゾーン方針

**全機器を UTC に統一**。運用者向けの画面表示 (Grafana / Zabbix UI) だけ JST 表示。

| 層 | TZ |
|---|---|
| ネットワーク機器 (r1/r2/r3/SW/AP/WLC) | UTC |
| ログ集約 CT 200 | UTC |
| 監視 CT 201 (OS / Zabbix server / Loki / Alloy) | UTC |
| Proxmox ホスト | UTC |
| Grafana 表示 | `default_timezone = Asia/Tokyo` |
| Zabbix frontend 表示 | DB `config.default_timezone = Asia/Tokyo` |

ファイル名の時刻表記は UTC (`Z` suffix 明記)、ファイル内の timestamp も UTC。運用者は UI で JST 表示を利用。

## 6. local-server CT 構成

local-server (CT 200) は**法執行対応ログ集約専用**。rsyslog + nfcapd + GCS uploader のみを稼働させ、運用監視ツール (Zabbix, Grafana, SNMP Exporter 等) は配置しない。運用監視は zabbix-grafana (CT 201) で行う。詳細は [`venue-proxmox.md`](venue-proxmox.md) を参照。

### ディレクトリ構造 (NVMe #2 上)

```
/mnt/data/ (NVMe #2, ext4, 458GB, noatime)            root:adm 2755
├── nfcapd/                                            nfcapd:adm 2750
│   ├── nfcapd.current.<pid>                           書き込み中
│   └── nfcapd.YYYYMMDDHHMM                            5 分ローテ後、immutable
├── syslog-archive/                                    root:adm 2750
│   ├── dns/<hostname>-YYYY-MM-DDTHHZ.log              pdns-recursor (quiet=no のクエリ)
│   ├── conntrack/<hostname>-YYYY-MM-DDTHHZ.log        facility local2 (r1/r2)
│   ├── ndp/<hostname>-YYYY-MM-DDTHHZ.log              facility local1 (r3 NDP dump)
│   ├── dhcp/<hostname>-YYYY-MM-DDTHHZ.log             programname kea* (r3 Kea)
│   └── all/<hostname>-YYYY-MM-DDTHHZ.log              全 syslog 保険コピー
├── manifests/                                         root:adm 2750
│   ├── preliminary/seal-<epoch>.{json,sha256,tsr}     会場封印
│   └── final/seal-<epoch>.{json,sha256,tsr}           自宅最終封印
└── .gcs-state/                                        root:adm 2750
    ├── sa-key.json                                    0400 root:root (SA 認証鍵)
    ├── pushed.list                                    送信済みファイル追跡
    ├── last-push.json                                 前回 push 統計 (Zabbix 監視対象)
    └── errors.log                                     push 失敗時のみ追記
```

**ファイル命名**: `<hostname>-YYYY-MM-DDTHHZ.log` (UTC、rsyslog `%HOSTNAME%` + `$YEAR/$MONTH/$DAY/$HOUR`)。CT 200 が UTC TZ のため自然に UTC ベース。

**kea/ ディレクトリは廃止**: Kea は r3 内蔵で動作し syslog 経由でログが来るため、`syslog-archive/dhcp/` に統合。

### rsyslog 設計

- **TCP 514** 受信 (VyOS 系の損失防止優先): r1 / r2-gcp / r3
- **UDP 514** 受信も併設: Cisco SW (TCP syslog ポートが 601 で非互換)、WLC、その他 UDP のみ対応機器
- ソース IP フィルタ: `192.168.11.0/24` + `10.255.0.0/16` (WG mesh) + `127.0.0.1` のみ許可、他は stop
- ファイル書き込み: `root:adm 0640` (setgid 継承)、dir は `2750`
- `$DynaFileCloseTimeout 300` で時間境界 +5 分で前時ファイルを自動 close (GCS 送信時の整合性確保)
- **運用可視化用**に zabbix-grafana CT (192.168.11.6:1514) の Alloy に forward (RFC 5424 octet-counted)。ログの**原本は local-server 側に保持**、Alloy は読み取り専用経路

設定ファイル: `/etc/rsyslog.d/60-bwai-forensic.conf` (リポジトリ内 `scripts/rsyslog-60-bwai-forensic.conf`)

### nfcapd

- UDP 受信ポート 2055
- nfdump 1.7.1: `-T all` は**廃止**され全拡張自動捕捉、`-l` は `-w` に変更
- `-t 300` で 5 分間隔ファイルローテーション、`-e` で rotate 時 EOF marker
- systemd unit: `User=nfcapd Group=adm`、`ProtectSystem=strict` + `ReadWritePaths=/mnt/data/nfcapd` の hardening

設定ファイル: `/etc/systemd/system/nfcapd.service` (リポジトリ内 `scripts/nfcapd.service`)

### Alloy / Loki (運用可視化)

CT 201 上で Alloy が TCP 1514 で RFC 5424 octet-counted を受信し、Loki (127.0.0.1:3100) に push。Grafana で Explore 検索。

- Loki: filesystem-backed、retention 14 日 (運用目的、法執行原本は GCS 側)
- Alloy config: `loki.source.syslog` + `loki.relabel` + `loki.write`
- Grafana datasource: `/etc/grafana/provisioning/datasources/loki.yaml`

## 7. 転送・アーカイブ (GCS 直送)

venue Proxmox は借用機のため、**イベント中から GCS に継続アップロード**し、搬送中の物理障害リスクを低減する (GCE 中継は廃止)。

```
[事前準備 (5 日) + 本番 (8 時間) + 片付け = 約 6 日運用中、継続 rsync]
  VyOS (r3)  ──syslog/NetFlow──→ local-server CT → ファイル保存 (NVMe #2)
  r1         ──syslog──→          local-server CT → ファイル保存
  r2-gcp     ──syslog──→          local-server CT → ファイル保存
  SW/WLC     ──syslog (UDP)──→   local-server CT → ファイル保存
                                    │
                                    └──→ curl raw REST API (5 分間隔 systemd timer)
                                          ↓ ifGenerationMatch=0 (上書き不可)
                                    gs://bwai-forensic-2026/

[運用可視化 (法執行ログとは独立)]
  local-server (rsyslog) ──forward──→ Alloy (CT 201) → Loki → Grafana
```

### アップロード実装

**raw REST API + `ifGenerationMatch=0`** を使用:

- `gcloud storage cp` / `gsutil cp` は preflight GET/HEAD を発行するため `storage.objects.get` が必要 → **objectCreator のみでは 403**
- `curl -X POST https://storage.googleapis.com/upload/storage/v1/b/<bucket>/o?uploadType=media&name=<path>&ifGenerationMatch=0` なら create-only、`storage.objects.create` のみで動作
- `ifGenerationMatch=0` により同名オブジェクトが既に存在する場合は **HTTP 412** で拒否 → 上書き不可 = WORM の自然強制

### 送信対象と除外

- 対象: `*.log` (`/mnt/data/syslog-archive/**/`), `nfcapd.20*` (`/mnt/data/nfcapd/`)
- 除外: mtime 10 分以内のファイル (書き込み中の可能性)、`.gcs-state/*`、`nfcapd.current.*`
- 冪等性: `.gcs-state/pushed.list` で送信済みファイルを追跡、重複送信スキップ

### SA 権限と Retention

- SA: `forensic-uploader@bwai-noc.iam.gserviceaccount.com`
- ロール: **`roles/storage.objectCreator` のみ** (list/read/delete/overwrite すべて不可)
- SA キー: CT 200 `/mnt/data/.gcs-state/sa-key.json` (0400 root:root)
- Retention: **180 日** 設定、lock は**イベント終了後**に実施 (事前準備期間中のテスト削除余地を残すため)

### タイマー

- systemd unit: `/etc/systemd/system/gcs-forensic-push.{service,timer}`
- 実行間隔: 5 分 (`OnUnitActiveSec=5min`)
- `RandomizedDelaySec=30` で並列性ばらつき吸収

スクリプト本体: `/usr/local/sbin/gcs-forensic-push.sh` (リポジトリ内 `scripts/gcs-forensic-push.sh`)
運用手順 (SA キー更新、手動再投入、障害復旧): [`../operations/gcs-upload-ops.md`](../operations/gcs-upload-ops.md)

## 8. 保存期間と保存先

| 層 | 場所 | 保持 |
|---|---|---|
| 原本 (CT 200) | `/mnt/data/` (NVMe #2) | イベント期間 + 搬送期間のみ (約 7 日) |
| 原本 (GCS) | `gs://bwai-forensic-2026/` | **180 日**、イベント後 lock で不可逆 |
| 運用可視化 (Loki) | CT 201 rootfs | **14 日**、法執行対応とは別経路 |

### ローテーションポリシー

- **nfcapd**: 5 分ローテ (`-t 300`)
- **syslog**: **時次ローテ** (rsyslog DynaFile で `$HOUR` 変数を使用、UTC)
  - append 方式でなくファイル名分割で、rotate 後のファイルは immutable
  - GCS 継続アップロードが上書き衝突を起こさないため必須
- **logrotate は使わない**: イベント期間が短く、GCS 側に長期保管する設計

## 9. 監視 (Zabbix)

CT 201 の Zabbix server から CT 200 を監視。テンプレート: **"BwAI Forensic local-server"**。

| 監視項目 | Zabbix key | トリガー |
|---|---|---|
| rsyslog active | `systemd.unit.info[rsyslog.service,ActiveState]` | High: `!= "active"` |
| nfcapd active | `systemd.unit.info[nfcapd.service,ActiveState]` | High: `!= "active"` |
| gcs timer active | `systemd.unit.info[gcs-forensic-push.timer,ActiveState]` | Warning: `!= "active"` |
| GCS push errors | `vfs.file.size[/mnt/data/.gcs-state/errors.log]` | Warning: `> 0` |
| GCS push stall | `vfs.file.time[.../last-push.json,modify]` | Warning: age `> 600s` |
| `/mnt/data` 使用率 | 標準 Linux テンプレート | Warning 50% / High 80% |

運用対応 runbook: [`../operations/zabbix-forensic-monitoring.md`](../operations/zabbix-forensic-monitoring.md)

## 10. イベント終了後のログ封印

搬送中の改ざん検知とイベント終了後の GCS 転送完了検証を両立するため、封印は **2 段階** で実施する。

1. **予備封印 (会場、電源オフ前)**: 搬送中の改ざん検知の基準点
2. **最終封印 (自宅ラボ)**: GCS 最終同期・検証後。照会対応の正式な根拠

GCS Retention Policy (WORM) のロックは最終封印・検証完了後 (不可逆)。**初期化は GCS 転送完了確認が取れるまで行わない**。

正当性証明の三層構造 (人的証人・RFC 3161 TSA・GCS WORM) は [`../policy/logging-policy.md`](../policy/logging-policy.md) を、具体的な手順は [`../operations/log-sealing.md`](../operations/log-sealing.md) を参照。

## 11. 照会対応

nfdump, grep ベースの具体的なクエリ例は [`../operations/log-query-cookbook.md`](../operations/log-query-cookbook.md) を参照。総合追跡テンプレート (DNS → DHCP → NDP → NetFlow → NAT) もそちらに記載。

照会対応は GCS 上のデータのみで完結する設計 (venue Proxmox は借用機のため返却済み)。

## 関連

- [`../policy/logging-policy.md`](../policy/logging-policy.md) — 記録ポリシー、保存期間、ランダム MAC 方針
- [`../operations/local-server-ops.md`](../operations/local-server-ops.md) — rsyslog / nfcapd / GCS 運用 runbook
- [`../operations/gcs-upload-ops.md`](../operations/gcs-upload-ops.md) — GCS 転送検証・SA 運用
- [`../operations/zabbix-forensic-monitoring.md`](../operations/zabbix-forensic-monitoring.md) — 監視トリガー対応
- [`../operations/log-sealing.md`](../operations/log-sealing.md) — 封印・TSA・GCS WORM 手順
- [`../operations/log-query-cookbook.md`](../operations/log-query-cookbook.md) — 照会対応クエリ例
- [`venue-proxmox.md`](venue-proxmox.md) — local-server CT の構成
- [`venue-vyos.md`](venue-vyos.md) — r3 側のログ収集設定
- [`home-vyos.md`](home-vyos.md) — r1 側 conntrack-logger
- [`gcp-integration.md`](gcp-integration.md) — r2-gcp 側 NAT66 / NAPT
