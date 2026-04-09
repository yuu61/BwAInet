# 会場 VyOS (r3) 設計書

## 概要

r3-vyos は会場 Proxmox サーバー上の VM として動作する VyOS ルーター。会場ネットワークの中核として以下を担う:

- VLAN 間ルーティング (VLAN 11/30/40)
- DNS フォワーディング / DHCP サーバー
- WireGuard VPN (自宅 r1 との接続)
- BGP (デフォルトルート受信)
- ファイアウォール (inter-VLAN ACL)
- NetFlow v9 (通信ログ)
- NDP テーブルダンプ (IPv6 追跡)

VM リソース: 3 vCPU, 4GB RAM。詳細は [`venue-proxmox.md`](venue-proxmox.md) を参照。

> **NIC 命名について**: Proxmox VM では `net2` (virtio, トランク) と `net3` (virtio, WAN アップリンク) を定義する。Linux カーネルのインターフェース enumeration の結果、VyOS 内部では **`eth1`** が WAN 側 virtio NIC、**`eth2`** がトランク側 virtio NIC となる。`eth0` は存在しない。再起動時の命名揺らぎを防ぐため、両方とも `hw-id` で MAC を固定する。

## 1. インターフェース

### 物理マッピング (Proxmox)

| VyOS IF | Proxmox での接続 | 物理 NIC | hw-id | 役割 |
|---------|----------------|---------|-------|------|
| eth1 | virtio-net (`net3`, `bridge=vmbr_wan,queues=4`) | Realtek RTL8156B USB 2.5GbE (nic1, ブリッジ経由) | `bc:24:11:76:48:ac` | アップリンク (→ blackbox) |
| eth2 | virtio-net (`net2`, `bridge=vmbr_trunk,trunks=2-4094,queues=4`) | Realtek RTL8111H オンボード (nic0, ブリッジ経由) | `bc:24:11:ea:46:88` | VLAN トランク (→ PoE スイッチ) |

- **eth1**: USB 2.5GbE NIC をホスト側 `vmbr_wan` ブリッジに収容し、virtio-net で VM に提供。vhost-net によるゼロコピー転送で高スループットを実現。`queues=4` で virtio multiqueue を有効化
- **eth2**: Proxmox の VLAN-aware ブリッジ `vmbr_trunk` をトランクで受け、VyOS 内部で `vif 11/30/40` を自力で tag 付けする。VM NIC 設定の `trunks=2-4094` により tap に VLAN 2-4094 が登録され、VLAN-aware ブリッジで drop されない

### VLAN サブインターフェース (eth2)

| VIF | VLAN ID | アドレス (v4) | IPv6 | 用途 |
|-----|---------|--------------|------|------|
| eth2.11 | 11 | 192.168.11.1/24 | なし | 管理 (mgmt) |
| eth2.30 | 30 | 192.168.30.1/24 | OPTAGE /64 `::1`, GCP /64 `::1` | 運営 (staff + live) |
| eth2.40 | 40 | 192.168.40.1/22 | OPTAGE /64 `::2`, GCP /64 `::2` | 来場者 (user) |

### WireGuard

| パラメータ | 値 |
|-----------|-----|
| インターフェース | wg0 |
| アドレス | 10.255.0.2/30 |
| MTU | 1400 |
| ポート | 51820 |
| ピア | r1 (自宅 VyOS) |

```
# === インターフェース ===

# アップリンク (virtio-net, vmbr_wan 経由で USB NIC → blackbox, DHCP)
set interfaces ethernet eth1 address dhcp
set interfaces ethernet eth1 description 'Uplink to blackbox (virtio via vmbr_wan)'
set interfaces ethernet eth1 hw-id 'bc:24:11:76:48:ac'
set interfaces ethernet eth1 offload gro
set interfaces ethernet eth1 offload gso
set interfaces ethernet eth1 offload sg
set interfaces ethernet eth1 offload tso

# VLAN トランク (virtio-net, vmbr_trunk 経由で PoE スイッチへ)
set interfaces ethernet eth2 description 'VLAN trunk to PoE switch'
set interfaces ethernet eth2 hw-id 'bc:24:11:ea:46:88'

# VLAN 11 (mgmt - v4 only)
set interfaces ethernet eth2 vif 11 address 192.168.11.1/24
set interfaces ethernet eth2 vif 11 description 'VLAN 11 - mgmt'

# VLAN 30 (staff + live)
set interfaces ethernet eth2 vif 30 address 192.168.30.1/24
set interfaces ethernet eth2 vif 30 address <gcp-prefix>::1/64
set interfaces ethernet eth2 vif 30 description 'VLAN 30 - staff + live'

# VLAN 40 (user)
set interfaces ethernet eth2 vif 40 address 192.168.40.1/22
set interfaces ethernet eth2 vif 40 address <gcp-prefix>::2/64
set interfaces ethernet eth2 vif 40 description 'VLAN 40 - user'

# WireGuard (自宅 VPN)
set interfaces wireguard wg0 address 10.255.0.2/30
set interfaces wireguard wg0 mtu 1400
set interfaces wireguard wg0 port 51820
set interfaces wireguard wg0 private-key <r3-private-key>
set interfaces wireguard wg0 description 'VPN to home (r1)'
set interfaces wireguard wg0 peer r1 public-key <r1-public-key>
set interfaces wireguard wg0 peer r1 allowed-ips 0.0.0.0/0
set interfaces wireguard wg0 peer r1 allowed-ips ::/0
set interfaces wireguard wg0 peer r1 endpoint '<自宅グローバルIP>:51820'
set interfaces wireguard wg0 peer r1 persistent-keepalive 25

# WireGuard (GCP r2-gcp)
# listen port は wstunnel コンテナ (allow-host-networks で 127.0.0.1:51821 を bind) との
# UDP ポート衝突を回避するため 51822 を使用する
set interfaces wireguard wg1 address 10.255.2.1/30
set interfaces wireguard wg1 mtu 1400
set interfaces wireguard wg1 port 51822
set interfaces wireguard wg1 private-key <r3-private-key>
set interfaces wireguard wg1 description 'VPN to GCP (r2-gcp)'
set interfaces wireguard wg1 peer r2-gcp public-key <r2-public-key>
# wg1 peer r2-gcp: VyOS config には address/port を設定しない
# VyOS が自動作成する escape route (eth1 経由) は blackbox の UDP ブロックで失敗する
# 代わりに wg-r1-tracker.sh で wg set + ip route replace を使い、
# wg0 (r1) 経由の double encapsulation パスを構成する
set interfaces wireguard wg1 peer r2-gcp allowed-ips 0.0.0.0/0
set interfaces wireguard wg1 peer r2-gcp allowed-ips ::/0
# address/port は設定しない → wg-r1-tracker.sh が管理
set interfaces wireguard wg1 peer r2-gcp persistent-keepalive 25
```

## 2. DHCP サーバー (v4)

### VLAN 11 (mgmt)

AP 等の管理機器向け。静的割り当ては [`mgmt-vlan-address.md`](mgmt-vlan-address.md) を参照。

| 項目 | 値 |
|------|-----|
| レンジ | 192.168.11.20 – .199 |
| GW | 192.168.11.1 |
| DNS | 192.168.11.1 |
| リース | 3600s (default) / 7200s (max) |

### VLAN 30 (staff)

