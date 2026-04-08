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

��場サブネット (192.168.11/30/40) のマ��カレードは全量設定の方に記載 (rule 110–130)。

加えて、**WG トンネルアド���ス (10.255.0.0/24)** ��マスカレードも必要。r3 ルーター自身が発するトラフィック (DNS, NTP, ping 等) は BGP default で wg0 経由 r1 に届くが、source が 10.255.0.2 (wg0 アドレス) となり、他のルールでカバーされない。SNAT されないまま pppoe0 に出るとプライベート src IP のため ISP で drop される。

```
set nat source rule 150 outbound-interface name pppoe0
set nat source rule 150 source address 10.255.0.0/24
set nat source rule 150 translation address masquerade
set nat source rule 150 description 'WG tunnel addresses masquerade'
```

### Destination NAT (ポートフォワーデ��ング → メインPC 192.168.10.4)

旧サーバー (.9) は VyOS に置き換わったため、wstunnel / iperf3 はメインPC (.4) で稼働させる。
SSH と WireGuard は VyOS 自身が終端するため DNAT 不要 (WAN-LOCAL で許可)。

#### wstunnel サーバー (メインPC 192.168.10.4)

自宅側は VPN の**受信側**であり、wstunnel サーバーを r1 配下のメインPC で稼働させる。会場側の wstunnel クライアント (r3 VyOS 上の podman コンテナ) が WSS (TCP 443) で接続し、WireGuard UDP パケットを WebSocket (TLS) で中継する。詳細は [`venue-proxmox.md`](venue-proxmox.md) を参照。

- TCP 443 → 192.168.10.4 に DNAT (下記ルール 30)
- ポート制限なしの場合は wstunnel 不使用 (WireGuard 直接接続)

wstunnel サーバーの起動コマンド:

```bash
wstunnel server --restrict-to 192.168.10.1:51820 wss://[::]:443
```

`--restrict-to` により、トンネル先を r1 の WireGuard (192.168.10.1:51820) に限定する。wstunnel サーバーはメインPC で動作するため、r1 の LAN IP を指定する。

```
set nat destination rule 30 description 'wstunnel-HTTPS'
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
set nat destination rule 110 description 'Hairpin-wstunnel-HTTPS'
set nat destination rule 110 inbound-interface name br0
set nat destination rule 110 protocol tcp
set nat destination rule 110 destination port 443
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

## Conntrack イベントログ (NAPT 変換記録)

法執行機関からの照会対応として、masquerade による NAPT 変換のマッピングを conntrack イベントとして記録する。詳細は [`logging-compliance.md`](logging-compliance.md) を参照。

### なぜ必要か

会場側の NetFlow は NAT 前のクライアント IP を記録するが、法執行機関からの照会は「グローバル IP X.X.X.X のポート Y から Z 時刻に通信があった」という形式。masquerade の変換テーブル (内部 IP:port ↔ グローバル IP:port) を記録しないと、この紐付けができない。

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
set interfaces wireguard wg0 mtu 1400

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
set interfaces wireguard wg1 mtu 1400

set interfaces wireguard wg1 peer r2-gcp public-key <r2-public-key>
set interfaces wireguard wg1 peer r2-gcp address 34.97.197.104
set interfaces wireguard wg1 peer r2-gcp port 51820
set interfaces wireguard wg1 peer r2-gcp allowed-ips 10.255.1.2/32
set interfaces wireguard wg1 peer r2-gcp allowed-ips 10.255.2.0/30
set interfaces wireguard wg1 peer r2-gcp allowed-ips 192.168.11.0/24
set interfaces wireguard wg1 peer r2-gcp allowed-ips 192.168.30.0/24
set interfaces wireguard wg1 peer r2-gcp allowed-ips 192.168.40.0/22
set interfaces wireguard wg1 peer r2-gcp persistent-keepalive 25

set firewall options interface wg1 adjust-mss clamp-mss-to-pmtu
```

> **注**: r2-gcp peer に会場プレフィックスを許可しているのは、r1↔r3 直結断時に r2-gcp 経由で会場トラフィックを迂回受信するため。

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
# r3 (venue) に default route を広告 (venue ユーザートラフィックを自宅 pppoe0 経由で抜くため)
set protocols bgp neighbor 10.255.0.2 address-family ipv4-unicast default-originate

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

### default-originate について

