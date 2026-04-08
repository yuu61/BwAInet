# 通信ログ保存設計 (法執行機関対応)

## 1. 目的と記録ポリシー

法執行機関からの照会に対し、通信記録を適切に提出できる体制を整備する。

### 基本方針

- IP ペイロード (通信内容) は**記録しない**
- 通信メタデータ (誰が・いつ・どこと) のみを記録
- 全ログを相互に紐付けて追跡可能にする
- 保存期間: **180 日**
- 利用規約 (AUP) で通信記録の取得を告知し、公序良俗に反する通信を禁止する

### 利用規約 (Acceptable Use Policy)

以下は会場掲示・配布用の本文 (そのまま掲示可)。

```
Build with AI in Kwansai 2026 ネットワーク利用規約

本ネットワークは Build with AI in Kwansai 2026 運営チーム (NOC: Network Operations Center) が会場内で提供する Wi-Fi / 有線ネットワークです。
本ネットワークに接続した時点で、以下のすべての内容に同意したものとみなします。

1. 通信記録の取得
   運営は、法執行機関対応および不正利用防止のため、本ネットワーク上を流れる
   通信のメタデータ (接続元 / 接続先 IP アドレス、ポート番号、通信時刻、通信量、DNS クエリ名、DHCP リース情報、IPv6 アドレスとハードウェアアドレスの対応情報 (NDP) 等) を記録します。
   通信の内容 (メッセージ本文、ファイルの中身等) は記録しません。
   取得した記録は 180 日間保管します。

2. 禁止事項
   以下の行為を禁止します。
   ・法令に違反する行為
   ・公序良俗に反する行為
   ・第三者の権利を侵害する行為
   ・本ネットワークその他の設備に対する攻撃・妨害行為
   ・運営が本イベントの運営上不適切と判断する行為

3. 法執行機関への情報提供
   日本国の法令に基づく正当な要請があった場合、運営は第 1 項で取得した記録を該当機関に提出することがあります。

4. 通信経路に関する技術的事項
   本ネットワークは通信最適化のため、Google 社のサービス (Google Cloud, Gmail, YouTube, Google 検索, Google Workspace 等) 宛の通信をGoogle Cloud Platform 経由で中継します。
   このため、これらのサービスから観測される送信元 IP アドレスは、本ネットワーク経由で他のウェブサイト等にアクセスする場合とは異なるアドレスとなります。

   ご自身が管理される Google Cloud 上の仮想マシン等に対し送信元 IP アドレスによるアクセス制限を設定されている場合、本ネットワークから直接の接続ができない可能性があります。
   該当する運用をされている方は通常の対処方法(踏み台サーバー、VPN、Identity-Aware Proxy 等) をご利用ください。
   以下の代替手段も利用可能です。
   ・gcloud compute ssh --tunnel-through-iap <VM>
     (ローカルのシェルから IAP Tunneling 経由で SSH 接続)
   ・Cloud Shell (ブラウザ上のシェル)

5. 免責
   本ネットワークはベストエフォートにより提供されます。
   運営は安定した通信の提供に最善を尽くしますが、通信速度・可用性・継続性・セキュリティについて保証はできません。
   本ネットワークの利用によって生じたいかなる損害についても、運営は責任を負いません。

本規約に関するお問い合わせは会場内の運営スタッフまでお寄せください。

Build with AI in Kwansai 2026 運営チーム
```

### ランダム MAC アドレスへの対応方針

iOS 14+ / Android 10+ / Windows 11 / macOS 15 はデフォルトでランダム MAC を使用するが、**per-SSID 固定** (同一 SSID に接続中は同じランダム MAC を維持) であるため、イベント期間中のログ相関には影響しない。

人物特定については:

- DHCP hostname ("〇〇のiPhone" 等) + ランダム MAC + IP + 通信時刻を記録として保持
- それ以上の人物特定 (ランダム MAC → 物理デバイス → 所有者) が必要な場合は捜査機関側の権限で対応
- 参加者はエンジニアが中心でありリテラシーが高いため、Captive Portal / 802.1X による本人確認は行わない