| 項目 | 値 |
|------|-----|
| レンジ | 192.168.30.100 – .254 |
| GW | 192.168.30.1 |
| DNS | 192.168.30.1 |
| リース | 3600s |

### VLAN 40 (user)

| 項目 | 値 |
|------|-----|
| レンジ | 192.168.40.100 – 192.168.43.254 |
| GW | 192.168.40.1 |
| DNS | 192.168.40.1 |
| リース | 3600s |

```
# === DHCP サーバー ===

# VLAN 11 (mgmt)
set service dhcp-server shared-network-name MGMT subnet 192.168.11.0/24 range 0 start 192.168.11.20
set service dhcp-server shared-network-name MGMT subnet 192.168.11.0/24 range 0 stop 192.168.11.199
set service dhcp-server shared-network-name MGMT subnet 192.168.11.0/24 default-router 192.168.11.1
set service dhcp-server shared-network-name MGMT subnet 192.168.11.0/24 name-server 192.168.11.1
set service dhcp-server shared-network-name MGMT subnet 192.168.11.0/24 lease 3600

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

### Forensic Log (Kea hook)

VyOS 内蔵 Kea の設定ファイル (`/etc/kea/kea-dhcp4.conf`) に直接 hook を追加し、リース操作を記録する。詳細は [`logging-compliance.md`](logging-compliance.md) セクション 4 を参照。

## 3. DNS フォワーディング

VyOS 内蔵 PowerDNS Recursor をフルリゾルバ（再帰解決）として使用。全 VLAN および VyOS 自身からのクエリを受け付ける。上流フォワーダーは指定せず、ルートから再帰解決する。`dns forwarding system` は `system name-server` が自分自身の場合にフォワーディングループを起こすため使用しない（r1 と同様）。クエリログは法執行機関対応のため有効化。

```
# === DNS フォワーディング (フルリゾルバ) ===

set service dns forwarding listen-address 192.168.11.1
set service dns forwarding listen-address 192.168.30.1
set service dns forwarding listen-address 192.168.40.1
set service dns forwarding listen-address 127.0.0.1

# IPv6 listen-address (OPTAGE /64 + GCP /64)
set service dns forwarding listen-address <optage-prefix>::1
set service dns forwarding listen-address <optage-prefix>::2
set service dns forwarding listen-address <gcp-prefix>::1
set service dns forwarding listen-address <gcp-prefix>::2

set service dns forwarding allow-from 192.168.11.0/24
set service dns forwarding allow-from 192.168.30.0/24
set service dns forwarding allow-from 192.168.40.0/22
set service dns forwarding allow-from 127.0.0.0/8

# IPv6 allow-from
set service dns forwarding allow-from <optage-prefix>::/64
set service dns forwarding allow-from <gcp-prefix>::/64

# クエリログ有効化 (法執行対応)
set service dns forwarding options 'log-common-errors=yes'
set service dns forwarding options 'quiet=no'
set service dns forwarding options 'logging-facility=0'
```

## 4. IPv6 / RA / DHCPv6

### デュアルプレフィックス構成

VLAN 30/40 では **2 つの IPv6 GUA プレフィックス** を RA で同時広告する:

| プレフィックス | 取得元 | 経路 | preferred-lifetime | valid-lifetime |
|---|---|---|---|---|
| OPTAGE /64 (`<optage-prefix>::/64`) | r1 DHCPv6-PD | wg0 → r1 → OPTAGE → Internet | 14400 (4h) | 86400 (24h) |
| GCP /64 (`2600:1900:41d1:92::/64`) | GCP サブネット (venue-v6-transit) | wg1 → r2-gcp → NAT66 → Google backbone | 1800 (30m) | 14400 (4h) |

端末は SLAAC で両プレフィックスの GUA を取得する。OS の source address selection (RFC 6724) で通常は preferred-lifetime が長い OPTAGE が優先される。r3 の source-based PBR (セクション 4a) で src prefix に応じて出口を振り分けるため、どちらが選ばれても通信は成立する。

VLAN 11 は v4 only。

> **RFC 8028 問題**: マルチプレフィックス環境では「プレフィックスとゲートウェイの紐付けが OS 側で保証されない」問題がある。本設計では r3 が唯一のゲートウェイであり、PBR で src prefix を見て振り分けるため、クライアント側の source address selection に依存しない。詳細は [`gcp-integration.md`](gcp-integration.md) セクション 4 を参照。

### RA (Router Advertisement)

SLAAC のみでアドレス配布する (DHCPv6 は廃止済み、後述)。

| フラグ | 値 | 効果 |
|---|---|---|
| A (autonomous) | 1 | SLAAC 有効 |
| ~~M (managed)~~ | ~~1~~ **0** | ~~DHCPv6 アドレス割り当て~~ 廃止 (iOS/Android 非対応) |
| O (other-config) | 1 | RDNSS 非対応クライアントの保険 |
| RDNSS | 設定 | Android DNS 解決に必須 |

```
# === RA (デュアルプレフィックス) ===

# VLAN 30 — OPTAGE /64 (優先: preferred-lifetime 長め)
set service router-advert interface eth2.30 prefix <optage-prefix>::/64 preferred-lifetime 14400
set service router-advert interface eth2.30 prefix <optage-prefix>::/64 valid-lifetime 86400

# VLAN 30 — GCP /64 (非優先: preferred-lifetime 短め → RFC 6724 で後回し)
set service router-advert interface eth2.30 prefix 2600:1900:41d1:92::/64 preferred-lifetime 1800
set service router-advert interface eth2.30 prefix 2600:1900:41d1:92::/64 valid-lifetime 14400

# VLAN 30 — 共通フラグ (M flag なし — SLAAC のみ)
set service router-advert interface eth2.30 other-config-flag true
set service router-advert interface eth2.30 name-server <optage-prefix>::1
set service router-advert interface eth2.30 interval max 60
set service router-advert interface eth2.30 interval min 20

# VLAN 40 — OPTAGE /64
set service router-advert interface eth2.40 prefix <optage-prefix>::/64 preferred-lifetime 14400
set service router-advert interface eth2.40 prefix <optage-prefix>::/64 valid-lifetime 86400

# VLAN 40 — GCP /64
set service router-advert interface eth2.40 prefix 2600:1900:41d1:92::/64 preferred-lifetime 1800
set service router-advert interface eth2.40 prefix 2600:1900:41d1:92::/64 valid-lifetime 14400

# VLAN 40 — 共通フラグ
set service router-advert interface eth2.40 other-config-flag true
set service router-advert interface eth2.40 name-server <optage-prefix>::2
set service router-advert interface eth2.40 interval max 60
set service router-advert interface eth2.40 interval min 20
```

### RA マルチキャスト対策

大規模 Wi-Fi 環境では RA のマルチキャスト送信が L2MC テーブル枯渇やエアタイム浪費の原因となる (JANOG56 での実例あり)。以下の対策を適用する。

#### RA 送信間隔の調整

デフォルトの RA 送信間隔 (200〜600 秒) ではマルチキャスト RA が頻繁に発生するため不要に短くしないこと。上記設定では max=60 秒、min=20 秒としており、端末の RA タイムアウトを防ぎつつマルチキャスト RA の頻度を抑えている。

#### RS に対する RA ユニキャスト応答 (radvd UnicastOnly)

VyOS の CLI では RS に対するユニキャスト応答の設定パラメータが提供されていない。ただし VyOS 内部で使用される radvd には `UnicastOnly` オプションが存在する。**本番で L2MC テーブル枯渇が発生した場合の緊急対策** として、radvd.conf を直接編集する手順を以下に記載する。

```bash
# 現在の radvd.conf を確認
cat /run/radvd/radvd.conf

