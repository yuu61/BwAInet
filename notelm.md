# ゼロトラスト＆クラウド指向 ハイブリッドVPN 構成ガイド

本ドキュメントは、拠点A（メインGW）、拠点B（GCP上のVyOS）、拠点C（エッジ拠点）の3拠点をIPsec IKEv2でフルメッシュ接続し、IPv4/IPv6のデュアルスタックルーティングと高度なフェイルオーバーを実現するアーキテクチャの設計および実装書です。

1. ネットワーク・アーキテクチャの全体像
1.1 トンネルの基本構造 (IKEv2 Dual-Stack)方式: IPsec IKEv2 トンネルモード（IX側：tunnel mode ipsec-ikev2 / VyOS側：VTI）特徴: 1つのIPsecトンネル内でIPv4とIPv6を同時に暗号化・カプセル化し、ネイティブなマルチキャスト（OSPF/DHCPv6）を透過します。
1.2 IPv6 アーキテクチャ (Dual-Prefix RA & PBR Multi-Next-Hop)プレフィックス委任 (PD): 拠点Aと拠点Bは、それぞれのISPから取得した /64 を拠点Cへ再委任（DHCPv6-PD 再配布機能を使用）。
デュアルプレフィックスRA: 拠点Cは、LAN内にA・B双方のプレフィックスをルータ広告(RA)し、PCはSLAACで2つのグローバルIPを生成します。
PBRと迂回ルーティング:拠点Cで送信元アドレスに基づくポリシーベースルーティング(PBR)を実施。
Src A は拠点Aへ、Src B は拠点Bへ向かわせます。
トンネル障害時は、PBRの「第2ネクストホップ」と「フルメッシュOSPFv3」の連携により、健全な拠点を経由して本来のISPからインターネットへ抜けます。
1.3 IPv4 アーキテクチャ (Longest Match & Metric Failover)動的ルーティング: OSPFv2のみで制御（PBRは不使用）。
Googleトラフィック分離: 拠点B（VyOS）からGoogleのプレフィックス（goog.jsonの97経路など）をOSPFに注入。
ロンゲストマッチの法則により、Google宛通信は自動的にGCP経由となります。
デフォルトゲートウェイ:拠点Aはメトリック 10 で 0.0.0.0/0 を広報（通常時のメインGW）。
拠点Bはメトリック 100 で 0.0.0.0/0 を広報（障害時のバックアップGW）。
1.4 GCP制約の突破 (VyOS NAT66)GCPの仕様上、VMには /96 までしかIPv6アドレスが付与されません。
拠点B（VyOS）にて NAT66 を実行し、拠点CのPCが持つ /64 SLAACアドレスの上位96bitをGCPのプレフィックスに上書きします。
PCが生成したインターフェースIDの下位32bitは保持されたままインターネットへ出ます。

2. 拠点C (エッジルータ - UNIVERGE IX) の実装イメージ拠点Cは、プレフィックスの受け取り、PBRによるIPv6の振り分け、およびトンネルの維持を担当します。

```console
! --- IPv6 送信元 PBR用 ACL ---
ipv6 access-list acl-src-a permit ip 2001:db8:aaaa::/64 any
ipv6 access-list acl-src-b permit ip 2001:db8:bbbb::/64 any

! --- IPv6 柔軟なPBR定義 (障害時自動フォールバック) ---
route-map v6-pbr permit 10
  match ipv6 address acl-src-a
  set interface Tunnel1.0 Tunnel2.0
route-map v6-pbr permit 20
  match ipv6 address acl-src-b
  set interface Tunnel2.0 Tunnel1.0

! --- IPv4/IPv6 動的ルーティング ---
router ospf 1
  router-id 3.3.3.3
ipv6 router ospf 1
  router-id 3.3.3.3

! --- 拠点C LAN側インターフェース ---
interface GigaEthernet0.0
  ip address 192.168.3.254/24
  ipv6 enable
  ipv6 nd ra enable
  ipv6 policy route-map v6-pbr

! --- トンネルインターフェース (対 拠点A) ---
interface Tunnel1.0
  description VPN-to-A
  tunnel mode ipsec-ikev2
  ! IPv4
  ip unnumbered GigaEthernet0.0
  ip tcp adjust-mss auto
  ip ospf 1 area 0.0.0.0
  ! IPv6
  ipv6 enable
  ipv6 ospf 1 area 0.0.0.0
  ipv6 dhcp client request ia-pd
  ipv6 dhcp client configuration id 10
  ikev2 dpd interval 10 retries 3
  ! IPsecピア設定等は省略

! --- トンネルインターフェース (対 拠点B) ---
interface Tunnel2.0
  description VPN-to-B
  tunnel mode ipsec-ikev2
  ! IPv4
  ip unnumbered GigaEthernet0.0
  ip tcp adjust-mss auto
  ip ospf 1 area 0.0.0.0
  ! IPv6
  ipv6 enable
  ipv6 ospf 1 area 0.0.0.0
  ipv6 dhcp client request ia-pd
  ipv6 dhcp client configuration id 20
  ikev2 dpd interval 10 retries 3

! --- 取得したPDのLAN側への割り当て ---
ipv6 dhcp client configuration 10
  ia-pd subscriber GigaEthernet0.0 0:0:0:0::1/64
ipv6 dhcp client configuration 20
  ia-pd subscriber GigaEthernet0.0 0:0:0:0::2/64
```

