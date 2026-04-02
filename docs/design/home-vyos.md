f# 自宅 VyOS (r1) 設計書

## 概要

自宅ルーター (r1) を NEC IX3315 から VyOS に移行する。
**最重要制約**: 家族用ネットワーク 192.168.10.0/24 を止めてはならない。移行時にダウンタイムを最小限にする。

## 現行構成 (IX3315) の要約

| 機能 | 設定値 |
|------|--------|
| WAN | PPPoE on GE2 (OPTAGE) |
| LAN | Bridge (GE0, GE1, GE3, GE4) → BVI1: 192.168.10.1/24 |
| DHCP | 192.168.10.3–199, DNS=192.168.10.1 |
| DHCP 固定割り当て | .3 (88:c2:55:2f:d5:14), .4 (9c:6b:00:04:ca:19), .9 (70:85:c2:b1:6f:7b) |
| DNS | proxy-dns (フォワーディング) |
| NTP | server 192.168.10.9 |
| NAPT static (→.9) | TCP 22, 80, 443, 5201(tcp/udp), 51820(udp) |
| NAPT service | ICMP → 192.168.10.1 |
| IPv6 | DHCPv6-PD client (WAN) → RA + DHCPv6 server (LAN) ※VyOS では廃止、/64 は会場へ転送 |
| デフォルトルート | v4/v6 ともに WAN (PPPoE) |

## VyOS インターフェース設計

### 物理構成

- **X710-DA4**: 4ポート SFP+ (10GbE)。FS SFP-10GM-T-30 (10GBase-T SFP+ モジュール) を使用。NVM 9.56 にアップデート済み (7.00 ではベンダーロックあり)。
- **オンボード NIC**: Intel I219-V 1GbE (ASRock B360M-ITX/ac)。AP 接続に使用。

#### インターフェースマッピング (確定)

| ethN | 物理 NIC | 論理名 | 役割 | 備考 |
|------|----------|--------|------|------|
| eth0 | オンボード I219-V 1GbE | ETH-AP | LAN — AP (br0 メンバー) | Wi-Fi AP |
| eth1 | X710-DA4 (SFP+ + RJ45 モジュール) | ETH-WAN | WAN (PPPoE) → pppoe0 | OPTAGE 回線終端 |
| eth2 | X710-DA4 (SFP+ + RJ45 モジュール) | ETH-PC | LAN — デスクトップPC (br0 メンバー) | |
| eth3 | X710-DA4 (SFP+) | — | 検証用トランジット (r3 直結時) | |
| eth4 | X710-DA4 (SFP+) | — | 未使用 | |
| — | — | — | WireGuard 会場 VPN + BGP | wg0 |
| — | — | — | WireGuard GCP (r2-gcp) | wg1 |

### br0 (LAN ブリッジ)

```
set interfaces bridge br0 address 192.168.10.1/24
set interfaces bridge br0 member interface eth0
set interfaces bridge br0 member interface eth2
```

IX3315 の BVI1 と同等。家族用デバイスは AP (eth0) 経由の Wi-Fi またはデスクトップPC (eth2) の有線で接続する。

## WAN (PPPoE)

```
set interfaces ethernet eth1 description 'WAN-OPTAGE'
set interfaces pppoe pppoe0 source-interface eth1
set interfaces pppoe pppoe0 authentication user 'hoge'
set interfaces pppoe pppoe0 authentication password 'hoge'
set interfaces pppoe pppoe0 ip adjust-mss clamp-mss-to-pmtu
set interfaces pppoe pppoe0 ipv6 address autoconf
set interfaces pppoe pppoe0 ipv6 adjust-mss clamp-mss-to-pmtu
set interfaces pppoe pppoe0 dhcpv6-options pd 0 length 64
```

### DHCPv6-PD

OPTAGE から DHCPv6-PD で /64 を取得する。**自宅 LAN (br0) は IPv4 only** とし、取得した /64 は丸ごと会場 (r3) に転送する。

- br0 には IPv6 アドレスを割り当てない (RA も配信しない)
- /64 は wg0 経由で会場へ static route (後述)
- 会場側の r3 が RA を配信し、VLAN 30/40 で SLAAC を提供

## DHCP サーバー (192.168.10.0/24)

```
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 range 0 start 192.168.10.3
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 range 0 stop 192.168.10.199
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 default-router 192.168.10.1
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 dns-server 192.168.10.1
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 ntp-server 192.168.10.1
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 lease 86400

# 固定割り当て
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 static-mapping device-3 ip-address 192.168.10.3
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 static-mapping device-3 mac 88:c2:55:2f:d5:14
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 static-mapping main-pc ip-address 192.168.10.4
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 static-mapping main-pc mac 9c:6b:00:04:ca:19
# .9 (旧サーバー) は VyOS に置き換わったため固定割り当て廃止
```

## DNS フォワーディング