※ Cisco AireOS 8.10 には LAA Mac Denial 機能があるが、iOS/Android の大半をブロックするため使用しない。

### 記録対象と非記録対象

| 記録する | 記録しない |
|---|---|
| 5-tuple (src/dst IP, src/dst port, protocol) | IP ペイロード (通信内容) |
| タイムスタンプ, バイト数, パケット数 | HTTP URL / ヘッダ / ボディ |
| DNS クエリ名 (qname) + 応答コード | DNS 応答レコード値 |
| DHCP リース (IP ↔ MAC ↔ hostname) | ユーザー個人の認証情報 |
| NDP テーブル (IPv6 ↔ MAC) | |
| NAPT 変換マッピング (内部 IP:port ↔ グローバル IP:port) | |
| NAT66 変換マッピング (GCP /64 SLAAC ↔ r2-gcp /96) | |
| v4 SNAT 変換マッピング (内部 IP:port ↔ GCE IP:port) | |

## 2. ログ相関モデル

### ログ種別と役割

```
[誰が]
  VyOS DHCP リースログ    → timestamp + IPv4 ↔ MAC ↔ hostname
  NDP テーブルダンプ       → timestamp + IPv6 ↔ MAC (全デバイス)
  VyOS DHCPv6 リースログ  → timestamp + IPv6 ↔ DUID (Windows/macOS のみ)

[何を調べた]
  VyOS DNS クエリログ     → timestamp + client IP + qname + rcode

[どこと通信した]
  NetFlow v9              → timestamp + 5-tuple + bytes/packets

[NAT 変換]
  Conntrack イベント (r1) → timestamp + NAPT 変換マッピング (内部 IP:port ↔ グローバル IP:port)
  Conntrack イベント (r2-gcp) → timestamp + NAT66 変換 (GCP /64 SLAAC ↔ r2-gcp /96)
                                           + v4 SNAT 変換 (内部 IP:port ↔ GCE IP:port)
```

### 共通結合キー

**タイムスタンプ + IP アドレス + MAC アドレス (ランダム MAC 含む)**

ランダム MAC であっても per-SSID 固定のため、イベント期間中は一意のデバイス識別子として機能する。hostname ("〇〇のiPhone" 等) が補助的な識別情報となる。

### 追跡例

「2026-08-10 14:30 に example.com にアクセスしたデバイスは？」

1. DNS クエリログから `example.com` を引いた client IP を特定
2. NetFlow から当該 IP の通信フローを確認
3. DHCP リースログ / NDP ダンプから IP → MAC → hostname を特定
4. Conntrack ログから NAT 変換を特定:
   - r1: 内部 IP:port ↔ グローバル IP:port (OPTAGE 経由の通信)
   - r2-gcp: 内部 IP:port ↔ GCE IP:port (Google 向け v4 通信)
   - r2-gcp: GCP /64 SLAAC ↔ r2-gcp /96 (GCP /64 経由の v6 通信)
5. ※ MAC がランダムでも hostname + MAC + 時刻帯の組み合わせで捜査機関に提供可能

## 3. VyOS DNS Forwarding 設定

VyOS 内蔵の `service dns forwarding` (PowerDNS Recursor) を使用。Unbound は廃止。

```
# DNS フォワーディング
set service dns forwarding listen-address 192.168.11.1
set service dns forwarding listen-address 192.168.30.1
set service dns forwarding listen-address 192.168.40.1
set service dns forwarding allow-from 192.168.11.0/24
set service dns forwarding allow-from 192.168.30.0/24
set service dns forwarding allow-from 192.168.40.0/22
set service dns forwarding system

# クエリログ有効化 (法執行対応)
set service dns forwarding options 'log-common-errors=yes'
set service dns forwarding options 'quiet=no'
set service dns forwarding options 'logging-facility=0'
```

PowerDNS Recursor のログは syslog 経由で出力される。`quiet=no` でクエリごとに以下のフォーマットで記録:

```
timestamp client_ip query_name query_type rcode
```

## 4. VyOS DHCP 設定 + Forensic Log