# UnicastOnly を有効化 (interface ブロック内に追記)
# ※ VyOS の commit/save で上書きされるため、永続化されない。
#    commit 後に再度適用する必要がある。
sudo sed -i '/^interface eth2.40/a\    UnicastOnly on;' /run/radvd/radvd.conf
sudo sed -i '/^interface eth2.30/a\    UnicastOnly on;' /run/radvd/radvd.conf

# radvd を再起動
sudo systemctl restart radvd
```

**注意事項**:
- `UnicastOnly on` にすると定期的なマルチキャスト RA が停止し、RS を送信した端末にのみユニキャストで RA を返す
- VyOS の `commit` で radvd.conf が再生成されるため、設定は永続化されない。緊急対策用
- 永続化が必要な場合は `/config/scripts/vyos-postconfig-bootup.script` に sed コマンドを追記する

#### IPv6 ファイアウォールでの不正 RA ドロップ

VyOS 側でも、VLAN 30/40 のクライアント側から送信される不正 RA を破棄するファイアウォールルールを追加する。スイッチ側 RA Guard との多層防御。

```
# === IPv6 ファイアウォール: 不正 RA ドロップ ===

# VLAN 30 → r3 へのインバウンドで RA を遮断
set firewall ipv6 name BLOCK-CLIENT-RA default-action accept
set firewall ipv6 name BLOCK-CLIENT-RA rule 10 action drop
set firewall ipv6 name BLOCK-CLIENT-RA rule 10 protocol icmpv6
set firewall ipv6 name BLOCK-CLIENT-RA rule 10 icmpv6 type 134
set firewall ipv6 name BLOCK-CLIENT-RA rule 10 description 'Drop RA from clients'

set firewall ipv6 input filter rule 20 action jump
set firewall ipv6 input filter rule 20 jump-target BLOCK-CLIENT-RA
set firewall ipv6 input filter rule 20 inbound-interface name eth2.30

set firewall ipv6 input filter rule 30 action jump
set firewall ipv6 input filter rule 30 jump-target BLOCK-CLIENT-RA
set firewall ipv6 input filter rule 30 inbound-interface name eth2.40
```

### ~~DHCPv6~~ (廃止)

DHCPv6 によるアドレス配布は **廃止**。理由:

- iOS/Android が DHCPv6 IA_NA (アドレス割当) 非対応 → SLAAC 必須
- RFC 6724 によりソースアドレス選択は OS 依存 → DHCPv6 アドレスが PBR に使われる保証なし
- 法執行機関対応の MAC↔IPv6 追跡は NDP テーブル dump でカバー済み
- kea が VIF の `interface` 指定に VyOS CLI で対応しておらず運用が複雑

アドレス配布は **SLAAC (A flag) に統一**し、DNS は **RDNSS + O flag** で配布する。

<details>
<summary>旧 DHCPv6 設定 (参考、削除済み)</summary>

```
# === DHCPv6 (統合プール) === ※廃止

set service dhcpv6-server shared-network-name V6-POOL subnet <delegated-prefix>::/64 range staff start <prefix>::1000
set service dhcpv6-server shared-network-name V6-POOL subnet <delegated-prefix>::/64 range staff stop <prefix>::ffff
set service dhcpv6-server shared-network-name V6-POOL subnet <delegated-prefix>::/64 range user start <prefix>::1:0
set service dhcpv6-server shared-network-name V6-POOL subnet <delegated-prefix>::/64 range user stop <prefix>::1:ffff
set service dhcpv6-server shared-network-name V6-POOL subnet <delegated-prefix>::/64 subnet-id 60
set service dhcpv6-server shared-network-name V6-POOL subnet <delegated-prefix>::/64 option name-server <prefix>::1
```

</details>

### 4a. Source-based PBR (IPv6)

GCP /64 を src とするパケットを wg1 (r2-gcp) 経由に強制する。OPTAGE /64 src のパケットはデフォルトルート (wg0 → r1) を使用するため、追加設定不要。

`policy local-route6` は `ip -6 rule` を生成し、転送パケットにも適用される。VyOS の `policy route6` はインターフェース適用 (VIF) に対応していないため、`local-route6` を使用する。

```
# === PBR: GCP /64 src → r2-gcp ===

# ip -6 rule: src が GCP /64 なら table 100 を参照
set policy local-route6 rule 10 source address 2600:1900:41d1:92::/64
set policy local-route6 rule 10 set table 100

# テーブル 100: デフォルトルートを r2-gcp (wg1) に向ける
set protocols static table 100 route6 ::/0 next-hop fd00:255:2::2
```

## 5. ndppd (NDP Proxy)

VLAN 30/40 が同一 /64 を共有するため、インバウンド IPv6 の Neighbor Solicitation を正しいインターフェースに振り分ける。VyOS CLI 外の設定ファイル。ndppd は L2MC テーブル枯渇対策としても効果がある — WireGuard トンネル越しの NS/NA をインターフェース単位で代理応答することで、マルチキャストグループの生成を上流に伝播させない。

デュアルプレフィックス構成のため、OPTAGE /64 (wg0 経由) と GCP /64 (wg1 経由) の両方について proxy ルールを定義する。

```
# /etc/ndppd.conf
proxy wg0 {
    rule <optage-prefix>::/64 {
        iface eth2.30
        iface eth2.40
    }
}

proxy wg1 {
    rule 2600:1900:41d1:92::/64 {
        iface eth2.30
        iface eth2.40
    }
}
```

### ndppd の永続化

ndppd の systemd unit は `/run/ndppd/ndppd.conf` を参照するため (`ConditionPathExists`)、`/etc/ndppd.conf` をマスターとし、ブートスクリプトでコピーする:

```bash
# /config/scripts/vyos-postconfig-bootup.script に追記
mkdir -p /run/ndppd
cp /etc/ndppd.conf /run/ndppd/ndppd.conf
systemctl start ndppd || true
```

## 6. BGP

### ピアリング

| ピア | アドレス | AS | インターフェース | 用途 |
|------|---------|-----|-----------------|------|
| r1-home | 10.255.0.1 | 65002 | wg0 | 自宅との直接接続 |
| r2-gcp | 10.255.2.2 | 64512 | wg1 | GCP トランジット |

### 広告・受信

| 方向 | AFI | 経路 |
|------|-----|------|
| 広告 | IPv4 | 192.168.11.0/24, 192.168.30.0/24, 192.168.40.0/22 |
| 広告 | IPv6 | `redistribute connected` (OPTAGE /64, GCP /64 を自動広告) |
| 受信 (r1) | IPv4/IPv6 | 0.0.0.0/0, ::/0 (デフォルトルート) |
| 受信 (r2-gcp) | IPv4/IPv6 | r1 経由の経路 (フォールバック) + GCE サブネット |

### 経路優先度制御

WireGuard 直接リンク (r1) を優先し、r2-gcp 経由をフォールバックにする。ただし r2-gcp が広告する Google プレフィックス (goog.json 由来) は r2-gcp 直接を優先する (LP=250)。default route のみ r1 優先 (LP=50) を維持し、r1 障害時のフォールバックとする。

### BFD (Bidirectional Forwarding Detection)

BGP デフォルトの hold timer (90 秒) では障害検知が遅すぎるため、BFD を併用して約 1 秒で検知する。

| ピア | BFD interval | multiplier | 検知時間 |
|------|-------------|------------|---------|
| 10.255.0.1 (r1) | 300ms | 3 | ~0.9s |
| 10.255.2.2 (r2) | 300ms | 3 | ~0.9s |

### IPv6 出口ヘルスチェック (`v6-health-monitor.sh`)

BFD / BGP ではルーター間リンク障害のみ検知でき、出口の ISP 障害 (r1 正常だが OPTAGE 停止) は検知できない。アクティブプローブで各出口のインターネット疎通性を監視し、障害時は該当プレフィックスの RA を lifetime=0 に変更してクライアントの使用を停止させる。

**スクリプト**: [`scripts/v6-health-monitor.sh`](../../scripts/v6-health-monitor.sh)
**配置先**: `/config/scripts/v6-health-monitor.sh` (r3)
**実行間隔**: 5 秒 (`system task-scheduler task v6-health interval 5`)

| パラメータ | 値 | 説明 |
|---|---|---|
| プローブ先 | Google DNS, Cloudflare DNS | いずれか 1 つに到達できれば OK |
| 障害判定 | 3 回連続失敗 (15 秒) | 一時的な揺らぎを無視 |
| 復旧判定 | 3 回連続成功 (15 秒) | フラップ防止 |
| 障害アクション | RA `preferred-lifetime 0` + `valid-lifetime 0` | クライアントが新規接続でこのプレフィックスを使用しなくなる |
| 復旧アクション | RA lifetime をデフォルトに戻す | クライアントがプレフィックスを再び使用可能に |

```
# === BGP ===