```
set service dns forwarding listen-address 192.168.10.1
set service dns forwarding listen-address 127.0.0.1
set service dns forwarding allow-from 192.168.10.0/24
set service dns forwarding allow-from 127.0.0.0/8
set service dns forwarding allow-from 192.168.11.0/24
set service dns forwarding allow-from 192.168.30.0/24
set service dns forwarding allow-from 192.168.40.0/22
set service dns forwarding cache-size 2048
set service dns forwarding name-server 59.190.147.97
set service dns forwarding name-server 59.190.146.145
```

OPTAGE ISP の DNS を明示指定。`system` オプションは `system name-server` の値も上流に含めるため、`127.0.0.1` を指定するとフォワーディングループが発生する。これを回避するため `system` を使わず `name-server` で直接指定する。

ルーター自身の DNS 解決のため `127.0.0.1` でもリッスンし、`system name-server 127.0.0.1` で resolv.conf に反映する。

## NTP

```
set service ntp listen-address 192.168.10.1
set service ntp server ntp.nict.jp
set service ntp server ntp.jst.mfeed.ad.jp
```

IX3315 では NTP クライアントとして 192.168.10.9 を参照していたが、旧サーバーは VyOS に置き換わるため、VyOS 自身が NTP サーバーを提供する。DHCP option 42 は 192.168.10.1 (VyOS) を案内。

### 起動順序の問題と対策

chrony は vyos-router.service より先に起動する場合があり、その時点では DNS forwarding (pdns-recursor) が未起動のため NTP サーバーのホスト名解決に失敗する。`chronyc activity` で `sources with unknown address` と表示され、NTP 同期が行われない。

対策として `/config/scripts/vyos-postconfig-bootup.script` で全サービス起動後に chrony を再起動する。

```bash
#!/bin/bash
# /config/scripts/vyos-postconfig-bootup.script
systemctl restart chrony
```

## NAT (NAPT)

### Source NAT (マスカレード)

```
set nat source rule 100 outbound-interface name pppoe0
set nat source rule 100 source address 192.168.10.0/24
set nat source rule 100 translation address masquerade
```

### Destination NAT (ポートフォワーディング → メインPC 192.168.10.4)

旧サーバー (.9) は VyOS に置き換わったため、SoftEther / iperf3 はメインPC (.4) で稼働させる。
SSH と WireGuard は VyOS 自身が終端するため DNAT 不要 (WAN-LOCAL で許可)。

#### SoftEther サーバー (メインPC 192.168.10.4)

自宅側は VPN の**受信側**であり、SoftEther サーバーを r1 配下のメインPC で稼働させる。会場側の SoftEther クライアント (Proxmox CT) がプロキシ CONNECT 経由で TCP 443 に接続し、L2 トンネルを確立する。詳細は [`venue-proxmox.md`](venue-proxmox.md) を参照。

- TCP 80/443 → 192.168.10.4 に DNAT (下記ルール 20, 30)
- プロキシ解除時は SoftEther 不使用 (WireGuard 直接接続)

```
set nat destination rule 20 description 'SoftEther-HTTP'
set nat destination rule 20 inbound-interface name pppoe0
set nat destination rule 20 protocol tcp
set nat destination rule 20 destination port 80
set nat destination rule 20 translation address 192.168.10.4

set nat destination rule 30 description 'SoftEther-HTTPS'
set nat destination rule 30 inbound-interface name pppoe0
set nat destination rule 30 protocol tcp
set nat destination rule 30 destination port 443
set nat destination rule 30 translation address 192.168.10.4

set nat destination rule 40 description 'iperf3-tcp'
set nat destination rule 40 inbound-interface name pppoe0
set nat destination rule 40 protocol tcp
set nat destination rule 40 destination port 5201
set nat destination rule 40 translation address 192.168.10.4

set nat destination rule 50 description 'iperf3-udp'
set nat destination rule 50 inbound-interface name pppoe0
set nat destination rule 50 protocol udp
set nat destination rule 50 destination port 5201
set nat destination rule 50 translation address 192.168.10.4
```

### ヘアピン NAT

IX3315 の `ip napt hairpinning` と同等。LAN 内から自宅のグローバル IP 宛にアクセスした場合、内部の DNAT 先に正しく転送されるようにする。

```
set nat destination rule 110 description 'Hairpin-SoftEther-HTTP'
set nat destination rule 110 inbound-interface name br0
set nat destination rule 110 protocol tcp
set nat destination rule 110 destination port 80
set nat destination rule 110 destination address <pppoe0-address>
set nat destination rule 110 translation address 192.168.10.4

set nat source rule 110 outbound-interface name br0
set nat source rule 110 source address 192.168.10.0/24
set nat source rule 110 destination address 192.168.10.4
set nat source rule 110 translation address masquerade

# 他のヘアピンルールも同様のパターンで追加
# PPPoE アドレスが動的なため、ヘアピン NAT は必要に応じて設定
# または DNS で内部アドレスを返す split-horizon で回避
```