VyOS 内蔵の `service dhcp-server` (内部 Kea) を使用。別サーバーの Kea は廃止。

### DHCPv4

```
# VLAN 30 (staff + live)
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 range 0 start 192.168.30.100
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 range 0 stop 192.168.30.254
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 default-router 192.168.30.1
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 name-server 192.168.30.1
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 lease 3600

# VLAN 40 (user)
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 range 0 start 192.168.40.100
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 range 0 stop 192.168.43.254
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 default-router 192.168.40.1
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 name-server 192.168.40.1
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 lease 3600
```

### DHCPv6

```
set service dhcpv6-server shared-network-name STAFF-V6 subnet <delegated-prefix>::/64 address-range start <prefix>::1000 stop <prefix>::ffff
set service dhcpv6-server shared-network-name STAFF-V6 subnet <delegated-prefix>::/64 name-server <prefix>::1

set service dhcpv6-server shared-network-name USER-V6 subnet <delegated-prefix>::/64 address-range start <prefix>::1:0 stop <prefix>::1:ffff
set service dhcpv6-server shared-network-name USER-V6 subnet <delegated-prefix>::/64 name-server <prefix>::1
```

※ iOS/Android は DHCPv6 IA_NA 非対応のため SLAAC でアドレスを取得する。DHCPv6 は Windows/macOS 用。

### Forensic Log (Kea hook)

VyOS 内蔵 Kea の設定ファイル (`/etc/kea/kea-dhcp4.conf`) に直接 hook を追加:

```json
{
    "hooks-libraries": [
        {
            "library": "/usr/lib/kea/hooks/libdhcp_legal_log.so",
            "parameters": {
                "path": "/var/log/kea",
                "name": "kea-legal"
            }
        }
    ]
}
```

記録内容: タイムスタンプ, リースタイプ (assign/renew/release), IP, MAC, hostname, lease duration

## 5. VyOS Flow-Accounting 設定 (NetFlow v9)

```
set system flow-accounting interface eth2.30
set system flow-accounting interface eth2.40
set system flow-accounting interface wg0
set system flow-accounting netflow version 9
set system flow-accounting netflow server 192.168.11.2 port 2055
set system flow-accounting netflow timeout expiry-interval 60
set system flow-accounting netflow timeout flow-active 120
set system flow-accounting netflow timeout flow-inactive 15
set system flow-accounting netflow source-ip 192.168.11.1
```

対象インターフェース:

- `eth2.30` — staff + live トラフィック
- `eth2.40` — user トラフィック
- `wg0` — VPN トンネル経由の全トラフィック

※ `eth2.11` (mgmt) は対象外

## 6. Conntrack イベントログ (r1, NAPT 変換記録)

自宅 VyOS (r1) の pppoe0 で masquerade による NAPT が行われるため、conntrack イベントを記録して変換マッピングを保持する。

### なぜ必要か

会場側の NetFlow は NAT 前の内部 IP を記録するが、法執行機関からの照会は「**グローバル IP X.X.X.X のポート Y から Z 時刻に通信があった**」という形式で来る。masquerade の変換テーブル (内部 IP:port ↔ グローバル IP:port) を記録しないと、グローバル IP 起点での内部デバイス特定ができない。

### conntrack イベントロガー

`conntrack -E` で NEW/DESTROY イベントをリアルタイムに syslog へ出力する。対象は会場サブネットのみ (家族用 LAN 192.168.10.0/24 は除外)。

#### スクリプト (`/config/scripts/conntrack-logger.sh`)

```bash
#!/bin/bash
# Conntrack イベントログ: 会場サブネットの NAPT 変換マッピングを syslog に記録
# 対象: 192.168.11.0/24 (mgmt), 192.168.30.0/24 (staff), 192.168.40.0/22 (user)
# 除外: 192.168.10.0/24 (家族用 LAN)
conntrack -E -e NEW,DESTROY -o timestamp 2>/dev/null | \
    grep --line-buffered -E 'src=(192\.168\.(11|30|4[0-3])\.)' | \
    logger -t conntrack-nat -p local2.info
```

#### systemd サービス (`/etc/systemd/system/conntrack-logger.service`)