set protocols bgp system-as 65001

# --- r1 (WireGuard 直接) ---
set protocols bgp neighbor 10.255.0.1 remote-as 65002
set protocols bgp neighbor 10.255.0.1 description 'Home router (r1)'
set protocols bgp neighbor 10.255.0.1 address-family ipv4-unicast
set protocols bgp neighbor 10.255.0.1 address-family ipv4-unicast route-map import WG-IN
set protocols bgp neighbor 10.255.0.1 address-family ipv6-unicast
set protocols bgp neighbor 10.255.0.1 address-family ipv6-unicast route-map import WG-IN
set protocols bgp neighbor 10.255.0.1 address-family ipv6-unicast nexthop-local unchanged
set protocols bgp neighbor 10.255.0.1 bfd

# --- r2-gcp (GCP トランジット) ---
set protocols bgp neighbor 10.255.2.2 remote-as 64512
set protocols bgp neighbor 10.255.2.2 description 'r2-gcp'
set protocols bgp neighbor 10.255.2.2 address-family ipv4-unicast
set protocols bgp neighbor 10.255.2.2 address-family ipv4-unicast route-map import GCP-IN
set protocols bgp neighbor 10.255.2.2 address-family ipv6-unicast
set protocols bgp neighbor 10.255.2.2 address-family ipv6-unicast route-map import GCP-IN
set protocols bgp neighbor 10.255.2.2 address-family ipv6-unicast nexthop-local unchanged
set protocols bgp neighbor 10.255.2.2 bfd

# --- BFD ---
set protocols bfd peer 10.255.0.1 interval receive 300
set protocols bfd peer 10.255.0.1 interval transmit 300
set protocols bfd peer 10.255.0.1 interval multiplier 3
set protocols bfd peer 10.255.0.1 source address 10.255.0.2
set protocols bfd peer 10.255.2.2 interval receive 300
set protocols bfd peer 10.255.2.2 interval transmit 300
set protocols bfd peer 10.255.2.2 interval multiplier 3
set protocols bfd peer 10.255.2.2 source address 10.255.2.1

# --- IPv6 connected ルート再配布 (OPTAGE/GCP プレフィックス自動広告) ---
set protocols bgp address-family ipv6-unicast redistribute connected

# --- Route Map ---

# WireGuard 直接: local-pref 200 (優先)
set policy route-map WG-IN rule 10 action permit
set policy route-map WG-IN rule 10 set local-preference 200

# GCP 経由: default route のみ LP=50 (r1 優先を維持)、Google プレフィックスは LP=250 (r2-gcp 直接優先)
set policy prefix-list DEFAULT-ONLY rule 10 action permit
set policy prefix-list DEFAULT-ONLY rule 10 prefix 0.0.0.0/0
set policy prefix-list6 DEFAULT6-ONLY rule 10 action permit
set policy prefix-list6 DEFAULT6-ONLY rule 10 prefix ::/0

set policy route-map GCP-IN rule 10 action permit
set policy route-map GCP-IN rule 10 match ip address prefix-list DEFAULT-ONLY
set policy route-map GCP-IN rule 10 set local-preference 50
set policy route-map GCP-IN rule 15 action permit
set policy route-map GCP-IN rule 15 match ipv6 address prefix-list DEFAULT6-ONLY
set policy route-map GCP-IN rule 15 set local-preference 50
set policy route-map GCP-IN rule 20 action permit
set policy route-map GCP-IN rule 20 set local-preference 250

# 会場サブネット広告
set protocols bgp address-family ipv4-unicast network 192.168.11.0/24
set protocols bgp address-family ipv4-unicast network 192.168.30.0/24
set protocols bgp address-family ipv4-unicast network 192.168.40.0/22

# BGP ルートの AD を 20 に (DHCP default AD210 より優先、wg0 経由でユーザートラフィック転送)
set protocols bgp parameters distance global external 20
set protocols bgp parameters distance global internal 200
set protocols bgp parameters distance global local 200
```

### WG peer 公開 IP の escape route

r1-home から `default-originate` で `0.0.0.0/0` を受け取ると、何も対策しない状態では **WG 外殻パケット (outer dst = WG peer の公開 IP) が wg0 に吸われてループ・二重カプセル化** が発生する。r3 が維持している WG peer は 2 つあり、どちらも同じ問題の影響を受ける:

| peer | 公開 IP | IP 性質 | 対策方法 |
|---|---|---|---|
| r1-home (wg0) | tukushityann.net → 動的 pppoe0 | ISP 由来で変動あり | tracker スクリプトで kernel 直叩き (後述) |
| r2-gcp (wg1) | `34.97.197.104` | GCP 予約 static IP | tracker スクリプトで wg0 経由 double encapsulation (後述) |

#### r2-gcp (wg1) — wg0 経由の double encapsulation

~~GCP 側の公開 IP は固定なので VyOS config 内で完結できる。~~ 当初は `dhcp-interface eth1` で eth1 経由に escape させる設計だったが、blackbox が UDP をブロックするため WG ハンドシェイクが失敗する。代わりに **wg0 (r1) 経由の double encapsulation** パスを使用する。

wg-r1-tracker.sh が以下を kernel レベルで設定する:

```
# r2 endpoint を wg0 (r1) 経由にルーティング
ip route replace 34.97.197.104 via 10.255.0.1 dev wg0