## ファイアウォール

### WAN → ローカル (pppoe0 inbound)

```
set firewall ipv4 name WAN-LOCAL default-action drop

set firewall ipv4 name WAN-LOCAL rule 10 action accept
set firewall ipv4 name WAN-LOCAL rule 10 state established
set firewall ipv4 name WAN-LOCAL rule 10 state related

set firewall ipv4 name WAN-LOCAL rule 20 action accept
set firewall ipv4 name WAN-LOCAL rule 20 protocol icmp

set firewall ipv4 name WAN-LOCAL rule 30 action accept
set firewall ipv4 name WAN-LOCAL rule 30 protocol tcp
set firewall ipv4 name WAN-LOCAL rule 30 destination port 22
set firewall ipv4 name WAN-LOCAL rule 30 description 'SSH (ed25519 only — see service ssh)'

set firewall ipv4 name WAN-LOCAL rule 40 action accept
set firewall ipv4 name WAN-LOCAL rule 40 protocol udp
set firewall ipv4 name WAN-LOCAL rule 40 destination port 51820
set firewall ipv4 name WAN-LOCAL rule 40 description 'WireGuard from venue'

set firewall ipv4 input filter default-action accept
set firewall ipv4 input filter rule 10 action jump
set firewall ipv4 input filter rule 10 jump-target WAN-LOCAL
set firewall ipv4 input filter rule 10 inbound-interface name pppoe0
```

### WAN → LAN (フォワード)

```
set firewall ipv4 name WAN-LAN default-action drop

set firewall ipv4 name WAN-LAN rule 10 action accept
set firewall ipv4 name WAN-LAN rule 10 state established
set firewall ipv4 name WAN-LAN rule 10 state related

set firewall ipv4 name WAN-LAN rule 20 action accept
set firewall ipv4 name WAN-LAN rule 20 state new
set firewall ipv4 name WAN-LAN rule 20 destination address 192.168.10.4
set firewall ipv4 name WAN-LAN rule 20 protocol tcp
set firewall ipv4 name WAN-LAN rule 20 destination port 80,443,5201

set firewall ipv4 name WAN-LAN rule 30 action accept
set firewall ipv4 name WAN-LAN rule 30 state new
set firewall ipv4 name WAN-LAN rule 30 destination address 192.168.10.4
set firewall ipv4 name WAN-LAN rule 30 protocol udp
set firewall ipv4 name WAN-LAN rule 30 destination port 5201
```

### IPv6 ファイアウォール

```
set firewall ipv6 name WANv6-LOCAL default-action drop

set firewall ipv6 name WANv6-LOCAL rule 10 action accept
set firewall ipv6 name WANv6-LOCAL rule 10 state established
set firewall ipv6 name WANv6-LOCAL rule 10 state related

set firewall ipv6 name WANv6-LOCAL rule 20 action accept
set firewall ipv6 name WANv6-LOCAL rule 20 protocol icmpv6

set firewall ipv6 name WANv6-LOCAL rule 30 action accept
set firewall ipv6 name WANv6-LOCAL rule 30 protocol udp
set firewall ipv6 name WANv6-LOCAL rule 30 source port 547
set firewall ipv6 name WANv6-LOCAL rule 30 destination port 546
set firewall ipv6 name WANv6-LOCAL rule 30 description 'DHCPv6 replies'
```

## IPv6 設計

自宅 LAN (br0) では IPv6 を使用しない。IX3315 では RA + DHCPv6 サーバーを LAN に提供していたが、VyOS では廃止する。

理由: OPTAGE の DHCPv6-PD は /64 のみ。/64 は SLAAC の最小単位であり分割不可能なため、自宅と会場で共有できない。イベント参加者への IPv6 提供を優先し、/64 は全て会場に割り当てる。

自宅の家族用デバイスは IPv4 のみで運用する (現状でも IPv4 で十分機能しており、実質的な影響なし)。

## WireGuard (会場 VPN)

```
set interfaces wireguard wg0 address 10.255.0.1/30
set interfaces wireguard wg0 port 51820
set interfaces wireguard wg0 private-key <r1-private-key>
set interfaces wireguard wg0 mtu 1380

set interfaces wireguard wg0 peer venue public-key <r3-public-key>
set interfaces wireguard wg0 peer venue allowed-ips 10.255.0.2/32
set interfaces wireguard wg0 peer venue allowed-ips 192.168.11.0/24
set interfaces wireguard wg0 peer venue allowed-ips 192.168.30.0/24
set interfaces wireguard wg0 peer venue allowed-ips 192.168.40.0/22

set firewall options interface wg0 adjust-mss clamp-mss-to-pmtu
```

### WireGuard アドレス設計