`default-originate` により r1-home は venue-r3 に対して BGP で `0.0.0.0/0` を広告する。r3 側はこれを AD=20 でカーネルに投入し、DHCP 由来の default route (AD=210) より優先される。これによって venue のユーザートラフィックが wg0 経由で r1-home に到達し、pppoe0 から Internet へ抜ける設計が成立する。

**注意点 (r3 側のループ防止)**: r3 の wg0 peer endpoint は r1-home の公開 IP (pppoe0 アドレス) であり、`allowed-ips 0.0.0.0/0` を設定しているため、r3 に BGP default が刺さった瞬間に WG 外殻パケット (outer dst = r1 公開 IP) まで wg0 に吸われてループする危険がある。対策は r3 側の [venue-vyos.md](venue-vyos.md) 参照 (tracker スクリプトで `/32` escape route を kernel 直叩きで管理)。

**r1 側の静的経路クリーンアップ**: default-originate 投入と同時に、旧設計の残骸である以下の static route は削除済み。残っていると BGP (AD=20) より static (AD=1) が優先され、venue 戻りが wg1 (GCP) に誤配送されて `host unreachable` を吐く。

```
# 削除済み (旧 GCP 経由 venue 到達想定の残骸)
# set protocols static route 192.168.11.0/24
# set protocols static route 192.168.30.0/24 next-hop 10.255.1.2
# set protocols static route 192.168.40.0/22 next-hop 10.255.1.2
```

## IPv6 プレフィックス委任 (会場向け)

OPTAGE から取得した DHCPv6-PD /64 を丸ごと会場 (r3) に転送する。自宅 LAN には割り当てない。

### 方式: VyOS dhcpv6-options pd でダミーインターフェースに割り当て + 自動転送スクリプト

```
# DHCPv6-PD で /64 を取得し、ダミーインターフェースに割り当て
set interfaces dummy dum0
set interfaces pppoe pppoe0 dhcpv6-options pd 0 interface dum0 sla-id 0

# 自動転送スクリプトを 1 分間隔で実行
set system task-scheduler task pd-update interval 1m
set system task-scheduler task pd-update executable path /config/scripts/pd-update-venue.sh
```

### プレフィックス変更自動追従 (`pd-update-venue.sh`)

DHCPv6-PD のプレフィックスは PPPoE 再接続や ISP 側メンテナンスで変わる可能性がある。VyOS の DHCPv6 クライアント (wide-dhcpv6 / dhcp6c) はスクリプトにプレフィックス情報を渡さないため、dhclient hook 方式は使えない。代わりに **task-scheduler (cron) で 1 分間隔監視** する。

**スクリプト**: [`scripts/pd-update-venue.sh`](../../scripts/pd-update-venue.sh)
**配置先**: `/config/scripts/pd-update-venue.sh` (r1)

動作フロー:

1. dum0 の IPv6 グローバルアドレスから現在の /64 プレフィックスを取得
2. `/tmp/pd_current_prefix` に保存した前回のプレフィックスと比較
3. **変更あり**: r1 の IPv6 ルートを wg0 経由に更新 → r3 の VyOS API で IPv6 設定を全更新
4. **変更なし**: wg0 ルートが消えていないか確認し、消えていれば再追加 (自己修復)

r3 への更新内容:

- `interfaces ethernet eth2 vif 30/40 address` — IPv6 アドレス
- `service router-advert` — RA プレフィックス、RDNSS
- `service dhcpv6-server` — DHCPv6 アドレスレンジ

**制約**:

- プレフィックス変更から r3 反映まで最大 1 分のラグがある (IPv4 は影響なし)
- SLAAC クライアントは新プレフィックスの RA 受信後に新アドレスを取得する (旧アドレスは preferred-lifetime 満了まで残る)
- `/tmp/pd_current_prefix` は再起動で消えるため、起動後の初回実行時は必ずフル更新が走る

### 会場側 (r3) の RA 配信

r3 が受け取った /64 を VLAN 30/40 で RA 広告する。r1 側では RA を配信しない。r3 の IPv6 設定は `pd-update-venue.sh` が自動投入するため手動設定は不要。

