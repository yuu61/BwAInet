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

会場掲示・配布用の本文は [`../policy/aup.md`](../policy/aup.md) に分離。本設計書は AUP に基づく記録ポリシーを規定する。

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
  ※ DHCPv6 リースログは廃止 (後述「DHCPv6 廃止について」参照)

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

### DHCPv6 (廃止)

> **廃止**: DHCPv6 サーバーは以下の理由により廃止し、IPv6 アドレス割り当ては SLAAC に一本化した。
>
> 1. **iOS/Android が DHCPv6 IA_NA 非対応** — 参加者の大半を占めるモバイルデバイスが DHCPv6 でアドレスを取得できず、SLAAC が必須
> 2. **RFC 6724 によるソースアドレス選択が OS 依存** — DHCPv6 で割り当てたアドレスが PBR (Policy-Based Routing) に使われる保証がなく、ログ追跡の信頼性が低下する
> 3. **MAC ↔ IPv6 追跡は NDP テーブルダンプでカバー済み** — SLAAC アドレスであっても NDP ダンプ (セクション 8) で IPv6 ↔ MAC の対応を記録しており、DHCPv6 リースログがなくても法執行機関対応に支障はない
>
> 以下の設定は削除済み:
>
> ```
> # (削除済み) DHCPv6 サーバー設定
> # set service dhcpv6-server shared-network-name STAFF-V6 ...
> # set service dhcpv6-server shared-network-name USER-V6 ...
> ```

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
| NAT66 (IPv6) | 会場 GCP /64 src (`2600:1900:41d1:92::/64`) → r2-gcp /96 (`2600:1900:41d0:9d::/96`)、`snat prefix to` により IID 下位 32bit を保持 | GCP /64 を src に持つ v6 トラフィック |
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
[1723286400.123456]    [NEW] udp  17 30 src=2600:1900:41d1:92:a891:4504:ae8a:591f dst=2607:f8b0:400a:80b::200e sport=54321 dport=443 [UNREPLIED] src=2607:f8b0:400a:80b::200e dst=2600:1900:41d0:9d::ae8a:591f sport=443 dport=54321
```

読み方:
- original tuple: `src=2600:1900:41d1:92:a891:4504:ae8a:591f` → 会場デバイスの GCP /64 SLAAC アドレス
- reply tuple: `dst=2600:1900:41d0:9d::ae8a:591f` → NAT66 後の r2-gcp /96 アドレス (IID 下位 32bit `ae8a:591f` が保持される)
- `snat prefix to /96` により外部 IP の下位 32bit から元デバイスを特定可能 (IID 下位 32bit 衝突は SLAAC ランダム生成のため会場規模では事実上発生しない)
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

IPv6 アドレスは SLAAC で割り当てる。DHCPv6 は廃止したため M flag は無効化済み。

```
# VLAN 30
set interfaces ethernet eth2 vif 30 ipv6 address autoconf
set service router-advert interface eth2.30 prefix <delegated-prefix>::/64 autonomous-flag true
set service router-advert interface eth2.30 other-config-flag true
set service router-advert interface eth2.30 name-server <prefix>::1