| トンネル | ローカル | リモート | 用途 |
|---------|---------|---------|------|
| wg0 | 10.255.0.1/30 | r3 (10.255.0.2) | 会場直接 (優先) |
| wg1 | 10.255.1.1/30 | r2-gcp (10.255.1.2) | GCP トランジット |

### wg1 (GCP r2-gcp 向け)

```
set interfaces wireguard wg1 address 10.255.1.1/30
set interfaces wireguard wg1 port 51821
set interfaces wireguard wg1 private-key <r1-private-key>
set interfaces wireguard wg1 mtu 1380

set interfaces wireguard wg1 peer r2-gcp public-key <r2-public-key>
set interfaces wireguard wg1 peer r2-gcp address 34.97.94.203
set interfaces wireguard wg1 peer r2-gcp port 51820
set interfaces wireguard wg1 peer r2-gcp allowed-ips 10.255.1.2/32
set interfaces wireguard wg1 peer r2-gcp allowed-ips 10.255.2.0/30
set interfaces wireguard wg1 peer r2-gcp persistent-keepalive 25

set firewall options interface wg1 adjust-mss clamp-mss-to-pmtu
```

## BGP (AS65002)

### ピアリング

| ピア | アドレス | AS | インターフェース | 用途 |
|------|---------|-----|-----------------|------|
| r3-venue | 10.255.0.2 | 65001 | wg0 | 会場との直接接続 |
| r2-gcp | 10.255.1.2 | 64512 | wg1 | GCP トランジット |

### 経路優先度制御

WireGuard 直接リンクを優先し、r2-gcp 経由をフォールバックにする。AS path 長 (2 hop vs 3 hop) で自然に選択されるが、確実性のため local-preference を併用する。

```
set protocols bgp system-as 65002

# --- r3 (WireGuard 直接) ---
set protocols bgp neighbor 10.255.0.2 remote-as 65001
set protocols bgp neighbor 10.255.0.2 description 'venue-r3'
set protocols bgp neighbor 10.255.0.2 address-family ipv4-unicast
set protocols bgp neighbor 10.255.0.2 address-family ipv4-unicast route-map import WG-IN

# --- r2-gcp (GCP トランジット) ---
set protocols bgp neighbor 10.255.1.2 remote-as 64512
set protocols bgp neighbor 10.255.1.2 description 'r2-gcp'
set protocols bgp neighbor 10.255.1.2 address-family ipv4-unicast
set protocols bgp neighbor 10.255.1.2 address-family ipv4-unicast route-map import GCP-IN

# --- ネットワーク広告 ---
set protocols bgp address-family ipv4-unicast network 192.168.10.0/24

# --- Route Map ---

# WireGuard 直接: local-pref 200 (優先)
set policy route-map WG-IN rule 10 action permit
set policy route-map WG-IN rule 10 set local-preference 200

# GCP 経由: local-pref 50 (フォールバック)
set policy route-map GCP-IN rule 10 action permit
set policy route-map GCP-IN rule 10 set local-preference 50
```

WireGuard (wg0) ダウン時は r3 との BGP セッションも落ち、local-pref 200 の経路が消失。自動的に r2-gcp 経由 (local-pref 50) にフォールバックする。

## IPv6 プレフィックス委任 (会場向け)

OPTAGE から取得した DHCPv6-PD /64 を丸ごと会場 (r3) に転送する。自宅 LAN には割り当てない。

### 方式: VyOS dhcpv6-options pd でダミーインターフェースに割り当て + static route

```
# DHCPv6-PD で /64 を取得し、ダミーインターフェースに割り当てて経路を生成
set interfaces dummy dum0 address 0.0.0.0/32
set interfaces pppoe pppoe0 dhcpv6-options pd 0 interface dum0 sla-id 0 sla-len 0

# 取得した /64 を wg0 経由で会場へ転送
# ※ 実際のプレフィックスは動的に変わるため、dhclient-script hook で route を設定
```

### dhclient-script hook による動的ルーティング

DHCPv6-PD のプレフィックスは ISP 側で変わる可能性がある。VyOS の dhclient exit hook で、取得したプレフィックスを wg0 の next-hop に向ける。

```bash
#!/bin/bash
# /etc/dhcp/dhclient-exit-hooks.d/pd-route-to-venue
# DHCPv6-PD プレフィックス取得時に会場向け static route を設定

if [ "$reason" = "BOUND6" ] || [ "$reason" = "REBIND6" ]; then
  if [ -n "$new_ip6_prefix" ]; then
    # 既存ルートを削除してから再設定
    ip -6 route del ${new_ip6_prefix} dev wg0 2>/dev/null
    ip -6 route add ${new_ip6_prefix} dev wg0
  fi
fi
```

### 会場側 (r3) の RA 配信

r3 が受け取った /64 を VLAN 30/40 で RA 広告する。r1 側では RA を配信しない。

```
# r3 側 (参考)
set service router-advert interface eth2.30 prefix <delegated-prefix>::/64
set service router-advert interface eth2.40 prefix <delegated-prefix>::/64
```