```ini
[Unit]
Description=Conntrack NAT Translation Logger
After=network.target

[Service]
ExecStart=/config/scripts/conntrack-logger.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

#### 有効化

```bash
chmod +x /config/scripts/conntrack-logger.sh
systemctl daemon-reload
systemctl enable --now conntrack-logger.service
```

### 出力例

```
[1723286400.123456]    [NEW] tcp      6 120 SYN_SENT src=192.168.40.123 dst=93.184.216.34 sport=54321 dport=443 [UNREPLIED] src=93.184.216.34 dst=<pppoe0-ip> sport=443 dport=12345
[1723286460.789012] [DESTROY] tcp      6 src=192.168.40.123 dst=93.184.216.34 sport=54321 dport=443 src=93.184.216.34 dst=<pppoe0-ip> sport=443 dport=12345
```

読み方:

- original tuple: `src=192.168.40.123 sport=54321` → 内部クライアント
- reply tuple: `dst=<pppoe0-ip> dport=12345` → NAT 後のグローバル IP:ポート
- NEW → セッション確立、DESTROY → セッション終了

### syslog 転送 (r1 → Local Server)

conntrack ログを WireGuard 経由で会場の Local Server (192.168.11.2) に転送し、既存のログパイプラインに合流させる。

```
set system syslog host 192.168.11.2 facility local2 level info
```

## 6b. Conntrack イベントログ (r2-gcp, NAT66 / v4 SNAT 変換記録)

GCP トラフィック最適化 (詳細は [`gcp-integration.md`](gcp-integration.md) を参照) により、r2-gcp で以下の NAT が行われる:

| NAT 種別 | 変換内容 | 対象トラフィック |
|----------|---------|-----------------|
| NAT66 (IPv6) | 会場 GCP /64 src (`2600:1900:41d1:92::/64`) → r2-gcp /96 (`2600:1900:41d0:9d::/96`) | GCP /64 を src に持つ v6 トラフィック |
| v4 SNAT | 会場サブネット src (`192.168.0.0/16`) → GCE 内部 IP (`10.174.0.7`) → GCE 外部 IP (`34.97.197.104`, 1:1 NAT) | goog.json 宛の v4 トラフィック |

法執行機関からの照会が「GCE の外部 IP (`34.97.197.104`) から通信があった」「IPv6 アドレス `2600:1900:41d0:9d::xxxx` から通信があった」という形式で来た場合、r2-gcp の conntrack ログがないと内部デバイスを特定できない。

### conntrack イベントロガー (r2-gcp)

r1 と同様に `conntrack -E` で NAT 変換イベントを syslog に記録する。

#### スクリプト (`/config/scripts/conntrack-logger.sh`)

```bash
#!/bin/bash
# Conntrack イベントログ: NAT66 / v4 SNAT の変換マッピングを syslog に記録
# 対象: 会場サブネット (192.168.0.0/16) および GCP /64 (2600:1900:41d1:92::/64)
conntrack -E -e NEW,DESTROY -o timestamp 2>/dev/null | \
    grep --line-buffered -E 'src=(192\.168\.|2600:1900:41d1:92:)' | \
    logger -t conntrack-nat -p local2.info
