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

VM リソース: 2 vCPU, 2GB RAM。詳細は [`venue-proxmox.md`](venue-proxmox.md) を参照。

## 1. インターフェース

### 物理マッピング (Proxmox)

| VyOS IF | Proxmox ブリッジ | 物理 NIC | 役割 |
|---------|-----------------|----------|------|
| eth0 | vmbr0 | USB 2.5GbE | アップリンク (→ blackbox) |
| eth1 | vmbr1 | (内部ブリッジ) | SoftEther 経由時のアップリンク |
| eth2 | vmbr_trunk | Realtek RTL8111H | VLAN トランク (→ PoE スイッチ) |

### VLAN サブインターフェース (eth2)

| VIF | VLAN ID | アドレス (v4) | IPv6 | 用途 |
|-----|---------|--------------|------|------|
| eth2.11 | 11 | 192.168.11.1/24 | なし | 管理 (mgmt) |
| eth2.30 | 30 | 192.168.30.1/24 | DHCPv6-PD /64 | 運営 (staff + live) |
| eth2.40 | 40 | 192.168.40.1/22 | DHCPv6-PD /64 | 来場者 (user) |

### WireGuard

| パラメータ | 値 |
|-----------|-----|
| インターフェース | wg0 |
| アドレス | 10.255.0.2/30 |
| MTU | 1380 |
| ポート | 51820 |
| ピア | r1 (自宅 VyOS) |

```
# === インターフェース ===

# アップリンク (blackbox から DHCP)
set interfaces ethernet eth0 address dhcp
set interfaces ethernet eth0 description 'Uplink to blackbox'

# SoftEther ブリッジ (プロキシ経由時のみ使用)
set interfaces ethernet eth1 description 'SoftEther bridge (vmbr1)'

# VLAN トランク (PoE スイッチ)
set interfaces ethernet eth2 description 'VLAN trunk to PoE switch'

# VLAN 11 (mgmt - v4 only)
set interfaces ethernet eth2 vif 11 address 192.168.11.1/24
set interfaces ethernet eth2 vif 11 description 'VLAN 11 - mgmt'

# VLAN 30 (staff + live)
set interfaces ethernet eth2 vif 30 address 192.168.30.1/24
set interfaces ethernet eth2 vif 30 description 'VLAN 30 - staff + live'

# VLAN 40 (user)
set interfaces ethernet eth2 vif 40 address 192.168.40.1/22
set interfaces ethernet eth2 vif 40 description 'VLAN 40 - user'

# WireGuard (自宅 VPN)
set interfaces wireguard wg0 address 10.255.0.2/30
set interfaces wireguard wg0 mtu 1380
set interfaces wireguard wg0 port 51820
set interfaces wireguard wg0 private-key <r3-private-key>
set interfaces wireguard wg0 description 'VPN to home (r1)'
set interfaces wireguard wg0 peer r1 public-key <r1-public-key>
set interfaces wireguard wg0 peer r1 allowed-ips 0.0.0.0/0
set interfaces wireguard wg0 peer r1 allowed-ips ::/0
set interfaces wireguard wg0 peer r1 endpoint '<自宅グローバルIP>:51820'
set interfaces wireguard wg0 peer r1 persistent-keepalive 25

# WireGuard (GCP r2-gcp)
set interfaces wireguard wg1 address 10.255.2.1/30
set interfaces wireguard wg1 mtu 1380
set interfaces wireguard wg1 port 51821
set interfaces wireguard wg1 private-key <r3-private-key>
set interfaces wireguard wg1 description 'VPN to GCP (r2-gcp)'
set interfaces wireguard wg1 peer r2-gcp public-key <r2-public-key>
set interfaces wireguard wg1 peer r2-gcp allowed-ips 10.255.2.2/32
set interfaces wireguard wg1 peer r2-gcp allowed-ips 10.255.1.0/30
set interfaces wireguard wg1 peer r2-gcp allowed-ips 192.168.10.0/24
set interfaces wireguard wg1 peer r2-gcp address 34.97.94.203
set interfaces wireguard wg1 peer r2-gcp port 51821
set interfaces wireguard wg1 peer r2-gcp persistent-keepalive 25
```