## HTTPS API

```
set service https api keys id mykey key 'BwAI'
set service https api rest strict
```

管理 PC (eth0: 192.168.100.0/24) から VyOS 設定 API にアクセスするために使用。`scripts/r1-config.py` から curl で設定を投入する。

## SSH

```
set service ssh port 22
set service ssh disable-password-authentication
set service ssh hostkey-algorithm ssh-ed25519
```

WAN にも公開するため、ed25519 鍵認証のみに制限しパスワード認証を無効化する。listen-address を指定しないことで全インターフェースで受け付ける (WAN-LOCAL ファイアウォールで WAN 側も許可済み)。

## 移行手順

### 前提

- VyOS は別の物理 NIC (または VM) で事前にセットアップし、設定を完成させてから切り替える
- 家族用 LAN (192.168.10.0/24) のダウンタイムを最小化する

### 手順

1. **事前準備 (IX3315 稼働中)**
   - VyOS をインストールし、上記設定を投入
   - WAN 以外の設定 (DHCP, DNS, FW 等) を br0 に対して事前検証
   - WireGuard 鍵ペアを生成し、会場側 (r3) と共有

2. **切り替え (短時間停止)**
   - IX3315 の PPPoE セッションを切断
   - WAN ケーブルを IX3315 から VyOS の eth1 (X710 SFP+ + RJ45 モジュール) に差し替え
   - LAN ケーブルを IX3315 のブリッジポートから VyOS の eth0 (I219-V, AP) と eth2 (X710, PC) に差し替え
   - VyOS で PPPoE セッションを確立
   - LAN 側デバイスが DHCP リニューアルで 192.168.10.1 をゲートウェイとして再取得

3. **検証**
   - LAN デバイスからインターネットアクセスを確認
   - DHCP 固定割り当てデバイス (.3, .4, .9) の疎通確認
   - ポートフォワーディング (192.168.10.9 の各ポート) の動作確認
   - DHCPv6-PD /64 の取得確認 (`show dhcpv6 client pd`)
   - WireGuard トンネルの確立確認
   - 会場側で /64 の RA が正常に配信されることを確認 (会場セットアップ時)

4. **ロールバック計画**
   - 問題発生時はケーブルを IX3315 に戻すだけで即復旧可能
   - IX3315 の設定は変更しないため、差し戻しに設定作業は不要

## 設定一覧 (フルコンフィグ)

以下は上記設計をまとめた VyOS コマンドセットの全体像。