```

#### systemd サービス

r1 と同じユニットファイル (`/etc/systemd/system/conntrack-logger.service`) を配置し有効化する。

#### syslog 転送 (r2-gcp → Local Server)

conntrack ログを WireGuard (wg2) 経由で会場の Local Server (192.168.11.2) に転送する。

```
set system syslog host 192.168.11.2 facility local2 level info
```

### 出力例

#### NAT66 (IPv6)

```
[1723286400.123456]    [NEW] udp  17 30 src=2600:1900:41d1:92::abcd dst=2607:f8b0:400a:80b::200e sport=54321 dport=443 [UNREPLIED] src=2607:f8b0:400a:80b::200e dst=2600:1900:41d0:9d::4 sport=443 dport=54321
```

読み方:
- original tuple: `src=2600:1900:41d1:92::abcd` → 会場デバイスの GCP /64 SLAAC アドレス
- reply tuple: `dst=2600:1900:41d0:9d::4` → NAT66 後の r2-gcp /96 アドレス
- 会場デバイスの SLAAC アドレス → NDP ダンプで MAC → DHCP リースで hostname を特定

#### v4 SNAT

```
[1723286400.789012]    [NEW] tcp   6 120 SYN_SENT src=192.168.40.123 dst=142.250.196.110 sport=54321 dport=443 [UNREPLIED] src=142.250.196.110 dst=10.174.0.7 sport=443 dport=12345
```

読み方:
- original tuple: `src=192.168.40.123` → 会場デバイスの内部 IPv4
- reply tuple: `dst=10.174.0.7` → SNAT 後の GCE 内部 IP (外部では `34.97.197.104`)
- GCE の 1:1 NAT により、外部から見た IP は `34.97.197.104` となる

### 照会対応

```bash
# r2-gcp の NAT66 変換: 外部 IPv6 → 会場デバイスの SLAAC アドレス
grep "conntrack-nat" /var/log/syslog | grep "dst=2600:1900:41d0:9d:"

# r2-gcp の v4 SNAT 変換: GCE 内部 IP (= 外部 34.97.197.104) → 会場デバイス
grep "conntrack-nat" /var/log/syslog | grep "dst=10.174.0.7"

# 特定内部 IP の Google 向け通信
grep "conntrack-nat" /var/log/syslog | grep "src=192.168.40.123"
```

## 7. VyOS RA 設定

IPv6 アドレス追跡のため、SLAAC と DHCPv6 を併用する。

```
# VLAN 30
set interfaces ethernet eth2 vif 30 ipv6 address autoconf
set service router-advert interface eth2.30 prefix <delegated-prefix>::/64 autonomous-flag true
set service router-advert interface eth2.30 managed-flag true
set service router-advert interface eth2.30 other-config-flag true
set service router-advert interface eth2.30 name-server <prefix>::1

# VLAN 40
set service router-advert interface eth2.40 prefix <delegated-prefix>::/64 autonomous-flag true
set service router-advert interface eth2.40 managed-flag true
set service router-advert interface eth2.40 other-config-flag true
set service router-advert interface eth2.40 name-server <prefix>::1
```

| フラグ | 値 | 効果 |
|---|---|---|
| A (autonomous) | 1 | SLAAC 有効 (iOS/Android 用) |
| M (managed) | 1 | DHCPv6 アドレス割り当て (Windows/macOS 用) |
| O (other-config) | 1 | DHCPv6 で DNS 等の追加情報取得 (iOS も対応) |
| RDNSS | 設定 | Android の DNS 解決に必須 (DHCPv6 非対応のため) |

### iOS/Android の DHCPv6 非対応について

| OS | DHCPv6 IA_NA | SLAAC | RDNSS |
|---|---|---|---|
| Windows 11 | 対応 | 対応 | 対応 |
| macOS 15 | 対応 | 対応 | 対応 |
| iOS 18 | **非対応** | 対応 | 対応 |
| Android 15 | **非対応** | 対応 | 対応 (必須) |

iOS/Android は SLAAC のみで IPv6 アドレスを取得するため、NDP テーブルダンプで IPv6 ↔ MAC の対応を記録する必要がある。

## 8. NDP テーブルダンプ

1 分間隔の cron で VyOS の IPv6 neighbor テーブルを記録。iOS/Android を含む全デバイスの IPv6 ↔ MAC 対応を取得する。

### スクリプト (`/config/scripts/ndp-dump.sh`)

```bash
#!/bin/bash
# NDP テーブルダンプ (IPv6 ↔ MAC 記録)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ip -6 neigh show | while read -r line; do
    echo "${TIMESTAMP} ${line}"