# endpoint を kernel レベルで直接設定 (VyOS config には address/port を書かない)
wg set wg1 peer <r2-key> endpoint 34.97.197.104:51821
```

これにより、wg1 の外殻パケット (`dst=34.97.197.104`) は wg0 を経由して r1 に送られ、r1 の pppoe0 から GCP に到達する。VyOS config に `address`/`port` を設定しないことで、VyOS が eth1 経由の auto-route を作成する問題を回避する。

> **r2-gcp 側の対策も必須**: r3 は r1 から `default-originate` で受けた `0.0.0.0/0` を eBGP の経路再広告により **r2-gcp にも再広告する**。r2-gcp がこの BGP default (AD20) を受け入れると、GCP の static default (AD210) が負けて r2 の全トラフィックが wg2 → r3 に吸い込まれ、**r2 がインターネット到達不能・WG 応答パケット送信不能** となる。r2-gcp 側の対策として `DENY-DEFAULT` prefix-list (import フィルタ) を設定済み。詳細は [`gcp-integration.md`](gcp-integration.md) セクション 8 を参照。

#### r1-home (wg0) — 動的追従の tracker

r1-home の公開 IP は DDNS `tukushityann.net` で管理されており、ISP 再接続で変動する可能性がある。しかし VyOS の CLI/API validator は:
- `interfaces wireguard <if> peer <name> address` に **FQDN を許可しない** (`ip-address` validator で拒否)
- `protocols static route <prefix>` の宛先に **FQDN を許可しない**

これは API 経由でも config.boot 直接編集でも同じ (commit 時に再検証される)。一方、kernel の `wg set endpoint <fqdn>:<port>` と `ip route replace` は FQDN/動的 IP に対応している。

そこで **VyOS config の外に tracker スクリプトを置き、kernel 直叩きで管理する**構成とする。

#### コンポーネント

| 要素 | パス | 役割 |
|---|---|---|
| tracker 本体 | `/config/scripts/wg-r1-tracker.sh` | `tukushityann.net` (r1 の DDNS) を解決し、wg0 peer endpoint と `/32` escape route を最新 IP に追従 |
| 定期実行 | VyOS task-scheduler `wg-r1-tracker` (1 分間隔) | r1 WAN IP 変更を自動追従 |
| 起動時実行 | `/config/scripts/vyos-postconfig-bootup.script` | boot 直後に一度実行し、BGP default が立つ前に `/32` を設置 |
| last-IP 状態 | `/var/run/wg-r1-tracker.last-ip` | 前回解決 IP を記録 (変更検知用、tmpfs なので再起動で消える = 起動時に必ず更新走る) |

#### 投入コマンド

```
# task-scheduler 登録 (毎分実行)
set system task-scheduler task wg-r1-tracker interval 1m
set system task-scheduler task wg-r1-tracker executable path /config/scripts/wg-r1-tracker.sh
```

スクリプト本体は `scripts/wg-r1-tracker.sh` としてリポジトリ管理。`/config/scripts/vyos-postconfig-bootup.script` には以下を追記する:

```bash
# --- r1-home WAN IP tracker ---
# BGP default-originate 適用後、WG 外殻パケットが wg0 にループで吸われるのを防ぐため、
# 起動直後に tukushityann.net を解決して r1 公開 IP への /32 escape route を設置する。
# 以降は task-scheduler (wg-r1-tracker, 1m) が継続追従する。
/config/scripts/wg-r1-tracker.sh || true
```

#### VyOS config に残る placeholder

`interfaces wireguard wg0 peer r1-home address <last-known-ip>` は **last-known-good な IP** をそのまま残しておく。起動直後 (tracker が走る前) の一時的なフォールバックとして機能する。IP 変更時には tracker がカーネルレベルで `wg set endpoint` を上書きするため、config 側の値は同期されない点に注意 (設計上許容)。

#### r2-gcp endpoint の処理

wg-r1-tracker.sh は r1-home の DDNS 追従に加え、r2-gcp (wg1) の endpoint 設定も管理する。VyOS config で wg1 peer r2-gcp に `address`/`port` を設定すると、VyOS が eth1 経由の auto-route を作成するが、blackbox が UDP をブロックするため WG ハンドシェイクが失敗する。代わりに wg0 (r1) 経由の double encapsulation パスを使用する。

```
# wg-r1-tracker.sh に r2-gcp endpoint の処理を追加:
# - ip route replace 34.97.197.104 via 10.255.0.1 dev wg0
#   → r2 endpoint を wg0 (r1) 経由にルーティング
# - wg set wg1 peer <r2-key> endpoint 34.97.197.104:51821
#   → endpoint を kernel レベルで直接設定
```

これにより、r2-gcp 向けの WG 外殻パケットは wg0 (r1) を経由し、r1 の pppoe0 から GCP に到達する。VyOS config 外で kernel 直叩きするため、`commit` で上書きされるリスクがなく、blackbox の UDP ブロックも回避できる。

#### 運用上の注意

- tracker が停止すると r1 IP 変更時に WG が再接続不能になる。`systemctl status cron` と `journalctl -t wg-r1-tracker` を監視対象にする
- VyOS 側で `commit` が wg0 を触ると (例: allowed-ips の変更など) tracker 設定した endpoint が config の placeholder に戻される可能性がある。次の cron 発火 (最大 1 分) で復旧する
- `tukushityann.net` の DDNS 更新が停止した場合は tracker も追従できないため、DDNS 自体の監視も必要
- r1 IP を静的に変更したい場合は **config の placeholder と DDNS 両方**を更新すること
- r2-gcp の公開 IP (`34.97.197.104`) は GCP 予約 static IP のため変動しないが、tracker スクリプトで一元管理することで wg0/wg1 両方の endpoint 管理が集約される

## 7. ファイアウォール (ACL)

### 設計方針

ACL ポリシー ([`architecture.md`](architecture.md) 参照):

| ルール | 動作 |
|--------|------|
| VLAN 30 → VLAN 11 | 全許可 (運営スタッフ) |
| VLAN 40 → 192.168.11.1 (router) | 許可 (GW/DNS/DHCP) |
| VLAN 40 → VLAN 11 (上記以外) | 拒否 (.2 Grafana, .3 Proxmox, .4 SW 等) |
| VLAN 40 → VLAN 30 | 拒否 |

### VyOS ファイアウォール実装

VLAN 40 クライアントの GW は 192.168.40.1 (r3 の VLAN 40 IF)。クライアントから 192.168.40.1 宛のトラフィック (DNS, DHCP, GW) は **input** チェインで処理され、forward チェインには乗らない。そのため forward で VLAN 11 全体を deny しても、router 自身へのアクセスは影響しない。

```
# === ファイアウォール ===

# --- Forward filter (inter-VLAN ルーティング制御) ---

# Named chain: VLAN 40 からの転送制限
set firewall ipv4 name VLAN40-FORWARD default-action accept
set firewall ipv4 name VLAN40-FORWARD rule 10 action drop
set firewall ipv4 name VLAN40-FORWARD rule 10 destination address 192.168.11.0/24
set firewall ipv4 name VLAN40-FORWARD rule 10 description 'Deny user to mgmt VLAN'
set firewall ipv4 name VLAN40-FORWARD rule 20 action drop
set firewall ipv4 name VLAN40-FORWARD rule 20 destination address 192.168.30.0/24
set firewall ipv4 name VLAN40-FORWARD rule 20 description 'Deny user to staff VLAN'

# Forward filter に適用
set firewall ipv4 forward filter default-action accept
set firewall ipv4 forward filter rule 10 action jump
set firewall ipv4 forward filter rule 10 jump-target VLAN40-FORWARD
set firewall ipv4 forward filter rule 10 inbound-interface name eth2.40