## 2. DHCP サーバー (v4)

### VLAN 11 (mgmt)

AP 等の管理機器向け。静的割り当ては [`mgmt-vlan-address.md`](mgmt-vlan-address.md) を参照。

| 項目 | 値 |
|------|-----|
| レンジ | 192.168.11.100 – .199 |
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
set service dhcp-server shared-network-name MGMT subnet 192.168.11.0/24 range 0 start 192.168.11.100
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

VyOS 内蔵 PowerDNS Recursor を使用。全 VLAN からのクエリを受け付け、上流 DNS へフォワードする。クエリログは法執行機関対応のため有効化。

```
# === DNS フォワーディング ===

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

## 4. IPv6 / RA / DHCPv6

OPTAGE から DHCPv6-PD で取得した /64 を自宅 r1 経由で受け取り、VLAN 30/40 で共有。VLAN 11 は v4 only。

### RA (Router Advertisement)

SLAAC (iOS/Android) と DHCPv6 (Windows/macOS) を併用する。

| フラグ | 値 | 効果 |
|---|---|---|
| A (autonomous) | 1 | SLAAC 有効 |
| M (managed) | 1 | DHCPv6 アドレス割り当て |
| O (other-config) | 1 | DHCPv6 で DNS 等取得 |
| RDNSS | 設定 | Android DNS 解決に必須 |

```
# === RA ===

# VLAN 30
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

### DHCPv6

Windows/macOS 向け。iOS/Android は DHCPv6 IA_NA 非対応のため SLAAC のみ。

```
# === DHCPv6 ===

# VLAN 30
set service dhcpv6-server shared-network-name STAFF-V6 subnet <delegated-prefix>::/64 address-range start <prefix>::1000 stop <prefix>::ffff
set service dhcpv6-server shared-network-name STAFF-V6 subnet <delegated-prefix>::/64 name-server <prefix>::1

# VLAN 40
set service dhcpv6-server shared-network-name USER-V6 subnet <delegated-prefix>::/64 address-range start <prefix>::1:0 stop <prefix>::1:ffff
set service dhcpv6-server shared-network-name USER-V6 subnet <delegated-prefix>::/64 name-server <prefix>::1
```

## 5. ndppd (NDP Proxy)

VLAN 30/40 が同一 /64 を共有するため、インバウンド IPv6 の Neighbor Solicitation を正しいインターフェースに振り分ける。VyOS CLI 外の設定ファイル。

```
# /etc/ndppd.conf
proxy wg0 {
    rule <delegated-prefix>::/64 {
        iface eth2.30
        iface eth2.40
    }
}
```

## 6. BGP

### ピアリング

| ピア | アドレス | AS | インターフェース | 用途 |
|------|---------|-----|-----------------|------|
| r1-home | 10.255.0.1 | 65002 | wg0 | 自宅との直接接続 |
| r2-gcp | 10.255.2.2 | 64512 | wg1 | GCP トランジット |

### 広告・受信

| 方向 | 経路 |
|------|------|
| 広告 | 192.168.11.0/24, 192.168.30.0/24, 192.168.40.0/22 |
| 受信 (r1) | 0.0.0.0/0 (デフォルトルート) |
| 受信 (r2-gcp) | r1 経由の経路 (GCP トランジット、フォールバック) + GCE サブネット |

### 経路優先度制御

WireGuard 直接リンク (r1) を優先し、r2-gcp 経由をフォールバックにする。AS path 長 (2 hop vs 3 hop) で自然に選択されるが、確実性のため local-preference を併用する。