done | logger -t ndp-dump -p local1.info
```

### cron 設定

```
set system task-scheduler task ndp-dump interval 1m
set system task-scheduler task ndp-dump executable path /config/scripts/ndp-dump.sh
```

### 出力例

```
2026-08-10T14:30:00Z fe80::1a2b:3c4d:5e6f:7890 dev eth2.40 lladdr aa:bb:cc:dd:ee:ff REACHABLE
2026-08-10T14:30:00Z 2001:db8::abcd dev eth2.30 lladdr 11:22:33:44:55:66 STALE
```

## 9. nfcapd コレクター構成 (Local Server)

ローカルサーバー (192.168.11.2) で nfcapd を稼働させ、VyOS からの NetFlow を受信。

### インストール

```bash
apt install nfdump
```

### systemd ユニット (`/etc/systemd/system/nfcapd.service`)

```ini
[Unit]
Description=NetFlow Capture Daemon
After=network.target

[Service]
ExecStart=/usr/bin/nfcapd -w -D -l /var/log/nfcapd -p 2055 -T all -t 300
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

パラメータ:

- `-l /var/log/nfcapd` — 保存ディレクトリ
- `-p 2055` — 受信ポート
- `-T all` — 全拡張フィールドを記録
- `-t 300` — 5 分間隔でファイルローテーション

## 10. 転送・アーカイブ (rsyslog → GCE → GCS)

### rsyslog 転送設定 (VyOS → Local Server → GCE)

VyOS のログ (DNS クエリ、DHCP forensic、NDP ダンプ) は syslog 経由で Local Server に転送し、さらに GCE に転送。

```
# VyOS → Local Server
set system syslog host 192.168.11.2 facility all level info

# Local Server rsyslog.conf → GCE 転送 (既存パイプライン活用)
# *.* @@<gce-ip>:514
```

### nfcapd ファイル転送 (rsync)

```bash
# cron (15 分間隔)
*/15 * * * * rsync -az /var/log/nfcapd/ <gce-user>@<gce-ip>:/var/log/nfcapd/
```

### GCS 保存先

ログは保持ポリシー (Retention Policy) 付きの `bwai-compliance-logs` バケットに保存 (180 日保持、ロック済み)。詳細はセクション 11「ログ封印」を参照。

## 11. イベント終了後のログ封印

イベント終了後、ログファイルの改ざんがないことを証明するため、全ログのハッシュを取得し複数人で保存する。

### 封印スクリプト (`/config/scripts/seal-logs.sh`)

```bash
#!/bin/bash
# イベント終了後に実行: 全ログの SHA-256 ハッシュを生成
SEAL_DATE=$(date -u +"%Y%m%dT%H%M%SZ")
SEAL_FILE="/var/log/log-seal-${SEAL_DATE}.txt"

echo "=== BwAI Network Log Seal ===" > "$SEAL_FILE"
echo "Sealed at: ${SEAL_DATE}" >> "$SEAL_FILE"
echo "Sealed by: $(whoami)@$(hostname)" >> "$SEAL_FILE"
echo "" >> "$SEAL_FILE"

# NetFlow
echo "--- NetFlow (nfcapd) ---" >> "$SEAL_FILE"
find /var/log/nfcapd -type f -name "nfcapd.*" | sort | while read -r f; do
    sha256sum "$f" >> "$SEAL_FILE"
done

# DNS クエリログ
echo "--- DNS query log ---" >> "$SEAL_FILE"
sha256sum /var/log/syslog* 2>/dev/null | grep -v "No such" >> "$SEAL_FILE"

# DHCP forensic log
echo "--- DHCP forensic log ---" >> "$SEAL_FILE"
find /var/log/kea -type f -name "kea-legal*" | sort | while read -r f; do
    sha256sum "$f" >> "$SEAL_FILE"
done

# Conntrack イベントログ (r1 から転送済み)
echo "--- Conntrack NAT log ---" >> "$SEAL_FILE"
grep "conntrack-nat" /var/log/syslog* 2>/dev/null | sha256sum >> "$SEAL_FILE"

# NDP ダンプ (syslog 内)
echo "--- Seal file hash ---" >> "$SEAL_FILE"
# 封印ファイル自体のハッシュ (最終行を除く) を表示
sha256sum "$SEAL_FILE"
```

### 封印手順