```
# === インターフェース ===

# WAN (PPPoE)
set interfaces ethernet eth1 description 'WAN-OPTAGE'
set interfaces pppoe pppoe0 source-interface eth1
set interfaces pppoe pppoe0 authentication user 'hoge'
set interfaces pppoe pppoe0 authentication password 'hoge'
set interfaces pppoe pppoe0 ip adjust-mss clamp-mss-to-pmtu
set interfaces pppoe pppoe0 ipv6 address autoconf
set interfaces pppoe pppoe0 ipv6 adjust-mss clamp-mss-to-pmtu
set interfaces pppoe pppoe0 dhcpv6-options pd 0 length 64

# DHCPv6-PD /64 → ダミーインターフェース経由で会場へ転送 (br0 には割り当てない)
set interfaces dummy dum0
set interfaces pppoe pppoe0 dhcpv6-options pd 0 interface dum0 sla-id 0

# LAN ブリッジ (家族用 192.168.10.0/24, IPv4 only)
# eth0=AP (I219-V), eth2=デスクトップPC (X710)
set interfaces bridge br0 address 192.168.10.1/24
set interfaces bridge br0 member interface eth0
set interfaces bridge br0 member interface eth2

# WireGuard (会場 VPN)
set interfaces wireguard wg0 address 10.255.0.1/30
set interfaces wireguard wg0 port 51820
set interfaces wireguard wg0 private-key <r1-private-key>
set interfaces wireguard wg0 mtu 1380
set interfaces wireguard wg0 peer venue public-key <r3-public-key>
set interfaces wireguard wg0 peer venue allowed-ips 10.255.0.2/32
set interfaces wireguard wg0 peer venue allowed-ips 192.168.11.0/24
set interfaces wireguard wg0 peer venue allowed-ips 192.168.30.0/24
set interfaces wireguard wg0 peer venue allowed-ips 192.168.40.0/22

# WireGuard (GCP r2-gcp)
set interfaces wireguard wg1 address 10.255.1.1/30
set interfaces wireguard wg1 port 51821
set interfaces wireguard wg1 private-key <r1-private-key>
set interfaces wireguard wg1 mtu 1380
set interfaces wireguard wg1 peer r2-gcp public-key <r2-public-key>
set interfaces wireguard wg1 peer r2-gcp address 34.97.94.203
set interfaces wireguard wg1 peer r2-gcp port 51820
set interfaces wireguard wg1 peer r2-gcp allowed-ips 10.255.1.2/32
set interfaces wireguard wg1 peer r2-gcp allowed-ips 10.255.2.0/30
set interfaces wireguard wg1 peer r2-gcp persistent-keepalive 25

# MSS Clamping (wg0, wg1)
set firewall options interface wg0 adjust-mss clamp-mss-to-pmtu
set firewall options interface wg1 adjust-mss clamp-mss-to-pmtu

# === NAT ===

# Source NAT (マスカレード)
set nat source rule 100 outbound-interface name pppoe0
set nat source rule 100 source address 192.168.10.0/24
set nat source rule 100 translation address masquerade

# 会場トラフィックもマスカレード
set nat source rule 110 outbound-interface name pppoe0
set nat source rule 110 source address 192.168.11.0/24
set nat source rule 110 translation address masquerade
set nat source rule 120 outbound-interface name pppoe0
set nat source rule 120 source address 192.168.30.0/24
set nat source rule 120 translation address masquerade
set nat source rule 130 outbound-interface name pppoe0
set nat source rule 130 source address 192.168.40.0/22
set nat source rule 130 translation address masquerade

# Destination NAT (ポートフォワーディング → メインPC 192.168.10.4)
# SSH → VyOS 自身 (WAN-LOCAL で許可), WireGuard → VyOS 自身 (WAN-LOCAL で許可)
set nat destination rule 20 description 'SoftEther-HTTP'
set nat destination rule 20 inbound-interface name pppoe0
set nat destination rule 20 protocol tcp
set nat destination rule 20 destination port 80
set nat destination rule 20 translation address 192.168.10.4

set nat destination rule 30 description 'SoftEther-HTTPS'
set nat destination rule 30 inbound-interface name pppoe0
set nat destination rule 30 protocol tcp
set nat destination rule 30 destination port 443
set nat destination rule 30 translation address 192.168.10.4

set nat destination rule 40 description 'iperf3-tcp'
set nat destination rule 40 inbound-interface name pppoe0
set nat destination rule 40 protocol tcp
set nat destination rule 40 destination port 5201
set nat destination rule 40 translation address 192.168.10.4

set nat destination rule 50 description 'iperf3-udp'
set nat destination rule 50 inbound-interface name pppoe0
set nat destination rule 50 protocol udp
set nat destination rule 50 destination port 5201
set nat destination rule 50 translation address 192.168.10.4

# === ファイアウォール ===

# WAN → ローカル
set firewall ipv4 name WAN-LOCAL default-action drop
set firewall ipv4 name WAN-LOCAL rule 10 action accept
set firewall ipv4 name WAN-LOCAL rule 10 state established
set firewall ipv4 name WAN-LOCAL rule 10 state related
set firewall ipv4 name WAN-LOCAL rule 20 action accept
set firewall ipv4 name WAN-LOCAL rule 20 protocol icmp
set firewall ipv4 name WAN-LOCAL rule 30 action accept
set firewall ipv4 name WAN-LOCAL rule 30 protocol tcp
set firewall ipv4 name WAN-LOCAL rule 30 destination port 22
set firewall ipv4 name WAN-LOCAL rule 30 description 'SSH (ed25519 only)'
set firewall ipv4 name WAN-LOCAL rule 40 action accept
set firewall ipv4 name WAN-LOCAL rule 40 protocol udp
set firewall ipv4 name WAN-LOCAL rule 40 destination port 51820
set firewall ipv4 name WAN-LOCAL rule 40 description 'WireGuard from venue'
set firewall ipv4 name WAN-LOCAL rule 50 action accept
set firewall ipv4 name WAN-LOCAL rule 50 protocol udp
set firewall ipv4 name WAN-LOCAL rule 50 destination port 51821
set firewall ipv4 name WAN-LOCAL rule 50 description 'WireGuard from GCP'

# WAN → LAN (DNAT トラフィック → メインPC)
set firewall ipv4 name WAN-LAN default-action drop
set firewall ipv4 name WAN-LAN rule 10 action accept
set firewall ipv4 name WAN-LAN rule 10 state established
set firewall ipv4 name WAN-LAN rule 10 state related
set firewall ipv4 name WAN-LAN rule 20 action accept
set firewall ipv4 name WAN-LAN rule 20 state new
set firewall ipv4 name WAN-LAN rule 20 destination address 192.168.10.4
set firewall ipv4 name WAN-LAN rule 20 protocol tcp
set firewall ipv4 name WAN-LAN rule 20 destination port 80,443,5201
set firewall ipv4 name WAN-LAN rule 30 action accept
set firewall ipv4 name WAN-LAN rule 30 state new
set firewall ipv4 name WAN-LAN rule 30 destination address 192.168.10.4
set firewall ipv4 name WAN-LAN rule 30 protocol udp
set firewall ipv4 name WAN-LAN rule 30 destination port 5201

# IPv6 WAN → ローカル
set firewall ipv6 name WANv6-LOCAL default-action drop
set firewall ipv6 name WANv6-LOCAL rule 10 action accept
set firewall ipv6 name WANv6-LOCAL rule 10 state established
set firewall ipv6 name WANv6-LOCAL rule 10 state related
set firewall ipv6 name WANv6-LOCAL rule 20 action accept
set firewall ipv6 name WANv6-LOCAL rule 20 protocol icmpv6
set firewall ipv6 name WANv6-LOCAL rule 30 action accept
set firewall ipv6 name WANv6-LOCAL rule 30 protocol udp
set firewall ipv6 name WANv6-LOCAL rule 30 source port 547
set firewall ipv6 name WANv6-LOCAL rule 30 destination port 546
set firewall ipv6 name WANv6-LOCAL rule 30 description 'DHCPv6 replies'

# ファイアウォール適用
set firewall ipv4 input filter default-action accept
set firewall ipv4 input filter rule 10 action jump
set firewall ipv4 input filter rule 10 jump-target WAN-LOCAL
set firewall ipv4 input filter rule 10 inbound-interface name pppoe0

set firewall ipv4 forward filter default-action accept
set firewall ipv4 forward filter rule 10 action jump
set firewall ipv4 forward filter rule 10 jump-target WAN-LAN
set firewall ipv4 forward filter rule 10 inbound-interface name pppoe0

# === サービス ===

# DHCP サーバー
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 range 0 start 192.168.10.3
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 range 0 stop 192.168.10.199
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 default-router 192.168.10.1
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 dns-server 192.168.10.1
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 ntp-server 192.168.10.1
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 lease 86400
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 static-mapping device-3 ip-address 192.168.10.3
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 static-mapping device-3 mac 88:c2:55:2f:d5:14
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 static-mapping main-pc ip-address 192.168.10.4
set service dhcp-server shared-network-name FAMILY subnet 192.168.10.0/24 static-mapping main-pc mac 9c:6b:00:04:ca:19
# .9 (旧サーバー) は VyOS に置き換わったため固定割り当て廃止

# DNS フォワーディング (ISP DNS 明示指定、system はループ回避のため不使用)
set service dns forwarding listen-address 192.168.10.1
set service dns forwarding listen-address 127.0.0.1
set service dns forwarding allow-from 192.168.10.0/24
set service dns forwarding allow-from 127.0.0.0/8
set service dns forwarding allow-from 192.168.11.0/24
set service dns forwarding allow-from 192.168.30.0/24
set service dns forwarding allow-from 192.168.40.0/22
set service dns forwarding cache-size 2048
set service dns forwarding name-server 59.190.147.97
set service dns forwarding name-server 59.190.146.145

# SSH (WAN 公開、ed25519 鍵認証のみ)
set service ssh port 22
set service ssh disable-password-authentication
set service ssh hostkey-algorithm ssh-ed25519

# NTP
set service ntp listen-address 192.168.10.1
set service ntp server ntp.nict.jp
set service ntp server ntp.jst.mfeed.ad.jp

# br0 では IPv6 を使用しない (RA 配信なし)
# DHCPv6-PD /64 は wg0 経由で会場に転送 (dhclient-exit-hooks で動的設定)

# === ルーティング ===

# デフォルトルートは pppoe0 から自動取得
# 会場サブネットへの static route
set protocols static route 192.168.11.0/24 next-hop 10.255.0.2
set protocols static route 192.168.30.0/24 next-hop 10.255.0.2
set protocols static route 192.168.40.0/22 next-hop 10.255.0.2

# BGP (AS65002)
set protocols bgp system-as 65002

# r3 (WireGuard 直接)
set protocols bgp neighbor 10.255.0.2 remote-as 65001
set protocols bgp neighbor 10.255.0.2 description 'venue-r3'
set protocols bgp neighbor 10.255.0.2 address-family ipv4-unicast
set protocols bgp neighbor 10.255.0.2 address-family ipv4-unicast route-map import WG-IN

# r2-gcp (GCP トランジット)
set protocols bgp neighbor 10.255.1.2 remote-as 64512
set protocols bgp neighbor 10.255.1.2 description 'r2-gcp'
set protocols bgp neighbor 10.255.1.2 address-family ipv4-unicast
set protocols bgp neighbor 10.255.1.2 address-family ipv4-unicast route-map import GCP-IN

# ネットワーク広告
set protocols bgp address-family ipv4-unicast network 192.168.10.0/24

# Route Map
set policy route-map WG-IN rule 10 action permit
set policy route-map WG-IN rule 10 set local-preference 200
set policy route-map GCP-IN rule 10 action permit
set policy route-map GCP-IN rule 10 set local-preference 50

# === システム ===

set system host-name r1-home
set system time-zone Asia/Tokyo
set system name-server 127.0.0.1

# HTTPS API
set service https api keys id mykey key 'BwAI'
set service https api rest strict
```