# VLAN 40
set service router-advert interface eth2.40 prefix <delegated-prefix>::/64 autonomous-flag true
set service router-advert interface eth2.40 other-config-flag true
set service router-advert interface eth2.40 name-server <prefix>::1
```

> **変更点**: `managed-flag true` を削除。DHCPv6 サーバー廃止に伴い M flag を無効化し、SLAAC に一本化した。

| フラグ | 値 | 効果 |
|---|---|---|
| A (autonomous) | 1 | SLAAC 有効 (全 OS 共通) |
| M (managed) | 0 (デフォルト) | DHCPv6 アドレス割り当て無効 (DHCPv6 廃止のため) |
| O (other-config) | 1 | DHCPv6 で DNS 等の追加情報取得 (対応 OS 向け) |
| RDNSS | 設定 | Android の DNS 解決に必須 (DHCPv6 非対応のため) |

### DHCPv6 廃止について

DHCPv6 サーバーは廃止し、IPv6 アドレス割り当ては SLAAC に一本化した。理由は以下の通り:

1. **iOS/Android が DHCPv6 IA_NA 非対応** — 参加者の大半を占めるモバイルデバイスが DHCPv6 でアドレスを取得できない
2. **RFC 6724 によるソースアドレス選択が OS 依存** — DHCPv6 で割り当てたアドレスが PBR に使われる保証がなく、Windows/macOS でも SLAAC アドレスが選択される場合がある
3. **MAC ↔ IPv6 追跡は NDP テーブルダンプでカバー済み** — セクション 8 の NDP ダンプにより全デバイスの IPv6 ↔ MAC 対応を記録しており、DHCPv6 リースログは不要

| OS | DHCPv6 IA_NA | SLAAC | RDNSS |
|---|---|---|---|
| Windows 11 | 対応 | 対応 | 対応 |
| macOS 15 | 対応 | 対応 | 対応 |
| iOS 18 | **非対応** | 対応 | 対応 |
| Android 15 | **非対応** | 対応 | 対応 (必須) |

全デバイスが SLAAC で IPv6 アドレスを取得するため、NDP テーブルダンプ (セクション 8) で IPv6 ↔ MAC の対応を記録する。

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

## 9. local-server CT 構成

### 概要

local-server は**法執行対応ログ集約専用**の LXC CT である。rsyslog (syslog アグリゲータ) と nfcapd (NetFlow コレクタ) のみを稼働させ、運用監視ツール (Zabbix, Grafana, SNMP Exporter 等) は配置しない。運用監視は別 VM (zabbix-grafana, VM 101) で行う。詳細は [`venue-proxmox.md`](venue-proxmox.md) を参照。

### CT 基本設定

| 項目 | 値 | 備考 |
|------|-----|------|
| VMID | 200 | VM 100-102 と重複しない番号帯 |
| 名称 | `local-server` | |
| 種別 | LXC CT | データ永続化に問題なし (rootfs/mp は Proxmox ストレージ上に永続化) |
| OS テンプレート | Debian 12 (Bookworm) | Proxmox 標準テンプレート |
| vCPU | 2 | nfcapd + rsyslog は CPU 軽量 |
| RAM | 8GB | rsyslog バッファリング + nfcapd I/O キャッシュ |
| Root Disk | 16GB (NVMe #1 thin pool) | OS + ツールのみ |
| Data Mount | NVMe #2 512GB → `/mnt/data` (CT 内) | Proxmox storage pool 経由でマウント |
| Network | `net0: name=eth0,bridge=vmbr_trunk,tag=11,ip=192.168.11.2/24,gw=192.168.11.1` | mgmt VLAN |
| DNS | 192.168.11.1 (r3) | |

### NVMe #2 マウント (Proxmox storage pool)

NVMe #2 を Proxmox の directory ストレージとして追加し、CT のマウントポイントとして提供する。

```bash
# ホスト側: NVMe #2 をフォーマット (初回のみ)
# ※ デバイス名は実機確認が必要 (nvme1n1 等)
mkfs.ext4 -L data-nvme2 /dev/nvme1n1

# ホスト側: マウントポイント作成
mkdir -p /mnt/data-nvme2
echo 'LABEL=data-nvme2 /mnt/data-nvme2 ext4 defaults,noatime 0 2' >> /etc/fstab
mount /mnt/data-nvme2