1. **イベント終了直後**に封印スクリプトを実行
2. 生成された封印ファイル (`log-seal-<timestamp>.txt`) の **SHA-256 ハッシュ**を取得
3. ハッシュを**複数の NOC メンバー** (最低 2 名) がそれぞれ独立に保存
   - 個人の端末にテキストファイルとして保存
   - チャット (Slack / Discord 等) に投稿して記録
   - 写真撮影 (物理的な記録) も有効
4. RFC 3161 タイムスタンプを取得 (後述)
5. 封印ファイル + タイムスタンプ応答を GCS 保持ポリシー付きバケットにアップロード

### RFC 3161 タイムスタンプ (TSA)

信頼された第三者機関 (TSA: Time-Stamping Authority) が封印ファイルに対して署名付きタイムスタンプを発行する。電子署名法において法的効力があり、「この時点でこのデータが存在した」ことを第三者が証明できる。

```bash
# タイムスタンプ要求の生成
openssl ts -query -data /var/log/log-seal-${SEAL_DATE}.txt \
    -no_nonce -sha256 -cert -out seal.tsq

# TSA にタイムスタンプを要求 (FreeTSA.org: 無料)
curl -s -H "Content-Type: application/timestamp-query" \
    --data-binary @seal.tsq \
    https://freetsa.org/tsr -o seal.tsr

# タイムスタンプの検証
openssl ts -verify -data /var/log/log-seal-${SEAL_DATE}.txt \
    -in seal.tsr \
    -CAfile freetsa-cacert.pem \
    -untrusted freetsa-tsa.crt
```

※ FreeTSA.org の CA 証明書は事前にダウンロードしておくこと:

```bash
wget https://freetsa.org/files/cacert.pem -O freetsa-cacert.pem
wget https://freetsa.org/files/tsa.crt -O freetsa-tsa.crt
```

### GCS Retention Policy (WORM)

ログアーカイブ用の GCS バケットに保持ポリシー (Retention Policy) を設定し、保持期間中はオブジェクトの削除・上書きを物理的に不可能にする。ポリシーをロックすると、ポリシー自体の削除・短縮も不可能になる。

```bash
# バケット作成
gcloud storage buckets create gs://bwai-compliance-logs \
    --location=asia-northeast1

# 保持ポリシー設定 (180 日 = 15552000 秒)
gcloud storage buckets update gs://bwai-compliance-logs \
    --retention-period=15552000

# ポリシーをロック (不可逆: ロック後はポリシーの削除・短縮不可)
gcloud storage buckets update gs://bwai-compliance-logs \
    --lock-retention-period
```

ロック後はプロジェクトオーナーでも保持期間中のオブジェクト削除は不可能。

### 封印後のアップロード

```bash
# 封印ファイル + TSA 応答を保持ポリシー付きバケットにアップロード
gcloud storage cp /var/log/log-seal-${SEAL_DATE}.txt gs://bwai-compliance-logs/seal/
gcloud storage cp seal.tsr gs://bwai-compliance-logs/seal/
gcloud storage cp seal.tsq gs://bwai-compliance-logs/seal/
```

### 正当性証明の三層構造

| 層 | 手法 | 証明できること |
|---|---|---|
| 1. 人的証人 | SHA-256 ハッシュを複数 NOC メンバーが独立保存 | 封印時点のハッシュが合意されていたこと |
| 2. 第三者証明 | RFC 3161 TSA タイムスタンプ | 封印ファイルが特定時刻に存在し、以降改変されていないこと |
| 3. 物理的保護 | GCS Retention Policy (ロック済み) | ログ本体が保持期間中に削除・改変されていないこと |

### 検証方法

照会時にログの改ざんがないことを証明する:

```bash
# 1. 封印ファイルのハッシュを再計算し、NOC メンバーの保存済みハッシュと照合
sha256sum /var/log/log-seal-*.txt

# 2. 個別ログファイルのハッシュを封印ファイルの記録と照合
sha256sum /var/log/nfcapd/nfcapd.202608101430 | diff - <(grep "nfcapd.202608101430" /var/log/log-seal-*.txt)

# 3. TSA タイムスタンプの検証 (封印ファイルが TSA 署名時点から無改変)
openssl ts -verify -data /var/log/log-seal-*.txt -in seal.tsr \
    -CAfile freetsa-cacert.pem -untrusted freetsa-tsa.crt

# 4. GCS Retention Policy の保持状態を確認
gcloud storage objects describe gs://bwai-compliance-logs/seal/log-seal-*.txt \
    --format="value(retentionExpirationTime)"
# → 保持期限の日時が表示される
```