# --- Input filter (router 自身への通信制御) ---

# Named chain: VLAN 40 から router への制限 (管理サービスのみブロック)
set firewall ipv4 name VLAN40-INPUT default-action accept
set firewall ipv4 name VLAN40-INPUT rule 10 action drop
set firewall ipv4 name VLAN40-INPUT rule 10 protocol tcp
set firewall ipv4 name VLAN40-INPUT rule 10 destination port 22
set firewall ipv4 name VLAN40-INPUT rule 10 description 'Deny SSH from user VLAN'
set firewall ipv4 name VLAN40-INPUT rule 20 action drop
set firewall ipv4 name VLAN40-INPUT rule 20 protocol udp
set firewall ipv4 name VLAN40-INPUT rule 20 destination port 161
set firewall ipv4 name VLAN40-INPUT rule 20 description 'Deny SNMP from user VLAN'
set firewall ipv4 name VLAN40-INPUT rule 30 action drop
set firewall ipv4 name VLAN40-INPUT rule 30 protocol tcp
set firewall ipv4 name VLAN40-INPUT rule 30 destination port 179
set firewall ipv4 name VLAN40-INPUT rule 30 description 'Deny BGP from user VLAN'

# Input filter に適用
set firewall ipv4 input filter default-action accept
set firewall ipv4 input filter rule 10 action jump
set firewall ipv4 input filter rule 10 jump-target VLAN40-INPUT
set firewall ipv4 input filter rule 10 inbound-interface name eth2.40
```

## 8. MSS Clamping

WireGuard トンネル上の TCP で MTU 超過による断片化を防止。PMTUD に依存しない設計。

```
# === MSS Clamping ===

set firewall options interface wg0 adjust-mss clamp-mss-to-pmtu
```

## 9. Flow Accounting (NetFlow v9)

VLAN 30/40 と wg0 の 5-tuple を記録し、法執行機関対応に備える。VLAN 11 (mgmt) は対象外。

```
# === Flow Accounting ===

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

## 10. Syslog

全ログを Local Server (192.168.11.2) に転送。DNS クエリログ、DHCP forensic ログ、NDP ダンプが含まれる。

```
# === Syslog ===

set system syslog host 192.168.11.2 facility all level info
```

## 11. NDP テーブルダンプ

1 分間隔で IPv6 neighbor テーブルを記録。iOS/Android (SLAAC のみ) を含む全デバイスの IPv6 ↔ MAC 対応を取得する。

### スクリプト (`/config/scripts/ndp-dump.sh`)

```bash
#!/bin/bash
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ip -6 neigh show | while read -r line; do
    echo "${TIMESTAMP} ${line}"
done | logger -t ndp-dump -p local1.info
```

### VyOS タスクスケジューラ

```
# === NDP ダンプ ===

set system task-scheduler task ndp-dump interval 1m
set system task-scheduler task ndp-dump executable path /config/scripts/ndp-dump.sh
```

## 12. wstunnel (ポート制限環境時の WireGuard トンネル)

会場上流でポート制限 (UDP 51820 等のブロック) がある場合、wstunnel を podman コンテナとして VyOS 上で動作させる。WireGuard の UDP パケットを WebSocket (TLS over TCP 443) にカプセル化し、ポート制限を回避する。

> **補足**: プロキシ環境も併用される場合は `--http-proxy <proxy>:8080` を command に追加する。

### wstunnel の動作概要

```
WireGuard (wg0, endpoint=127.0.0.1:51821)
  → wstunnel client (localhost:51821 を listen)
    → WSS (TLS, TCP 443) → 自宅 wstunnel server:443
      → WireGuard (r1, port 51820)
```

> **ポート分離の必要性**: r3 の wg0 自身も UDP 51820 で listen しているため、wstunnel client の listen を同一ポートにすると `allow-host-networks` で bind 衝突し `Address already in use (os error 98)` で起動失敗する。このため wstunnel client は **51821** で listen させ、wg0 の peer endpoint を `127.0.0.1:51821` に向ける。r1 側 WireGuard (宛先) は設計通り 51820 のまま。

### VyOS コンテナ設定

```
# === wstunnel コンテナ (ポート制限環境時に使用) ===

set container name wstunnel image ghcr.io/erebe/wstunnel:latest
set container name wstunnel allow-host-networks
set container name wstunnel command '/home/app/wstunnel client -L udp://127.0.0.1:51821:192.168.10.1:51820?timeout_sec=0 wss://<自宅FQDN>:443'
set container name wstunnel restart on-failure
set container name wstunnel description 'WireGuard over WebSocket tunnel (port restriction bypass)'
```

- **`/home/app/wstunnel` の絶対パス指定は必須**: 公式イメージの `ENTRYPOINT` は `dumb-init -v --` で、VyOS の `container command` は Dockerfile `CMD` に相当する。`dumb-init` は shell を介さず直接 `execve` するため、command を `client -L ...` のようにサブコマンドから始めると `dumb-init: client: No such file or directory` で即 exit 2 して `restart on-failure` のループに落ちる
- `allow-host-networks`: ホストネットワーク名前空間を共有 (localhost 経由で wg0 と UDP 通信するため必須)
- `127.0.0.1:51821`: wg0 自身の listen port 51820 と衝突しないよう **51821** を使用 (※ この結果 wg1 (対 r2-gcp) の listen port も 51821 と衝突するため **51822** にずらしている。前述 WireGuard 設定参照)
- `192.168.10.1:51820`: 自宅 r1 の WireGuard アドレス (自宅 wstunnel server から見た最終転送先)
- `wss://`: 自宅側 wstunnel サーバーのエンドポイント (TCP 443, TLS)。FQDN 指定可

> ⚠️ **VyOS CLI から `set` で投入不可**: `command` 文字列に含まれる `?` (および `/`, `\`) は VyOS CLI が補完トリガーとして解釈し、シングルクォート内でも補完が発動して入力が打ち切られる。**このコマンドは必ず VyOS REST API (`/configure`) 経由で投入すること**。投入例:
>
> ```bash
> curl -k -X POST https://<r3-mgmt-ip>/configure \
>   -H "Content-Type: application/json" \
>   -d '{"key":"<API_KEY>","commands":[
>     {"op":"delete","path":["container","name","wstunnel","command"]},
>     {"op":"set","path":["container","name","wstunnel","command",
>       "/home/app/wstunnel client -L udp://127.0.0.1:51821:192.168.10.1:51820?timeout_sec=0 wss://<自宅FQDN>:443"]}
>   ]}'
> ```
>
> 投入後は `/config-file` エンドポイントで `save` を忘れずに実行する。

### WireGuard endpoint の切替

```
# ポート制限環境時: wstunnel 経由 (wstunnel client は 127.0.0.1:51821 で listen)
set interfaces wireguard wg0 peer r1 endpoint '127.0.0.1:51821'
commit

# ポート制限なし: 直接接続
set interfaces wireguard wg0 peer r1 endpoint '<自宅グローバルIP>:51820'
commit
```

### 自宅側 wstunnel サーバー

自宅側はメインPC (192.168.10.4) で wstunnel サーバーを稼働させる。詳細は [`home-vyos.md`](home-vyos.md) を参照。

```bash
wstunnel server --restrict-to 192.168.10.1:51820 wss://[::]:443
```

- `--restrict-to 192.168.10.1:51820`: トンネル先を r1 の WireGuard に限定。wstunnel サーバーはメインPC で動作するため、r1 の LAN IP を指定する
- r1 の DNAT で pppoe0:443 → 192.168.10.4:443 に転送する

## 13. システム基本設定

```
# === システム ===