## IX3315 との機能対応表

| 機能 | IX3315 | VyOS | 備考 |
|------|--------|------|------|
| PPPoE | `ppp profile` + `encapsulation pppoe` | `interfaces pppoe pppoe0` | |
| LAN ブリッジ | `bridge irb` + `bridge-group 1` + `BVI1` | `interfaces bridge br0` | |
| NAPT (source) | `ip napt enable` | `nat source rule` | |
| NAPT (static) | `ip napt static` | `nat destination rule` | |
| ヘアピン NAT | `ip napt hairpinning` | `nat destination/source rule` (手動) | VyOS は明示設定が必要 |
| DHCP サーバー | `ip dhcp profile` | `service dhcp-server` | |
| DHCP 固定割り当て | `fixed-assignment` | `static-mapping` | |
| DNS フォワーディング | `proxy-dns` | `service dns forwarding` | ISP DNS 明示指定 (`system` はループするため不使用) |
| IPv6 RA (LAN) | `ipv6 nd ra enable` | — | 自宅 LAN では廃止。/64 は会場へ転送 |
| DHCPv6-PD | `ipv6 dhcp client-profile` | `pppoe0 dhcpv6-options pd` | /64 を取得、会場へ全量転送 |
| DHCPv6 サーバー (LAN) | `ipv6 dhcp server-profile` | — | 自宅 LAN では廃止 |
| ACL (HTTP) | `ip access-list web-http-acl` | `firewall ipv4` | |
| SSH | `ssh-server ip enable` | `service ssh` | |
| NTP | `ntp server` | `service ntp` | |
| WireGuard | — | `interfaces wireguard wg0` | 新規追加 |
| BGP | — | `protocols bgp` | 新規追加 |