```
# r3 側 (pd-update-venue.sh が投入する設定の例)
set interfaces ethernet eth2 vif 30 address 2001:ce8:180:5a79::1/64
set interfaces ethernet eth2 vif 40 address 2001:ce8:180:5a79::2/64
set service router-advert interface eth2.30 prefix 2001:ce8:180:5a79::/64
set service router-advert interface eth2.40 prefix 2001:ce8:180:5a79::/64
```

## HTTPS API

```
set service https api keys id mykey key 'BwAI'
set service https api rest strict
set service https listen-address 192.168.10.1
```

管理 PC (eth0: 192.168.100.0/24) から VyOS 設定 API にアクセスするために使用。`scripts/r1-config.py` から curl で設定を投入する。

> ⚠️ **`listen-address` の明示は必須**: デフォルトでは `service https` は全インターフェース (pppoe0 WAN 含む) で 443 を listen する。`nat destination rule 30` で `pppoe0:443 → 192.168.10.4` の DNAT を設定しているため **本来の WAN 経由トラフィックは PREROUTING で先に DNAT されて wstunnel server に届く**ので機能面の実害はないが、以下 2 点の問題があるため LAN 側 IP に限定する。
>
> 1. **LAN 内から自宅グローバル IP でアクセスしたときに r1 の nginx (API フロント) が応答してしまう**: ヘアピン NAT は別ルールで ip 向けに指定しない限り効かず、r1 自身の pppoe0 IP 宛パケットは INPUT に落ちて nginx (403/404) が返る。LAN 内動作確認やヘアピン前提の運用で想定外の応答になる
> 2. **API の WAN 露出はセキュリティリスク**: `https://<WAN-IP>/retrieve` に API キーのブルートフォースが可能になってしまう

## SSH

```
set service ssh port 22
set service ssh disable-password-authentication
set service ssh hostkey-algorithm ssh-ed25519
```

WAN にも公開するため、ed25519 鍵認証のみに制限しパスワード認証を無効化する。listen-address を指定しないことで全インターフェースで受け付ける (WAN-LOCAL ファイアウォールで WAN 側も許可済み)。

### 登録済み公開鍵 (authorized_keys)

ユーザー `vyos` に登録されている SSH 公開鍵一覧:

| キー名 | 種別 | 公開鍵 |
|--------|------|--------|
| `admin-P14sGen4` | ssh-ed25519 | `AAAAC3NzaC1lZDI1NTE5AAAAIB+qVyw/Zek2Mw81dOqJKHQKsG9bnZuFsJdsRWakenyj` |
| `admin@DESKTOP-NKBDQ7N` | ssh-ed25519 | `AAAAC3NzaC1lZDI1NTE5AAAAICE+Sh+BGa5emrjg2WLm+KYxQZGUPcIoSSKVE8Fsrm16` |
| `yuuki@uyuki234` | ssh-ed25519 | `AAAAC3NzaC1lZDI1NTE5AAAAILpwyh8IbeX+/UG8hSxKJSZSYUG21hBvUIxQoyI0AJuk` |
| `uenohiroya@MacBook-Pro` | ssh-ed25519 | `AAAAC3NzaC1lZDI1NTE5AAAAILFoalIDw9/h9PPlB52T7j9jokmbT/F5iHQ/2O8frfYT` |
| `GDG_Kwansai_2026_1` | ssh-ed25519 | `AAAAC3NzaC1lZDI1NTE5AAAAIK7+w42OTq5owt5qJ5AnvC5zUiGKjus7wFyI9kt97KAR` |
| `GDG_Kwansai_2026_2` | ssh-ed25519 | `AAAAC3NzaC1lZDI1NTE5AAAAIDo0nQBmij/qT7E/Nuz9CNy41LZW6vzUl4vFSktH6R4d` |

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB+qVyw/Zek2Mw81dOqJKHQKsG9bnZuFsJdsRWakenyj admin-P14sGen4
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICE+Sh+BGa5emrjg2WLm+KYxQZGUPcIoSSKVE8Fsrm16 admin@DESKTOP-NKBDQ7N
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILpwyh8IbeX+/UG8hSxKJSZSYUG21hBvUIxQoyI0AJuk yuuki@uyuki234
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILFoalIDw9/h9PPlB52T7j9jokmbT/F5iHQ/2O8frfYT uenohiroya@MacBook-Pro
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK7+w42OTq5owt5qJ5AnvC5zUiGKjus7wFyI9kt97KAR GDG_Kwansai_2026_1
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDo0nQBmij/qT7E/Nuz9CNy41LZW6vzUl4vFSktH6R4d GDG_Kwansai_2026_2
```

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
set interfaces wireguard wg0 mtu 1400
set interfaces wireguard wg0 peer venue public-key <r3-public-key>
set interfaces wireguard wg0 peer venue allowed-ips 10.255.0.2/32
set interfaces wireguard wg0 peer venue allowed-ips 192.168.11.0/24
set interfaces wireguard wg0 peer venue allowed-ips 192.168.30.0/24
set interfaces wireguard wg0 peer venue allowed-ips 192.168.40.0/22

# WireGuard (GCP r2-gcp)
set interfaces wireguard wg1 address 10.255.1.1/30
set interfaces wireguard wg1 port 51821
set interfaces wireguard wg1 private-key <r1-private-key>
set interfaces wireguard wg1 mtu 1400
set interfaces wireguard wg1 peer r2-gcp public-key <r2-public-key>
set interfaces wireguard wg1 peer r2-gcp address 34.97.197.104
set interfaces wireguard wg1 peer r2-gcp port 51820
set interfaces wireguard wg1 peer r2-gcp allowed-ips 10.255.1.2/32
set interfaces wireguard wg1 peer r2-gcp allowed-ips 10.255.2.0/30
set interfaces wireguard wg1 peer r2-gcp allowed-ips 192.168.11.0/24
set interfaces wireguard wg1 peer r2-gcp allowed-ips 192.168.30.0/24
set interfaces wireguard wg1 peer r2-gcp allowed-ips 192.168.40.0/22
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

# WG トンネルアドレスもマスカレード (r3 ルーター自身の通信用)
set nat source rule 150 outbound-interface name pppoe0
set nat source rule 150 source address 10.255.0.0/24
set nat source rule 150 translation address masquerade
set nat source rule 150 description 'WG tunnel addresses masquerade'

# Destination NAT (ポートフォワーディング → メインPC 192.168.10.4)
# SSH → VyOS 自身 (WAN-LOCAL で許可), WireGuard → VyOS 自身 (WAN-LOCAL で許可)
set nat destination rule 30 description 'wstunnel-HTTPS'
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
# 会場サブネットは BGP で r3 (wg0) から学習 (旧 static route は廃止)
# 旧構成の残骸 (誤配送の原因) は投入しないこと:
#   set protocols static route 192.168.11.0/24
#   set protocols static route 192.168.30.0/24 next-hop 10.255.1.2
#   set protocols static route 192.168.40.0/22 next-hop 10.255.1.2

# BGP (AS65002)
set protocols bgp system-as 65002

# r3 (WireGuard 直接) — venue に default route を広告
set protocols bgp neighbor 10.255.0.2 remote-as 65001
set protocols bgp neighbor 10.255.0.2 description 'venue-r3'
set protocols bgp neighbor 10.255.0.2 address-family ipv4-unicast
set protocols bgp neighbor 10.255.0.2 address-family ipv4-unicast route-map import WG-IN
set protocols bgp neighbor 10.255.0.2 address-family ipv4-unicast default-originate

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
set service https listen-address 192.168.10.1
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

eth3 に RJ45 SFP+ モジュール経由で Proxmox (USB 2.5GbE) を直結し、会場上流 (blackbox) を再現する。
eth3 は会場当日の `10.64.56.0/22` を DHCP で配布し、r3 eth0 (`address dhcp`) が本番同等の条件で動作することを検証する。
構築完了後に削除すること。

### 設定内容

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

### 削除手順 (構築完了後)

```
delete interfaces ethernet eth3 address 10.64.56.1/22
delete interfaces ethernet eth3 description
delete service dhcp-server shared-network-name VENUE-TEST
delete service dhcp-server listen-interface eth3
delete service dns forwarding listen-address 10.64.56.1
delete service dns forwarding allow-from 10.64.56.0/22
delete nat source rule 140
```

## 注意事項

- PPPoE 認証情報はこのドキュメントに記載しているが、本番では secret 管理を検討すること
- `<r1-private-key>`, `<r3-public-key>` は WireGuard 鍵生成後に差し替え
- OPTAGE の DHCPv6-PD は /64 のみ。自宅 LAN は IPv4 only とし、/64 は会場に全量転送する
- VyOS のバージョンは 2026.03 (Circinus, rolling release) を使用