set system host-name r3-vyos
set system time-zone Asia/Tokyo
set system name-server 127.0.0.1

# SSH (管理 VLAN からのみ想定、VLAN 40 は input filter でブロック)
set service ssh port 22
set service ssh disable-password-authentication
```

## 14. 完全コンフィグ一覧

以下は全 `set` コマンドをコピペ可能な形で集約したもの。`<placeholder>` は環境依存値。

```
# ============================================================
# r3-vyos 完全コンフィグ
# ============================================================

# --- システム ---
set system host-name r3-vyos
set system time-zone Asia/Tokyo
set system name-server 127.0.0.1

# --- SSH ---
set service ssh port 22
set service ssh disable-password-authentication

# --- インターフェース ---
set interfaces ethernet eth1 address dhcp
set interfaces ethernet eth1 description 'Uplink to blackbox (virtio via vmbr_wan)'
set interfaces ethernet eth1 hw-id 'bc:24:11:76:48:ac'
set interfaces ethernet eth1 offload gro
set interfaces ethernet eth1 offload gso
set interfaces ethernet eth1 offload sg
set interfaces ethernet eth1 offload tso
set interfaces ethernet eth2 description 'VLAN trunk to PoE switch'
set interfaces ethernet eth2 hw-id 'bc:24:11:ea:46:88'

set interfaces ethernet eth2 vif 11 address 192.168.11.1/24
set interfaces ethernet eth2 vif 11 description 'VLAN 11 - mgmt'
set interfaces ethernet eth2 vif 30 address 192.168.30.1/24
set interfaces ethernet eth2 vif 30 address <gcp-prefix>::1/64
set interfaces ethernet eth2 vif 30 description 'VLAN 30 - staff + live'
set interfaces ethernet eth2 vif 40 address 192.168.40.1/22
set interfaces ethernet eth2 vif 40 address <gcp-prefix>::2/64
set interfaces ethernet eth2 vif 40 description 'VLAN 40 - user'

# --- WireGuard ---
set interfaces wireguard wg0 address 10.255.0.2/30
set interfaces wireguard wg0 mtu 1400
set interfaces wireguard wg0 port 51820
set interfaces wireguard wg0 private-key <r3-private-key>
set interfaces wireguard wg0 description 'VPN to home (r1)'
set interfaces wireguard wg0 peer r1 public-key <r1-public-key>
set interfaces wireguard wg0 peer r1 allowed-ips 0.0.0.0/0
set interfaces wireguard wg0 peer r1 allowed-ips ::/0
set interfaces wireguard wg0 peer r1 endpoint '<自宅グローバルIP>:51820'
set interfaces wireguard wg0 peer r1 persistent-keepalive 25

# wg1 listen port は wstunnel (127.0.0.1:51821) との衝突を避けるため 51822
set interfaces wireguard wg1 address 10.255.2.1/30
set interfaces wireguard wg1 mtu 1400
set interfaces wireguard wg1 port 51822
set interfaces wireguard wg1 private-key <r3-private-key>
set interfaces wireguard wg1 description 'VPN to GCP (r2-gcp)'
set interfaces wireguard wg1 peer r2-gcp public-key <r2-public-key>
# allowed-ips 0.0.0.0/0 ::/0 (goog.json + フェイルオーバー全カバー)
# address/port は設定しない → wg-r1-tracker.sh が kernel レベルで管理
set interfaces wireguard wg1 peer r2-gcp allowed-ips 0.0.0.0/0
set interfaces wireguard wg1 peer r2-gcp allowed-ips ::/0
set interfaces wireguard wg1 peer r2-gcp persistent-keepalive 25

# --- wstunnel コンテナ (ポート制限環境時に使用、command のみ REST API 経由で投入) ---
set container name wstunnel image ghcr.io/erebe/wstunnel:latest
set container name wstunnel allow-host-networks
set container name wstunnel command '/home/app/wstunnel client -L udp://127.0.0.1:51821:192.168.10.1:51820?timeout_sec=0 wss://<自宅FQDN>:443'
set container name wstunnel restart on-failure
set container name wstunnel description 'WireGuard over WebSocket tunnel (port restriction bypass)'

# --- DHCP サーバー ---
set service dhcp-server shared-network-name MGMT subnet 192.168.11.0/24 range 0 start 192.168.11.20
set service dhcp-server shared-network-name MGMT subnet 192.168.11.0/24 range 0 stop 192.168.11.199
set service dhcp-server shared-network-name MGMT subnet 192.168.11.0/24 default-router 192.168.11.1
set service dhcp-server shared-network-name MGMT subnet 192.168.11.0/24 name-server 192.168.11.1
set service dhcp-server shared-network-name MGMT subnet 192.168.11.0/24 lease 3600

set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 range 0 start 192.168.30.100
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 range 0 stop 192.168.30.254
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 default-router 192.168.30.1
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 name-server 192.168.30.1
set service dhcp-server shared-network-name STAFF subnet 192.168.30.0/24 lease 3600

set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 range 0 start 192.168.40.100
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 range 0 stop 192.168.43.254
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 default-router 192.168.40.1
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 name-server 192.168.40.1
set service dhcp-server shared-network-name USER subnet 192.168.40.0/22 lease 3600

# --- DNS フォワーディング (フルリゾルバ、system はループ回避のため不使用) ---
set service dns forwarding listen-address 192.168.11.1
set service dns forwarding listen-address 192.168.30.1
set service dns forwarding listen-address 192.168.40.1
set service dns forwarding listen-address 127.0.0.1
set service dns forwarding listen-address <optage-prefix>::1
set service dns forwarding listen-address <optage-prefix>::2
set service dns forwarding listen-address <gcp-prefix>::1
set service dns forwarding listen-address <gcp-prefix>::2
set service dns forwarding allow-from 192.168.11.0/24
set service dns forwarding allow-from 192.168.30.0/24
set service dns forwarding allow-from 192.168.40.0/22
set service dns forwarding allow-from 127.0.0.0/8
set service dns forwarding allow-from <optage-prefix>::/64
set service dns forwarding allow-from <gcp-prefix>::/64
set service dns forwarding options 'log-common-errors=yes'
set service dns forwarding options 'quiet=no'
set service dns forwarding options 'logging-facility=0'

# --- RA (デュアルプレフィックス) ---
# VLAN 30: OPTAGE /64 (優先)
set service router-advert interface eth2.30 prefix <optage-prefix>::/64 preferred-lifetime 14400
set service router-advert interface eth2.30 prefix <optage-prefix>::/64 valid-lifetime 86400
# VLAN 30: GCP /64 (非優先)
set service router-advert interface eth2.30 prefix 2600:1900:41d1:92::/64 preferred-lifetime 1800
set service router-advert interface eth2.30 prefix 2600:1900:41d1:92::/64 valid-lifetime 14400
set service router-advert interface eth2.30 other-config-flag true
set service router-advert interface eth2.30 name-server <optage-prefix>::1
set service router-advert interface eth2.30 interval max 60
set service router-advert interface eth2.30 interval min 20