## 構築作業用の一時設定 (eth3)

eth3 にスイッチを接続し、会場の r3 (Proxmox) を配下に繋いで構築作業を行うための一時設定。
構築完了後に削除すること。

### 追加した設定

```
set interfaces ethernet eth3 vif 11 address 192.168.11.254/24
set interfaces ethernet eth3 vif 11 description 'MGMT VLAN (construction)'
set protocols static route 192.168.30.0/24 next-hop 192.168.11.1
set protocols static route 192.168.40.0/22 next-hop 192.168.11.1
set service dns forwarding listen-address 192.168.11.254
```

### 変更した設定

| 項目 | 変更前 | 変更後 |
|------|--------|--------|
| static route 192.168.11.0/24 | next-hop 10.255.0.2 (wg0) | 削除 (connected route で到達) |
| static route 192.168.30.0/24 | next-hop 10.255.0.2 (wg0) | next-hop 192.168.11.1 (eth3.11) |
| static route 192.168.40.0/22 | next-hop 10.255.0.2 (wg0) | next-hop 192.168.11.1 (eth3.11) |

### 削除手順 (構築完了後)

```
# 一時設定の削除
delete interfaces ethernet eth3 vif 11
delete protocols static route 192.168.30.0/24 next-hop 192.168.11.1
delete protocols static route 192.168.40.0/22 next-hop 192.168.11.1
delete service dns forwarding listen-address 192.168.11.254

# wg0 経由の static route を復元
set protocols static route 192.168.11.0/24 next-hop 10.255.0.2
set protocols static route 192.168.30.0/24 next-hop 10.255.0.2
set protocols static route 192.168.40.0/22 next-hop 10.255.0.2
```

### API で削除する場合

```bash
curl -sk -X POST https://192.168.10.1/configure -F data='[
  {"op": "delete", "path": ["interfaces", "ethernet", "eth3", "vif", "11"]},
  {"op": "delete", "path": ["protocols", "static", "route", "192.168.30.0/24", "next-hop", "192.168.11.1"]},
  {"op": "delete", "path": ["protocols", "static", "route", "192.168.40.0/22", "next-hop", "192.168.11.1"]},
  {"op": "delete", "path": ["service", "dns", "forwarding", "listen-address", "192.168.11.254"]},
  {"op": "set", "path": ["protocols", "static", "route", "192.168.11.0/24", "next-hop", "10.255.0.2"]},
  {"op": "set", "path": ["protocols", "static", "route", "192.168.30.0/24", "next-hop", "10.255.0.2"]},
  {"op": "set", "path": ["protocols", "static", "route", "192.168.40.0/22", "next-hop", "10.255.0.2"]}
]' -F key='BwAI'
```

## 注意事項

- PPPoE 認証情報はこのドキュメントに記載しているが、本番では secret 管理を検討すること
- `<r1-private-key>`, `<r3-public-key>` は WireGuard 鍵生成後に差し替え
- OPTAGE の DHCPv6-PD は /64 のみ。自宅 LAN は IPv4 only とし、/64 は会場に全量転送する
- VyOS のバージョンは 2026.03 (Circinus, rolling release) を使用