## 12. 保存期間とローテーション

| ログ種別 | ローカル保存 | GCE 保存 | GCS 保存 |
|---|---|---|---|
| NetFlow (nfcapd) | 30 日 | 90 日 | 180 日 |
| DNS クエリログ | 30 日 | 90 日 | 180 日 |
| DHCP forensic log | 30 日 | 90 日 | 180 日 |
| NDP テーブルダンプ | 30 日 | 90 日 | 180 日 |
| Conntrack NAT ログ (r1) | 30 日 | 90 日 | 180 日 |

ローカルのローテーション:

```bash
# /etc/logrotate.d/compliance-logs
/var/log/nfcapd/*.nfcapd {
    daily
    rotate 30
    compress
    missingok
    notifempty
}
```

## 13. 照会対応手順

### nfdump による NetFlow 検索

```bash
# 特定 IP の全通信フロー
nfdump -R /var/log/nfcapd -o long "src ip 192.168.40.123 or dst ip 192.168.40.123"

# 特定時間帯の通信
nfdump -R /var/log/nfcapd -t 2026/08/10.14:00:00-2026/08/10.15:00:00

# 特定ポートへの通信 (例: HTTPS)
nfdump -R /var/log/nfcapd "dst port 443 and src ip 192.168.40.123"

# 通信量トップ 10 (IP 別)
nfdump -R /var/log/nfcapd -s srcip -n 10
```

### DNS クエリログ検索

```bash
# 特定ドメインへのクエリを検索
grep "example.com" /var/log/syslog | grep "dns-forwarding"

# 特定クライアントのクエリ
grep "192.168.40.123" /var/log/syslog | grep "dns-forwarding"
```

### DHCP リースログ検索

```bash
# 特定 MAC アドレスのリース履歴
grep "aa:bb:cc:dd:ee:ff" /var/log/kea/kea-legal*.txt

# 特定 IP のリース履歴
grep "192.168.40.123" /var/log/kea/kea-legal*.txt
```

### NDP ダンプ検索

```bash
# 特定 MAC の IPv6 アドレス履歴
grep "aa:bb:cc:dd:ee:ff" /var/log/syslog | grep "ndp-dump"

# 特定 IPv6 アドレスの MAC 特定
grep "2001:db8::abcd" /var/log/syslog | grep "ndp-dump"
```

### Conntrack NAT ログ検索 (r1 → Local Server 転送済み)

```bash
# 特定内部 IP の NAPT 変換マッピング
grep "conntrack-nat" /var/log/syslog | grep "src=192.168.40.123"

# 特定グローバルポートからの逆引き (外部からの照会対応)
grep "conntrack-nat" /var/log/syslog | grep "dport=12345"

# 特定時間帯の全 NAT 変換
grep "conntrack-nat" /var/log/syslog | grep "1723286[4-5]"
```

### 総合追跡 (IP → デバイス → 全通信)

```bash
# Step 1: 時刻から IP を使っていた MAC を特定
grep "192.168.40.123" /var/log/kea/kea-legal*.txt

# Step 2: その MAC の IPv6 アドレスも特定
grep "<mac-address>" /var/log/syslog | grep "ndp-dump"

# Step 3: 両 IP の DNS クエリを取得
grep "192.168.40.123\|<ipv6-address>" /var/log/syslog | grep "dns-forwarding"

# Step 4: 両 IP の NetFlow を取得
nfdump -R /var/log/nfcapd "src ip 192.168.40.123 or dst ip 192.168.40.123"

# Step 5: NAPT 変換マッピングを取得 (グローバル IP:port との対応)
grep "conntrack-nat" /var/log/syslog | grep "src=192.168.40.123"