```
# === BGP ===

set protocols bgp system-as 65001

# --- r1 (WireGuard 直接) ---
set protocols bgp neighbor 10.255.0.1 remote-as 65002
set protocols bgp neighbor 10.255.0.1 description 'Home router (r1)'
set protocols bgp neighbor 10.255.0.1 address-family ipv4-unicast
set protocols bgp neighbor 10.255.0.1 address-family ipv4-unicast route-map import WG-IN

# --- r2-gcp (GCP トランジット) ---
set protocols bgp neighbor 10.255.2.2 remote-as 64512
set protocols bgp neighbor 10.255.2.2 description 'r2-gcp'
set protocols bgp neighbor 10.255.2.2 address-family ipv4-unicast
set protocols bgp neighbor 10.255.2.2 address-family ipv4-unicast route-map import GCP-IN

# --- Route Map ---

# WireGuard 直接: local-pref 200 (優先)
set policy route-map WG-IN rule 10 action permit
set policy route-map WG-IN rule 10 set local-preference 200

# GCP 経由: local-pref 50 (フォールバック)
set policy route-map GCP-IN rule 10 action permit
set policy route-map GCP-IN rule 10 set local-preference 50

# 会場サブネット広告
set protocols bgp address-family ipv4-unicast network 192.168.11.0/24
set protocols bgp address-family ipv4-unicast network 192.168.30.0/24
set protocols bgp address-family ipv4-unicast network 192.168.40.0/22

# BGP ルートの AD を 20 に (DHCP default AD210 より優先、wg0 経由でユーザートラフィック転送)
set protocols bgp parameters distance global external 20
set protocols bgp parameters distance global internal 200
set protocols bgp parameters distance global local 200
```

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
set system flow-accounting netflow server 192.168.11.10 port 2055
set system flow-accounting netflow timeout expiry-interval 60
set system flow-accounting netflow timeout flow-active 120
set system flow-accounting netflow timeout flow-inactive 15
set system flow-accounting netflow source-ip 192.168.11.1
```

## 10. Syslog

全ログを Local Server (192.168.11.10) に転送。DNS クエリログ、DHCP forensic ログ、NDP ダンプが含まれる。

```
# === Syslog ===

set system syslog host 192.168.11.10 facility all level info
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

## 12. システム基本設定

```
# === システム ===

set system host-name r3-vyos
set system time-zone Asia/Tokyo
set system name-server 192.168.11.1

# SSH (管理 VLAN からのみ想定、VLAN 40 は input filter でブロック)
set service ssh port 22
set service ssh disable-password-authentication
```

## 13. 完全コンフィグ一覧

以下は全 `set` コマンドをコピペ可能な形で集約したもの。`<placeholder>` は環境依存値。