3. 拠点A (メインGW - UNIVERGE IX) の実装イメージ拠点Aは、ISPからのIPv6プレフィックスを再委任し、IPv4の主系インターネット出口として動作します。
また、拠点Bとのフルメッシュトンネルを構築します。

```console
! --- IPv6 PD再配布プール ---
! ISPから受け取った /64 をNLA長 0 でそのままプール化
ia-pd redistribute pool POOL-A nla-length 0

! --- IPv4/IPv6 動的ルーティング ---
router ospf 1
  router-id 1.1.1.1
  ! IPv4 主系デフォルトルートの広報
  default-information originate metric 10
ipv6 router ospf 1
  router-id 1.1.1.1
  ! PDで委任した宛先(スタティック)をOSPFv3に再配布(拠点Bの迂回用)
  redistribute static subnets

! --- 拠点A WAN(インターネット出口) ---
interface GigaEthernet0.1
  ip address dhcp
  ip napt enable
  ip napt translation net 192.168.0.0/16 vlan GigaEthernet0.1
  ipv6 enable
  ! ISPからPDを受け取る
  ipv6 dhcp client request ia-pd
  ipv6 dhcp client ia-pd pool POOL-A

! --- トンネルインターフェース (対 拠点C) ---
interface Tunnel1.0
  description VPN-to-C
  tunnel mode ipsec-ikev2
  ip unnumbered GigaEthernet0.0
  ip ospf 1 area 0.0.0.0
  ipv6 enable
  ipv6 ospf 1 area 0.0.0.0
  ! プレフィックスを委任するDHCPv6サーバとして動作
  ipv6 dhcp server ia-pd pool POOL-A
  ikev2 dpd interval 10 retries 3

! --- トンネルインターフェース (対 拠点B) バックアップ迂回用 ---
interface Tunnel2.0
  description VPN-to-B
  tunnel mode ipsec-ikev2
  ip unnumbered GigaEthernet0.0
  ip ospf 1 area 0.0.0.0
  ipv6 enable
  ipv6 ospf 1 area 0.0.0.0
  ikev2 dpd interval 10 retries 3
  ! ※ここではPD委任は行わず、OSPFv3による経路交換のみを実施
```

4. 拠点B (GCP / VyOS) の実装イメージ拠点Bは、Google宛IPv4通信の直接ブレイクアウト、IPv4待機系デフォルトGW、拠点Aへの迂回ルート、そしてIPv6のNAT66を担当します。

```console
# --- 物理インターフェース (eth0: GCP WAN) ---

set interfaces ethernet eth0 address dhcp
set interfaces ethernet eth0 address dhcpv6

# --- VPN仮想トンネル (VTI) インターフェースの設定 ---

# 対 拠点C 用トンネル (PD委任と通常トラフィック)

set interfaces vti vti0 description 'VPN-to-C'
set interfaces vti vti0 ip ospf network 'point-to-point'
set interfaces vti vti0 ipv6 ospfv3 network 'point-to-point'

# 対 拠点A 用トンネル (A-B間のOSPF迂回・バックアップ用)

set interfaces vti vti1 description 'VPN-to-A'
set interfaces vti vti1 ip ospf network 'point-to-point'
set interfaces vti vti1 ipv6 ospfv3 network 'point-to-point'

# ※上記 vti0, vti1 は別途IPsec (IKEv2) の設定プロファイルにバインドします

# --- OSPFv2 (IPv4 ルーティング) ---

set protocols ospf area 0 network '192.168.0.0/16'

# Googleのプレフィックス(スタティック等で定義済み)をOSPFへ注入

set protocols ospf redistribute static metric-type 2

# バックアップ用デフォルトルートをメトリック100で注入

set protocols ospf default-information originate metric 100

# --- OSPFv3 (IPv6 ルーティング) ---

set protocols ospfv3 area 0.0.0.0 interface vti0
set protocols ospfv3 area 0.0.0.0 interface vti1

# PD委任経路を再配布

set protocols ospfv3 redistribute static

# --- IPv4 NAPT (インターネット向け) ---

set nat source rule 100 outbound-interface 'eth0'
set nat source rule 100 source address '192.168.0.0/16'
set nat source rule 100 translation address masquerade

# --- IPv6 NAT66 (拠点Cの/64 を GCPの/96 へマッピング) ---

set nat66 source rule 10 outbound-interface 'eth0'
set nat66 source rule 10 source prefix '2001:db8:bbbb::/64'
set nat66 source rule 10 translation address '2600:1900:abcd:ef01:2345:6789::/96'

# --- IPv6 DHCPv6-PD Server (拠点Cへ /64 を委任) ---

# ※VyOSのdhcp-server機能を用いて設定 (詳細構文はバージョン依存)
```
