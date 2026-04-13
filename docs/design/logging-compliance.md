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
  Conntrack イベント (r2-gcp) → NAT66 変換 + v4 SNAT 変換
```

### 共通結合キー

**タイムスタンプ + IP アドレス + MAC アドレス (ランダム MAC 含む)**

ランダム MAC であっても per-SSID 固定のため、イベント期間中は一意のデバイス識別子として機能する。hostname ("〇〇のiPhone" 等) が補助的な識別情報となる。

### 追跡例

「2026-08-10 14:30 に example.com にアクセスしたデバイスは?」

1. DNS クエリログから `example.com` を引いた client IP を特定
2. NetFlow から当該 IP の通信フローを確認
3. DHCP リースログ / NDP ダンプから IP → MAC → hostname を特定
4. Conntrack ログから NAT 変換を特定 (r1: NAPT / r2-gcp: NAT66 + v4 SNAT)

詳細なクエリパターンは [`../operations/log-query-cookbook.md`](../operations/log-query-cookbook.md) を参照。

## 2. 収集経路 (設計方針)

### VyOS 内蔵機能で完結

- **DNS**: `service dns forwarding` (PowerDNS Recursor) でクエリログ
- **DHCPv4**: `service dhcp-server` (内部 Kea) + forensic log hook
- **NetFlow**: `system flow-accounting` v9
- **NDP**: `ip -6 neigh show` を 1 分間隔の task-scheduler でロギング
- **Conntrack NAT**: `conntrack -E` を systemd サービスで syslog に出力 (r1, r2-gcp 両方)

### 対象インターフェース (NetFlow)

- `eth2.30` — staff + live トラフィック
- `eth2.40` — user トラフィック
- `wg0` — VPN トンネル経由の全トラフィック

`eth2.11` (mgmt) は対象外。

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

`conntrack -E` で NEW/DESTROY イベントをリアルタイム syslog 出力。対象は会場サブネット (192.168.11/30/40) のみ、家族用 LAN (192.168.10.0/24) は除外。facility local2、tag `conntrack-nat`。

### r2-gcp (NAT66 + v4 SNAT)

同様に conntrack イベントを記録。対象:

| NAT 種別 | 変換内容 |
|----------|---------|
| NAT66 (IPv6) | 会場 GCP /64 src (`2600:1900:41d1:92::/64`) → r2-gcp /96 (`2600:1900:41d0:9d::/96`)、IID 下位 32bit 保持 |
| v4 SNAT | 会場サブネット src (`192.168.0.0/16`) → GCE 内部 IP (`10.174.0.7`) → GCE 外部 IP (`34.97.197.104`, 1:1 NAT) |

syslog 転送 (wg 経由で local-server 192.168.11.2 に集約) は VyOS config で `system syslog host 192.168.11.2 facility local2 level info`。

## 5. local-server CT 構成

local-server (CT 200) は**法執行対応ログ集約専用**。rsyslog + nfcapd のみを稼働させ、運用監視ツール (Zabbix, Grafana, SNMP Exporter 等) は配置しない。運用監視は zabbix-grafana (CT 201) で行う。詳細は [`venue-proxmox.md`](venue-proxmox.md) を参照。

### ディレクトリ構造 (NVMe #2 上)

```
/mnt/data (NVMe #2, ext4, 512GB)
├── nfcapd/                  ← NetFlow v9 ファイル (5 分ローテ)
├── syslog-archive/
│   ├── dns/                 ← facility 0, tag: dns-forwarding
│   ├── conntrack/           ← facility local2
│   ├── ndp/                 ← facility local1
│   ├── dhcp/                ← Kea (daemon)
│   └── all.log              ← 全ログ保険コピー
└── kea/                     ← Kea forensic log
```

### rsyslog 設計

- TCP 514 で受信 (r3/r1/r2-gcp) — ログ損失防止、同一 VLAN 11 内で TLS 不要
- facility 別ファイル出力 (NVMe #2)
- **運用可視化用**に zabbix-grafana CT (192.168.11.6:1514) の Alloy に forward。ログの**原本は local-server 側に保持**、Alloy は読み取り専用経路

### nfcapd

- 受信ポート 2055
- `-T all` で全拡張フィールド記録
- `-t 300` で 5 分間隔ファイルローテーション

## 6. 転送・アーカイブ (GCS 直送)

venue Proxmox は借用機のため、イベント中から GCS に継続アップロードし、搬送中の物理障害リスクを低減する (GCE 中継は廃止)。

```
[イベント期間中: 継続的 GCS アップロード]
  VyOS (r3)  ──syslog/NetFlow──→ local-server CT → ファイル保存 (NVMe #2)
  r1         ──syslog──→          local-server CT → ファイル保存
  r2-gcp     ──syslog──→          local-server CT → ファイル保存
                                    │
                                    └──→ gcloud storage rsync (5-15 分間隔)
                                          ↓
                                    gs://bwai-forensic-2026/

[運用可視化 (法執行ログとは独立)]
  local-server (rsyslog) ──forward──→ Alloy (CT 201) → Grafana
```

SA 権限は `objectCreator` のみ (漏洩時も削除・上書き不可)。運用手順 (cron 設定、失敗検知) は [`../operations/log-sealing.md`](../operations/log-sealing.md) を参照。

## 7. イベント終了後のログ封印

搬送中の改ざん検知とイベント終了後の GCS 転送完了検証を両立するため、封印は **2 段階** で実施する。

1. **予備封印 (会場、電源オフ前)**: 搬送中の改ざん検知の基準点
2. **最終封印 (自宅ラボ)**: GCS 最終同期・検証後。照会対応の正式な根拠

GCS Retention Policy (WORM) のロックは最終封印・検証完了後 (不可逆)。**初期化は GCS 転送完了確認が取れるまで行わない**。

正当性証明の三層構造 (人的証人・RFC 3161 TSA・GCS WORM) は [`../policy/logging-policy.md`](../policy/logging-policy.md) を、具体的な手順は [`../operations/log-sealing.md`](../operations/log-sealing.md) を参照。

## 8. 保存期間と保存先

| ログ種別 | ローカル (NVMe #2) | GCS (`bwai-forensic-2026`) |
|---|---|---|
| 全ログ種別 | イベント期間中のみ | **180 日 (WORM)** |

ローカルは nfcapd の 5 分ローテを内部で行う以外、ローテーション不要 (イベント期間は通常 1-2 日)。長期保管は GCS。

## 9. 照会対応

nfdump, grep ベースの具体的なクエリ例は [`../operations/log-query-cookbook.md`](../operations/log-query-cookbook.md) を参照。総合追跡テンプレート (DNS → DHCP → NDP → NetFlow → NAT) もそちらに記載。

照会対応は GCS 上のデータのみで完結する設計 (venue Proxmox は借用機のため返却済み)。

## 関連

- [`../policy/logging-policy.md`](../policy/logging-policy.md) — 記録ポリシー、保存期間、ランダム MAC 方針
- [`../operations/log-sealing.md`](../operations/log-sealing.md) — 封印・TSA・GCS WORM 手順
- [`../operations/log-query-cookbook.md`](../operations/log-query-cookbook.md) — 照会対応クエリ例
- [`venue-proxmox.md`](venue-proxmox.md) — local-server CT の構成
- [`venue-vyos.md`](venue-vyos.md) — r3 側のログ収集設定
- [`home-vyos.md`](home-vyos.md) — r1 側 conntrack-logger
- [`gcp-integration.md`](gcp-integration.md) — r2-gcp 側 NAT66 / SNAT