# Proxmox storage pool として追加
pvesm add dir data-nvme2 --path /mnt/data-nvme2 --content rootdir
```

CT config に mount point を追加:

```
# /etc/pve/lxc/200.conf
mp0: data-nvme2:subvol-200-disk-0,mp=/mnt/data,size=500G
```

CT 内でのシンボリックリンク:

```bash
# CT 内: /var/log 配下からデータドライブへリンク
ln -s /mnt/data/nfcapd /var/log/nfcapd
ln -s /mnt/data/syslog-archive /var/log/syslog-archive
ln -s /mnt/data/kea /var/log/kea
```

### NVMe #2 ディレクトリ構造

```
/mnt/data (NVMe #2, ext4, 512GB)
├── nfcapd/                  ← NetFlow v9 ファイル (5 分ローテ)
│   └── nfcapd.YYYYMMDDHHMMSS
├── syslog-archive/          ← rsyslog 出力 (facility 別分離)
│   ├── dns/                 ← DNS クエリログ (facility 0, tag: dns-forwarding)
│   │   └── dns.log
│   ├── conntrack/           ← conntrack NAT ログ (facility local2)
│   │   └── conntrack.log
│   ├── ndp/                 ← NDP テーブルダンプ (facility local1)
│   │   └── ndp.log
│   ├── dhcp/                ← DHCP リースログ
│   │   └── dhcp.log
│   └── all.log              ← 全ログ保険コピー (全 facility)
└── kea/                     ← Kea forensic log (r3 から転送)
    └── kea-legal.YYYYMMDDHHMMSS.txt
```

### rsyslog 設定 (local-server CT 内)

`/etc/rsyslog.d/10-forensic.conf`:

```
# TCP で受信 (r3, r1, r2-gcp からの syslog)
module(load="imtcp")
input(type="imtcp" port="514")

# --- facility 別ファイル出力 (NVMe #2) ---

# DNS クエリログ (PowerDNS Recursor, facility 0)
:syslogtag, contains, "pdns_recursor" /var/log/syslog-archive/dns/dns.log

# NDP テーブルダンプ (facility local1)
local1.* /var/log/syslog-archive/ndp/ndp.log

# Conntrack NAT ログ (facility local2, r1 + r2-gcp)
local2.* /var/log/syslog-archive/conntrack/conntrack.log

# DHCP リースログ (Kea, facility daemon)
:syslogtag, contains, "kea-dhcp4" /var/log/syslog-archive/dhcp/dhcp.log

# 全ログ保険コピー (照会時のフォールバック)
*.* /var/log/syslog-archive/all.log

# --- 運用可視化: Alloy (zabbix-grafana VM) に転送 ---
*.* @@192.168.11.6:1514
```

- **TCP (`@@`)** を使用 — ログ損失防止
- **暗号化なし** — 同一 VLAN 11 内の通信、TLS 不要
- Alloy への転送はポート `1514` (Alloy の syslog receiver、デフォルトポートとの衝突回避)

### パッケージインストール

```bash
apt update && apt install -y \
    nfdump \
    rsyslog \
    google-cloud-cli \
    ca-certificates \
    curl
```

## 10. nfcapd コレクター設定

local-server CT (192.168.11.2) で nfcapd を稼働させ、VyOS (r3) からの NetFlow を受信する。nfcapd データは NVMe #2 上の `/var/log/nfcapd/` に保存する。

### ディレクトリ準備

```bash
mkdir -p /var/log/nfcapd
```

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

- `-l /var/log/nfcapd` — 保存ディレクトリ (NVMe #2 上、シンボリックリンク経由)
- `-p 2055` — 受信ポート
- `-T all` — 全拡張フィールドを記録
- `-t 300` — 5 分間隔でファイルローテーション

## 11. 転送・アーカイブ (local-server → GCS 直送)

### 全体転送フロー

```
[イベント期間中: 継続的 GCS アップロード]
  VyOS (r3)  ──syslog──→ local-server CT (rsyslog) ──→ ファイル保存 (NVMe #2)
  VyOS (r3)  ──NetFlow──→ local-server CT (nfcapd)  ──→ ファイル保存 (NVMe #2)
  r1         ──syslog──→ local-server CT (rsyslog)   ──→ ファイル保存 (NVMe #2)
  r2-gcp     ──syslog──→ local-server CT (rsyslog)   ──→ ファイル保存 (NVMe #2)
                                                           │
                                                           └──→ gcloud storage rsync (5-15 分間隔)
                                                                  ↓
                                                           gs://bwai-forensic-2026/

[運用可視化 (法執行ログとは独立)]
  local-server CT (rsyslog) ──forward──→ Grafana Alloy (VM 101) → Grafana ダッシュボード
```

旧設計では local-server → GCE → GCS の 3 段階転送を想定していたが、GCE 中継は廃止し **local-server から GCS への直送** に簡素化した。理由:

- venue Proxmox は借用機であり、イベント後に全データを取り出して初期化する必要がある。GCS にイベント中から継続的にアップロードしておくことで、搬送中の物理障害リスクを低減する
- GCE 中継を挟む必要性が薄い（GCS への直送で十分、中間ノードの管理コスト削減）

### rsyslog 転送設定 (VyOS → local-server)

```
# VyOS (r3) → local-server CT
set system syslog host 192.168.11.2 facility all level info
```

r1 および r2-gcp の conntrack ログも同じ宛先に転送する (セクション 6, 6b 参照)。

### rsyslog → Grafana Alloy 転送 (運用可視化用)

local-server の rsyslog から zabbix-grafana VM (192.168.11.6) 上の Alloy にログを forward する。これにより Grafana でログのリアルタイム可視化が可能になる。**ログの原本はあくまで local-server 側に保持され、Alloy は運用可視化のための読み取り専用の経路** である。

```
# local-server rsyslog.conf (運用可視化用転送)
*.* @@192.168.11.6:<alloy-syslog-port>
```

### GCS 認証 (サービスアカウント)

local-server CT から GCS へ書き込むためのサービスアカウントを作成する。

```bash
# SA 作成 (GCP プロジェクト側で事前実施)
gcloud iam service-accounts create sa-forensic-writer \
    --display-name="Forensic Log Writer"

# forensic バケットへの書き込み権限のみ付与 (削除不可)
gcloud storage buckets add-iam-policy-binding gs://bwai-forensic-2026 \
    --member="serviceAccount:sa-forensic-writer@<project>.iam.gserviceaccount.com" \
    --role="roles/storage.objectCreator"

# SA キー発行
gcloud iam service-accounts keys create /etc/gcs-sa-key.json \
    --iam-account=sa-forensic-writer@<project>.iam.gserviceaccount.com
```

local-server CT 内で認証を有効化:

```bash
gcloud auth activate-service-account --key-file=/etc/gcs-sa-key.json
```

権限を `objectCreator` に限定しているため、SA キーが漏洩しても既存オブジェクトの削除・上書きはできない。キーファイルは venue Proxmox のディスクワイプ時に自動的に消去される。

### GCS 継続アップロード

イベント期間中、local-server から GCS へ 5-15 分間隔で差分同期を行う。イベント終了後の一括転送ではなく、**継続的にアップロード** することで、venue Proxmox の搬送中に物理障害が発生しても GCS 側にデータが残る。

`/etc/cron.d/gcs-sync`:

```bash
*/5  * * * * root gcloud storage rsync -r /var/log/nfcapd/         gs://bwai-forensic-2026/live/nfcapd/    >> /var/log/gcs-sync.log 2>&1
*/5  * * * * root gcloud storage rsync -r /var/log/syslog-archive/ gs://bwai-forensic-2026/live/syslog/    >> /var/log/gcs-sync.log 2>&1
*/15 * * * * root gcloud storage rsync -r /var/log/kea/            gs://bwai-forensic-2026/live/kea-legal/ >> /var/log/gcs-sync.log 2>&1
```

### GCS アップロード失敗検知

Zabbix agent (zabbix-grafana VM 上) で `/var/log/gcs-sync.log` を監視し、`ERROR` や `FAILED` を検知したらアラートを発報する。

Zabbix 側の設定:

- **Item**: `log[/var/log/gcs-sync.log,"ERROR|FAILED",,,,]` (log 型、active agent)
- **Trigger**: `{local-server:log[...].logseverity()} >= 4` → Severity: Warning
- **Action**: Google Chat webhook で NOC に通知

※ local-server 上で Zabbix agent を稼働させ、zabbix-grafana VM の Zabbix Server に接続する。agent は監視用途のみで、forensic ログの責務には影響しない。

### GCS 保存先

法執行対応ログは年度別の forensic バケットに保存する。保持ポリシー (Retention Policy) のロックはイベント終了後の最終検証完了時に行う（セクション 11 参照）。

```
gs://bwai-forensic-2026/
  live/                    ← イベント中の継続アップロード
    nfcapd/
    syslog/
    kea-legal/
  seal/                    ← 封印ファイル + TSA 応答
    preliminary/           ← 会場での予備封印
    final/                 ← 自宅ラボでの最終封印
```

運用監視データ (Zabbix DB ダンプ等) は別バケット `gs://bwai-monitoring-2026/` に保存し、WORM ロックは掛けない。

## 12. イベント終了後のログ封印

イベント終了後、ログファイルの改ざんがないことを証明するため、全ログのハッシュを取得し複数人で保存する。

### 重要: 借用機制約

venue Proxmox (Minisforum MS-01) は**借用機**であり、イベント終了後に以下のフローで処理する:

1. 会場で電源オフ
2. 自宅ラボへ物理搬送
3. 自宅ラボで起動し、**GCS への転送完了を確認**
4. 転送完了確認後に初期化（ディスクワイプ）
5. 借用元へ返送

**初期化は GCS 転送の完了確認が取れるまで行わない。** 初期化後はローカルデータが不可逆に失われるため、GCS 側のオブジェクト数・サイズ・ハッシュが local-server のローカルデータと一致することを検証してから進める。

封印は **2 段階** で実施する:

1. **予備封印 (会場、電源オフ前)**: イベント終了直後に local-server CT 上で実施。搬送中の改ざん検知の基準点となる
2. **最終封印 (自宅ラボ)**: GCS への最終アップロード・検証完了後に実施。照会対応の正式な根拠となる

GCS Retention Policy のロックは**最終封印・検証完了後**に行う。予備封印の時点ではロックしない（自宅ラボからの追加アップロードの余地を残すため）。

### 封印スクリプト (`seal-logs.sh`)

local-server CT 上で実行する。

```bash
#!/bin/bash
# 全ログの SHA-256 ハッシュを生成
SEAL_PHASE="${1:-preliminary}"  # "preliminary" or "final"
SEAL_DATE=$(date -u +"%Y%m%dT%H%M%SZ")
SEAL_FILE="/var/log/log-seal-${SEAL_PHASE}-${SEAL_DATE}.txt"

echo "=== BwAI Network Log Seal ===" > "$SEAL_FILE"
echo "Phase: ${SEAL_PHASE}" >> "$SEAL_FILE"
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
sha256sum /var/log/syslog-archive/* 2>/dev/null | grep -v "No such" >> "$SEAL_FILE"

# DHCP forensic log
echo "--- DHCP forensic log ---" >> "$SEAL_FILE"
find /var/log/kea -type f -name "kea-legal*" | sort | while read -r f; do
    sha256sum "$f" >> "$SEAL_FILE"
done

# Conntrack イベントログ (r1/r2-gcp から転送済み)
echo "--- Conntrack NAT log ---" >> "$SEAL_FILE"
grep "conntrack-nat" /var/log/syslog-archive/* 2>/dev/null | sha256sum >> "$SEAL_FILE"

# NDP ダンプ
echo "--- NDP dump ---" >> "$SEAL_FILE"
grep "ndp-dump" /var/log/syslog-archive/* 2>/dev/null | sha256sum >> "$SEAL_FILE"

echo "" >> "$SEAL_FILE"
echo "--- Seal file hash ---" >> "$SEAL_FILE"
sha256sum "$SEAL_FILE"
```

### 封印手順 (2 段階)

#### Phase 1: 予備封印 (会場、電源オフ前)

1. イベント終了直後、local-server CT 上で封印スクリプトを実行
   ```bash
   bash seal-logs.sh preliminary
   ```
2. 予備封印ファイルの SHA-256 ハッシュを取得
3. NOC メンバー **2 名以上** がハッシュを独立保存 (Google Chat 投稿、端末テキスト保存、写真撮影)
4. RFC 3161 タイムスタンプを取得
5. 予備封印ファイル + TSA 応答を GCS にアップロード
   ```bash
   gcloud storage cp /var/log/log-seal-preliminary-*.txt gs://bwai-forensic-2026/seal/preliminary/
   gcloud storage cp seal.tsr gs://bwai-forensic-2026/seal/preliminary/
   ```
6. 最終 GCS rsync を実行し、差分ゼロを確認
7. venue Proxmox を電源オフ

#### Phase 2: 最終封印 (自宅ラボ)

1. 自宅ラボで venue Proxmox を起動し local-server CT を開始
2. 予備封印ファイルのハッシュを再計算し、搬送前の記録と一致することを確認（搬送中の改ざん検知）
3. GCS 側のオブジェクト数・サイズを確認し、欠損があれば追加アップロード
4. 最終封印スクリプトを実行
   ```bash
   bash seal-logs.sh final
   ```
5. 最終封印ファイルの SHA-256 ハッシュを取得
6. NOC メンバー **2 名以上** がハッシュを独立保存
7. RFC 3161 タイムスタンプを取得
8. 最終封印ファイル + TSA 応答を GCS にアップロード
   ```bash
   gcloud storage cp /var/log/log-seal-final-*.txt gs://bwai-forensic-2026/seal/final/
   gcloud storage cp seal.tsr gs://bwai-forensic-2026/seal/final/
   ```
9. **GCS 転送完了の検証** (初期化前の最終ゲート)
   ```bash
   # ローカルファイル数と GCS オブジェクト数の突き合わせ
   LOCAL_COUNT=$(find /var/log/nfcapd /var/log/syslog-archive /var/log/kea -type f | wc -l)
   GCS_COUNT=$(gcloud storage ls -r gs://bwai-forensic-2026/live/ | wc -l)
   echo "Local: ${LOCAL_COUNT}, GCS: ${GCS_COUNT}"
   # → 一致していることを確認。不一致の場合は追加アップロード

   # サンプリングハッシュ検証 (任意のファイルを GCS からダウンロードしてハッシュ照合)
   gcloud storage cp gs://bwai-forensic-2026/live/nfcapd/nfcapd.YYYYMMDDHHMMSS /tmp/
   sha256sum /tmp/nfcapd.YYYYMMDDHHMMSS
   sha256sum /var/log/nfcapd/nfcapd.YYYYMMDDHHMMSS
   # → 一致していることを確認
   ```
10. **GCS Retention Policy をロック** (不可逆)
    ```bash
    gcloud storage buckets update gs://bwai-forensic-2026 \
        --retention-period=15552000 --lock-retention-period
    ```
11. **venue Proxmox (MS-01) のディスクをワイプ** — 転送完了確認・WORM ロック完了後にのみ実施
12. 借用元へ返送

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

法執行対応ログ用の GCS バケットに保持ポリシー (Retention Policy) を設定し、保持期間中はオブジェクトの削除・上書きを物理的に不可能にする。ポリシーをロックすると、ポリシー自体の削除・短縮も不可能になる。

**重要**: Retention Policy のロックは**不可逆**であり、ロック後 180 日間の課金が確定する。**最終封印・検証完了後** (Phase 2 ステップ 9) に行うこと。イベント期間中やアップロード途中でロックしない。

```bash
# バケット作成 (イベント前に実施)
gcloud storage buckets create gs://bwai-forensic-2026 \
    --location=asia-northeast1

# 保持ポリシー設定 (180 日 = 15552000 秒、ロックはまだ掛けない)
gcloud storage buckets update gs://bwai-forensic-2026 \
    --retention-period=15552000

# ポリシーのロックは Phase 2 (自宅ラボでの最終封印) 完了後に実施
# gcloud storage buckets update gs://bwai-forensic-2026 \
#     --lock-retention-period
```

ロック後はプロジェクトオーナーでも保持期間中のオブジェクト削除は不可能。

### 正当性証明の三層構造

| 層 | 手法 | 証明できること |
|---|---|---|
| 1. 人的証人 | SHA-256 ハッシュを複数 NOC メンバーが独立保存 | 封印時点のハッシュが合意されていたこと |
| 2. 第三者証明 | RFC 3161 TSA タイムスタンプ | 封印ファイルが特定時刻に存在し、以降改変されていないこと |
| 3. 物理的保護 | GCS Retention Policy (ロック済み) | ログ本体が保持期間中に削除・改変されていないこと |

### 検証方法

照会時にログの改ざんがないことを証明する。照会対応は GCS 上のデータのみで完結する (venue Proxmox は借用機のため返却済み)。

```bash
# 1. 最終封印ファイルのハッシュを再計算し、NOC メンバーの保存済みハッシュと照合
gcloud storage cp gs://bwai-forensic-2026/seal/final/log-seal-final-*.txt /tmp/
sha256sum /tmp/log-seal-final-*.txt

# 2. GCS 上の個別ログファイルのハッシュを封印ファイルの記録と照合
gcloud storage cp gs://bwai-forensic-2026/live/nfcapd/nfcapd.202608101430 /tmp/
sha256sum /tmp/nfcapd.202608101430 | diff - <(grep "nfcapd.202608101430" /tmp/log-seal-final-*.txt)

# 3. TSA タイムスタンプの検証 (封印ファイルが TSA 署名時点から無改変)
gcloud storage cp gs://bwai-forensic-2026/seal/final/seal.tsr /tmp/
openssl ts -verify -data /tmp/log-seal-final-*.txt -in /tmp/seal.tsr \
    -CAfile freetsa-cacert.pem -untrusted freetsa-tsa.crt

# 4. GCS Retention Policy の保持状態を確認
gcloud storage objects describe gs://bwai-forensic-2026/seal/final/log-seal-final-*.txt \
    --format="value(retentionExpirationTime)"
# → 保持期限の日時が表示される
```

## 13. 保存期間とローテーション

### 保存場所と保持期間

venue Proxmox (MS-01) は**借用機**であり、イベント終了後に自宅ラボへ搬送し、**GCS 転送完了を確認してから**初期化・返送する。ローカル保存はイベント期間中〜自宅ラボでの転送完了確認までとし、長期保管は GCS で行う。GCE 中継は廃止した。

| ログ種別 | ローカル保存 (local-server CT, NVMe #2) | GCS 保存 (`bwai-forensic-2026`) |
|---|---|---|
| NetFlow (nfcapd) | イベント期間中のみ | **180 日 (WORM)** |
| DNS クエリログ | イベント期間中のみ | **180 日 (WORM)** |
| DHCP forensic log | イベント期間中のみ | **180 日 (WORM)** |
| NDP テーブルダンプ | イベント期間中のみ | **180 日 (WORM)** |
| Conntrack NAT ログ (r1) | イベント期間中のみ | **180 日 (WORM)** |
| Conntrack NAT ログ (r2-gcp) | イベント期間中のみ | **180 日 (WORM)** |

### ローカルのローテーション

イベント期間中（通常 1-2 日）はローテーション不要。ただし nfcapd は `-t 300` で 5 分間隔のファイルローテーションを内部で行う。

### イベント後のデータ取り出し

1. 会場で予備封印 → 電源オフ
2. 自宅ラボに搬送
3. local-server CT を起動し、GCS への最終同期・検証を実施
4. 最終封印 → GCS WORM ロック
5. **GCS 転送完了を検証**（ファイル数・サイズ・サンプルハッシュの一致確認）
6. 確認完了後、venue Proxmox (MS-01) のディスクをワイプ → 借用元へ返送

**注意**: 初期化はステップ 5 の転送完了確認が取れるまで行わない。初期化後はローカルデータが不可逆に失われる。

詳細はセクション 11「ログ封印」および [`venue-proxmox.md`](venue-proxmox.md) を参照。

## 14. 照会対応手順

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