```
# ============================================================
# r3-vyos 完全コンフィグ
# ============================================================

# --- システム ---
set system host-name r3-vyos
set system time-zone Asia/Tokyo
set system name-server 192.168.11.1

# --- SSH ---
set service ssh port 22
set service ssh disable-password-authentication

# --- インターフェース ---
set interfaces ethernet eth0 address dhcp
set interfaces ethernet eth0 description 'Uplink to blackbox'
set interfaces ethernet eth1 description 'SoftEther bridge (vmbr1)'
set interfaces ethernet eth2 description 'VLAN trunk to PoE switch'

set interfaces ethernet eth2 vif 11 address 192.168.11.1/24
set interfaces ethernet eth2 vif 11 description 'VLAN 11 - mgmt'
set interfaces ethernet eth2 vif 30 address 192.168.30.1/24
set interfaces ethernet eth2 vif 30 description 'VLAN 30 - staff + live'
set interfaces ethernet eth2 vif 40 address 192.168.40.1/22
set interfaces ethernet eth2 vif 40 description 'VLAN 40 - user'

# --- WireGuard ---
set interfaces wireguard wg0 address 10.255.0.2/30
set interfaces wireguard wg0 mtu 1380
set interfaces wireguard wg0 port 51820
set interfaces wireguard wg0 private-key <r3-private-key>
set interfaces wireguard wg0 description 'VPN to home (r1)'
set interfaces wireguard wg0 peer r1 public-key <r1-public-key>
set interfaces wireguard wg0 peer r1 allowed-ips 0.0.0.0/0
set interfaces wireguard wg0 peer r1 allowed-ips ::/0
set interfaces wireguard wg0 peer r1 endpoint '<自宅グローバルIP>:51820'
set interfaces wireguard wg0 peer r1 persistent-keepalive 25

set interfaces wireguard wg1 address 10.255.2.1/30
set interfaces wireguard wg1 mtu 1380
set interfaces wireguard wg1 port 51821
set interfaces wireguard wg1 private-key <r3-private-key>
set interfaces wireguard wg1 description 'VPN to GCP (r2-gcp)'
set interfaces wireguard wg1 peer r2-gcp public-key <r2-public-key>
set interfaces wireguard wg1 peer r2-gcp allowed-ips 10.255.2.2/32
set interfaces wireguard wg1 peer r2-gcp allowed-ips 10.255.1.0/30
set interfaces wireguard wg1 peer r2-gcp allowed-ips 192.168.10.0/24
set interfaces wireguard wg1 peer r2-gcp address 34.97.94.203
set interfaces wireguard wg1 peer r2-gcp port 51821
set interfaces wireguard wg1 peer r2-gcp persistent-keepalive 25

# --- DHCP サーバー ---
set service dhcp-server shared-network-name MGMT subnet 192.168.11.0/24 range 0 start 192.168.11.100
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

# --- DNS フォワーディング ---
set service dns forwarding listen-address 192.168.11.1
set service dns forwarding listen-address 192.168.30.1
set service dns forwarding listen-address 192.168.40.1
set service dns forwarding allow-from 192.168.11.0/24
set service dns forwarding allow-from 192.168.30.0/24
set service dns forwarding allow-from 192.168.40.0/22
set service dns forwarding system
set service dns forwarding options 'log-common-errors=yes'
set service dns forwarding options 'quiet=no'
set service dns forwarding options 'logging-facility=0'

# --- RA ---
set service router-advert interface eth2.30 prefix <delegated-prefix>::/64 autonomous-flag true
set service router-advert interface eth2.30 managed-flag true
set service router-advert interface eth2.30 other-config-flag true
set service router-advert interface eth2.30 name-server <prefix>::1

set service router-advert interface eth2.40 prefix <delegated-prefix>::/64 autonomous-flag true
set service router-advert interface eth2.40 managed-flag true
set service router-advert interface eth2.40 other-config-flag true
set service router-advert interface eth2.40 name-server <prefix>::1

# --- DHCPv6 ---
set service dhcpv6-server shared-network-name STAFF-V6 subnet <delegated-prefix>::/64 address-range start <prefix>::1000 stop <prefix>::ffff
set service dhcpv6-server shared-network-name STAFF-V6 subnet <delegated-prefix>::/64 name-server <prefix>::1

set service dhcpv6-server shared-network-name USER-V6 subnet <delegated-prefix>::/64 address-range start <prefix>::1:0 stop <prefix>::1:ffff
set service dhcpv6-server shared-network-name USER-V6 subnet <delegated-prefix>::/64 name-server <prefix>::1

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
set policy route-map GCP-IN rule 10 action permit
set policy route-map GCP-IN rule 10 set local-preference 50

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

# --- Flow Accounting ---
set system flow-accounting interface eth2.30
set system flow-accounting interface eth2.40
set system flow-accounting interface wg0
set system flow-accounting netflow version 9
set system flow-accounting netflow server 192.168.11.10 port 2055
set system flow-accounting netflow timeout expiry-interval 60
set system flow-accounting netflow timeout flow-active 120
set system flow-accounting netflow timeout flow-inactive 15
set system flow-accounting netflow source-ip 192.168.11.1

# --- Syslog ---
set system syslog host 192.168.11.10 facility all level info

# --- NDP ダンプ ---
set system task-scheduler task ndp-dump interval 1m
set system task-scheduler task ndp-dump executable path /config/scripts/ndp-dump.sh
```
