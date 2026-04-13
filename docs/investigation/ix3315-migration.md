# IX3315 → VyOS 移行記録 (r1)

自宅ルーター (r1) を NEC IX3315 から VyOS に移行した際の作業記録。移行は完了済み。本書はトラブル発生時のロールバック判断や類似移行の参考資料として保持。

現行 r1 (VyOS) の設計は [`../design/home-vyos.md`](../design/home-vyos.md) を参照。

## 移行前 IX3315 構成

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
| IPv6 | DHCPv6-PD client (WAN) → RA + DHCPv6 server (LAN) ※VyOS 移行で廃止、/64 は会場へ転送 |
| デフォルトルート | v4/v6 ともに WAN (PPPoE) |

**最重要制約 (当時)**: 家族用ネットワーク 192.168.10.0/24 を止めてはならない。移行時にダウンタイムを最小限にする。

## IX3315 ↔ VyOS 機能対応表

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

## 移行手順 (実施済み)

### 前提

- VyOS は別の物理 NIC (または VM) で事前にセットアップし、設定を完成させてから切り替える
- 家族用 LAN (192.168.10.0/24) のダウンタイムを最小化する

### 手順

1. **事前準備 (IX3315 稼働中)**
   - VyOS をインストールし、設計通りの設定を投入
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

## 構築作業用の一時設定 (eth3 — 現在は撤去済み)

会場上流 (blackbox) を再現するため、eth3 に RJ45 SFP+ モジュール経由で Proxmox (USB 2.5GbE) を直結し、当日の `10.64.56.0/22` を DHCP で配布、r3 eth0 (`address dhcp`) が本番同等の条件で動作することを検証した。構築完了後に削除済み。

### 設定内容 (参考)

```
set interfaces ethernet eth3 address 10.64.56.1/22
set interfaces ethernet eth3 description 'Venue upstream simulator'

set service dhcp-server shared-network-name VENUE-TEST subnet 10.64.56.0/22 subnet-id 2
set service dhcp-server shared-network-name VENUE-TEST subnet 10.64.56.0/22 range 0 start 10.64.56.100
set service dhcp-server shared-network-name VENUE-TEST subnet 10.64.56.0/22 range 0 stop 10.64.56.199
set service dhcp-server shared-network-name VENUE-TEST subnet 10.64.56.0/22 option default-router 10.64.56.1
set service dhcp-server shared-network-name VENUE-TEST subnet 10.64.56.0/22 option name-server 10.64.56.1
set service dhcp-server listen-interface eth3

set service dns forwarding listen-address 10.64.56.1
set service dns forwarding allow-from 10.64.56.0/22

set nat source rule 140 outbound-interface name pppoe0
set nat source rule 140 source address 10.64.56.0/22
set nat source rule 140 translation address masquerade
set nat source rule 140 description 'Venue upstream test'
```

### 削除手順 (実施済み)

```
delete interfaces ethernet eth3 address 10.64.56.1/22
delete interfaces ethernet eth3 description
delete service dhcp-server shared-network-name VENUE-TEST
delete service dhcp-server listen-interface eth3
delete service dns forwarding listen-address 10.64.56.1
delete service dns forwarding allow-from 10.64.56.0/22
delete nat source rule 140
```