# VLAN 40: OPTAGE /64 (優先)
set service router-advert interface eth2.40 prefix <optage-prefix>::/64 preferred-lifetime 14400
set service router-advert interface eth2.40 prefix <optage-prefix>::/64 valid-lifetime 86400
# VLAN 40: GCP /64 (非優先)
set service router-advert interface eth2.40 prefix 2600:1900:41d1:92::/64 preferred-lifetime 1800
set service router-advert interface eth2.40 prefix 2600:1900:41d1:92::/64 valid-lifetime 14400
set service router-advert interface eth2.40 other-config-flag true
set service router-advert interface eth2.40 name-server <optage-prefix>::2
set service router-advert interface eth2.40 interval max 60
set service router-advert interface eth2.40 interval min 20

# --- DHCPv6: 廃止 (iOS/Android非対応, ソースアドレス選択制御不可, NDP dumpでカバー) ---
# delete service dhcpv6-server

# --- PBR: GCP /64 src → r2-gcp ---
set policy local-route6 rule 10 source address 2600:1900:41d1:92::/64
set policy local-route6 rule 10 set table 100
set protocols static table 100 route6 ::/0 next-hop fd00:255:2::2

# --- BGP ---
set protocols bgp system-as 65001

# r1 (WireGuard 直接)
set protocols bgp neighbor 10.255.0.1 remote-as 65002
set protocols bgp neighbor 10.255.0.1 description 'Home router (r1)'
set protocols bgp neighbor 10.255.0.1 address-family ipv4-unicast
set protocols bgp neighbor 10.255.0.1 address-family ipv4-unicast route-map import WG-IN

# r2-gcp (GCP トランジット)
set protocols bgp neighbor 10.255.2.2 remote-as 64512
set protocols bgp neighbor 10.255.2.2 description 'r2-gcp'
set protocols bgp neighbor 10.255.2.2 address-family ipv4-unicast
set protocols bgp neighbor 10.255.2.2 address-family ipv4-unicast route-map import GCP-IN

# Route Map
set policy route-map WG-IN rule 10 action permit
set policy route-map WG-IN rule 10 set local-preference 200
set policy prefix-list DEFAULT-ONLY rule 10 action permit
set policy prefix-list DEFAULT-ONLY rule 10 prefix 0.0.0.0/0
set policy prefix-list6 DEFAULT6-ONLY rule 10 action permit
set policy prefix-list6 DEFAULT6-ONLY rule 10 prefix ::/0
set policy route-map GCP-IN rule 10 action permit
set policy route-map GCP-IN rule 10 match ip address prefix-list DEFAULT-ONLY
set policy route-map GCP-IN rule 10 set local-preference 50
set policy route-map GCP-IN rule 15 action permit
set policy route-map GCP-IN rule 15 match ipv6 address prefix-list DEFAULT6-ONLY
set policy route-map GCP-IN rule 15 set local-preference 50
set policy route-map GCP-IN rule 20 action permit
set policy route-map GCP-IN rule 20 set local-preference 250

# 会場サブネット広告
set protocols bgp address-family ipv4-unicast network 192.168.11.0/24
set protocols bgp address-family ipv4-unicast network 192.168.30.0/24
set protocols bgp address-family ipv4-unicast network 192.168.40.0/22
set protocols bgp parameters distance global external 20
set protocols bgp parameters distance global internal 200
set protocols bgp parameters distance global local 200

# --- ファイアウォール ---

# Forward: VLAN 40 制限
set firewall ipv4 name VLAN40-FORWARD default-action accept
set firewall ipv4 name VLAN40-FORWARD rule 10 action drop
set firewall ipv4 name VLAN40-FORWARD rule 10 destination address 192.168.11.0/24
set firewall ipv4 name VLAN40-FORWARD rule 10 description 'Deny user to mgmt VLAN'
set firewall ipv4 name VLAN40-FORWARD rule 20 action drop
set firewall ipv4 name VLAN40-FORWARD rule 20 destination address 192.168.30.0/24
set firewall ipv4 name VLAN40-FORWARD rule 20 description 'Deny user to staff VLAN'

set firewall ipv4 forward filter default-action accept
set firewall ipv4 forward filter rule 10 action jump
set firewall ipv4 forward filter rule 10 jump-target VLAN40-FORWARD
set firewall ipv4 forward filter rule 10 inbound-interface name eth2.40

# Input: VLAN 40 管理サービスブロック
set firewall ipv4 name VLAN40-INPUT default-action accept
set firewall ipv4 name VLAN40-INPUT rule 10 action drop
set firewall ipv4 name VLAN40-INPUT rule 10 protocol tcp
set firewall ipv4 name VLAN40-INPUT rule 10 destination port 22
set firewall ipv4 name VLAN40-INPUT rule 10 description 'Deny SSH from user VLAN'
set firewall ipv4 name VLAN40-INPUT rule 20 action drop
set firewall ipv4 name VLAN40-INPUT rule 20 protocol udp
set firewall ipv4 name VLAN40-INPUT rule 20 destination port 161
set firewall ipv4 name VLAN40-INPUT rule 20 description 'Deny SNMP from user VLAN'
set firewall ipv4 name VLAN40-INPUT rule 30 action drop
set firewall ipv4 name VLAN40-INPUT rule 30 protocol tcp
set firewall ipv4 name VLAN40-INPUT rule 30 destination port 179
set firewall ipv4 name VLAN40-INPUT rule 30 description 'Deny BGP from user VLAN'

set firewall ipv4 input filter default-action accept
set firewall ipv4 input filter rule 10 action jump
set firewall ipv4 input filter rule 10 jump-target VLAN40-INPUT
set firewall ipv4 input filter rule 10 inbound-interface name eth2.40

# MSS Clamping
set firewall options interface wg0 adjust-mss clamp-mss-to-pmtu

# IPv6: クライアントからの不正 RA をドロップ (スイッチ側 RA Guard との多層防御)
set firewall ipv6 name BLOCK-CLIENT-RA default-action accept
set firewall ipv6 name BLOCK-CLIENT-RA rule 10 action drop
set firewall ipv6 name BLOCK-CLIENT-RA rule 10 protocol icmpv6
set firewall ipv6 name BLOCK-CLIENT-RA rule 10 icmpv6 type 134
set firewall ipv6 name BLOCK-CLIENT-RA rule 10 description 'Drop RA from clients'

set firewall ipv6 input filter rule 20 action jump
set firewall ipv6 input filter rule 20 jump-target BLOCK-CLIENT-RA
set firewall ipv6 input filter rule 20 inbound-interface name eth2.30
set firewall ipv6 input filter rule 30 action jump
set firewall ipv6 input filter rule 30 jump-target BLOCK-CLIENT-RA
set firewall ipv6 input filter rule 30 inbound-interface name eth2.40

# --- Flow Accounting ---
set system flow-accounting interface eth2.30
set system flow-accounting interface eth2.40
set system flow-accounting interface wg0
set system flow-accounting netflow version 9
set system flow-accounting netflow server 192.168.11.2 port 2055
set system flow-accounting netflow timeout expiry-interval 60
set system flow-accounting netflow timeout flow-active 120
set system flow-accounting netflow timeout flow-inactive 15
set system flow-accounting netflow source-ip 192.168.11.1

# --- Syslog ---
set system syslog host 192.168.11.2 facility all level info

# --- NDP ダンプ ---
set system task-scheduler task ndp-dump interval 1m
set system task-scheduler task ndp-dump executable path /config/scripts/ndp-dump.sh
```
