# IX3315 自宅設置 最終設計書（アーキテクチャ α 純 IX / D2-ii + D1=a）

> 対象: BwAI in Kwansai 2026 会場ネットワーク。自宅 r1 を **NEC UNIVERGE IX3315** に置換し、現行 r1-VyOS を撤去する純 IX 構成。
> 出典は `docs/configs/{r1-home,r2-gcp,r3-venue}.conf`・`scripts/`・`docs/investigation/ix3315-migration.md` を実読みした実値（`file:line` 付き）。IX 内部構文はリポジトリに前例が無いものが多く、確証の取れないトークンは `<要確認>` を明示し推測の断定をしない。
> **本設計書は 6 プレーンの敵対的検証 (consistent=partial) を反映し、矛盾を解消した最終形である。** 残 issue は §5 に最上位で列挙する。

---

## 0. サマリ

### 0.1 構成図

```
                家族 LAN (192.168.10.0/24, v4 only)
                          │
                  ┌───────┴────────┐
                  │   IX3315 (r1)  │  AS65002 / router-id 10.255.255.1
                  │  PPPoE(OPTAGE) │  ← v4 NAPT全数記録 = D1=a forensic点
                  │  v4 eBGP4      │
                  │  v6 OSPFv3     │
                  └───┬────────┬───┘
        IPsec IKEv2   │        │   IPsec IKEv2
        route-based   │        │   route-based VTI
        VTI (Tunnel)  │        │   (Tunnel)
                      │        │
        ┌─────────────┘        └──────────────┐
        │                                      │
 ┌──────┴───────┐                       ┌──────┴───────┐
 │  r3-venue    │   WireGuard 据え置き   │  r2-gcp      │
 │  VyOS(FRR)   │◄──── (wg: r3 wg1 ─────►│  VyOS(FRR)   │  AS64512
 │  AS65001     │       ↔ r2 wg2 )       │  NAT66       │  router-id .2
 │  router-id .3│   fd00:255:2::/126     │  GCP /64 元  │
 └──────────────┘                       └──────────────┘
   会場 VLAN 11/30/40                      GCP 上流 (v6 default 元)
```

- **eBGP/OSPFv3 フルメッシュ**: IX↔r3, IX↔r2, r2↔r3 の 3 脚。transport は IX 脚 2 本が IPsec VTI、r2↔r3 が WireGuard 据え置き。
- **v4 = eBGP4**（IX で維持）、**v6 = OSPFv3 area0**（IX が v6 BGP 不可のため強制移行）。

### 0.2 何が IX / 何が VyOS 据え置きか

| 機能 | 担当 | 備考 |
|---|---|---|
| 家族 LAN (PPPoE/DHCPv4/proxy-dns/NTP/v4 NAPT/v4 FW) | **IX3315** | 旧 r1-VyOS から全移植 |
| 会場 v4 source NAPT (192.168.11/30/40) | **IX3315** | ★必須。会場非 goog v4 は r3→VTI→IX→OPTAGE で egress (§1.7, §5-I4) |
| v4 NAPT 全数記録 (D1=a forensic) | **IX3315** `ip napt access-log` | 旧 r1 conntrack-logger を置換 |
| IX↔r3 / IX↔r2 transport | **IX3315** IPsec IKEv2 VTI | 旧 wg0/wg1 を置換、**link-net 流用 (REUSE)** |
| v4 eBGP4 / v6 OSPFv3 (IX 脚) | **IX3315** | BFD 非対応→holdtime+network-monitor |
| OPTAGE /64 の r3 への再委任 | **IX3315** `ia-pd redistribute` | 旧 pd-update-venue.sh push を置換 |
| **r2↔r3 WireGuard (制御面)** | **VyOS 据え置き** | wg 鍵・link-net 不変。ただし**外殻パスは wg0 から張り替え** (§3, §5-I2) |
| NAT66 (GCP /64→/96) | **VyOS r2 据え置き** | IX は NAT66 非対応 |
| DHCPv6-PD client / dual-prefix RA | **VyOS r3** | r3 を PD client 化 (D2-ii) |
| v6 src-PBR table 100/101 / OPTAGE 高速 deprecate | **VyOS r3** | next-hop は link-net 流用で不変 |
| 会場 v6 NAT66・GCP v6 default originate | **VyOS r2** | OSPFv3 `default-information originate` へ移行 |

### 0.3 v6 failover の非対称（最重要・Section 2 と直結）

- **OPTAGE-src（C-B-A 相当）= host-driven のみ**。r3↔IX 断で PD binding 喪失 → r3 が OPTAGE RA を Lifetime0 deprecate → クライアントが GCP prefix へ移行。ネットワーク迂回は存在しない（OPTAGE-src を GCP 脚から出すと un-NAT66 破綻）。
- **GCP-src（C-A-B = r3→IX→r2 中継）= 生存**。ただし **この生存は「r3 が r2 に home(IX) 非依存で到達できる」ことが前提**。本設計は **r3→r2 外殻を eth1 直 (DIRECT) に張り替える**ことでこれを保証する（§3, §5-I2）。r3→r2 を IX VTI 経由にすると IX 障害で GCP-src も道連れになり非対称が崩れる。

---

## 1. プレーン別設計

> **キーストン決定（全プレーン共通・採用 = REUSE）**: IX↔r3 / IX↔r2 の VTI transfer net は**現行 WG link-net をそのまま流用**する。
>
> - IX↔r3: IX `10.255.0.1/30` + `fd00:255:0::1/126` ↔ r3 `10.255.0.2/30` + `fd00:255:0::2/126`（旧 wg0）
> - IX↔r2: IX `10.255.1.1/30` + `fd00:255:1::1/126` ↔ r2 `10.255.1.2/30` + `fd00:255:1::2/126`（旧 wg1）
> - **`fd00:255::1`（r3-venue.conf:175,177）は `fd00:255:0::1` とビット同一**＝旧 r1 wg0 inner ＝ REUSE 時の IX VTI inner。よって **r3 の table 100/101 next-hop は IP 変更不要、解決 IF が wg0→VTI に変わるのみ**。
> - 帰結: v4 BGP neighbor は **delete+re-add せず in-place 編集**（BFD 削除・v6 AF 削除・VTI bind のみ）。neighbor identity / route-map / timers / `10.255.*` forensic src フィルタ / https allow-client が全て有効のまま。
> - **却下した代替**: 新採番（renumber）。neighbor 全削除・再追加の churn が発生し、forensic src フィルタや https allow-client の照合も崩れるため採らない。

### 1.1 transport — IPsec IKEv2 route-based VTI（IX↔r3 / IX↔r2）

proposal（両区間共通、firmware は version-gated 機能利用可の前提）:

- 暗号 **AES-GCM-256（`aes-gcm-256-16`、ICV 16）**、PRF **SHA2-256**、DH **MODP-3072(group15)**（MODP-2048(group14) も可。ECP 非対応）
- DPD 最小 **10s**、IKEv2。MTU は IX `ip tcp adjust-mss auto` / `ipv6 tcp adjust-mss auto`（ESP overhead 自動）。UDP/ICMP は IX `ip forced-fragment`。VyOS 側 VTI は MTU 1400 + MSS clamp。

**初期化方向（initiator/responder）と NAT-T**:

- **IX↔r3**: r3 は venue eth1=`dhcp`（NAT 内）＝ **r3 initiator / IX responder**。IKE ID は IP 固定不可 → FQDN/keyid 照合。NAT-T(UDP4500) 必須。
- **IX↔r2**: r2 外部 `34.97.197.104` は GCE **1:1 NAT**（r2 eth0 内部 = `10.174.0.7`、`dhcp`、gcp-integration 参照／r2-gcp.conf:62 local-route source `10.174.0.7`）。よって **r2 も NAT 越え（NAT-T UDP4500 必須・IKE ID は IP 不可で FQDN/keyid）**。「両側固定 IP で IX から initiate」という単純化は誤りなので採らない。IX 側は `tunnel destination 34.97.197.104`、r2 VyOS は `connection-type respond` を基本に、向きは bring-up で統一。

#### IX 側（NEC IX3315）— 骨子

> ⚠️ NEC IX の IKEv2/VTI CLI は機種・firmware で記述が分かれる。意味論を確定し values を埋めた骨子。キーワード綴り・順序は最新 IX3315 リファレンスで bring-up 確認。

```
! ===== IKEv2 共通 proposal（AES-GCM-256 / SHA2-256 / MODP-3072）=====
ikev2 proposal IKE2-GCM-MODP15
  encryption aes-gcm-256-16          ! <要確認: NEC の GCM トークン綴り>
  prf hmac-sha2-256                  ! <要確認: prf キーワード対応>
  group 15                           ! MODP-3072（14=MODP-2048 も可）

! ===== authentication（PSK 前提）=====
ikev2 authentication AUTH-r3 pre-shared-key <要確認: PSK_IX_r3>
ikev2 authentication AUTH-r2 pre-shared-key <要確認: PSK_IX_r2>

! ===== policy / peer（r3 脚: r3 initiator, IX responder, NAT-T）=====
ikev2 policy POL-r3
  proposal IKE2-GCM-MODP15
  authentication AUTH-r3
  remote-id <要確認: r3 IKE ID (fqdn/keyid)>   ! r3 は NAT 内、IP 固定不可
  local-id  <要確認: IX IKE ID>
  dpd interval 10
  lifetime  <要確認: IKE/CHILD SA lifetime>

! ===== policy / peer（r2 脚: 1:1 NAT 越えの NAT-T ピア）=====
ikev2 policy POL-r2
  proposal IKE2-GCM-MODP15
  authentication AUTH-r2
  remote-address 34.97.197.104       ! GCE 1:1 NAT 外側。IKE ID は FQDN/keyid 照合
  remote-id <要確認: r2 IKE ID (fqdn/keyid)>
  dpd interval 10
  lifetime  <要確認>

! ===== Tunnel（route-based VTI）r3 脚（REUSE: 旧 wg0 link-net）=====
interface Tunnel0.0
  description "VTI to r3-venue (replaces wg0)"
  tunnel mode ipsec ikev2            ! <要確認: route-based IPsec tunnel 宣言構文>
  tunnel protection ikev2 policy POL-r3   ! <要確認: policy 紐付け>
  tunnel source <IX-WAN-PPPoE-IF>    ! <要確認: PPPoE 終端 IF 名>
  ! r3 は NAT 内のため destination 固定せず responder。<要確認: destination 省略可否>
  ip address 10.255.0.1/30
  ipv6 address fd00:255:0::1/126
  ip tcp adjust-mss auto
  ipv6 tcp adjust-mss auto
  ip forced-fragment
  no shutdown

! ===== Tunnel（route-based VTI）r2 脚（REUSE: 旧 wg1 link-net）=====
interface Tunnel1.0
  description "VTI to r2-gcp (replaces wg1)"
  tunnel mode ipsec ikev2
  tunnel protection ikev2 policy POL-r2
  tunnel source <IX-WAN-PPPoE-IF>
  tunnel destination 34.97.197.104   ! r2 外側 (1:1 NAT)。NAT-T 経由
  ip address 10.255.1.1/30
  ipv6 address fd00:255:1::1/126
  ip tcp adjust-mss auto
  ipv6 tcp adjust-mss auto
  ip forced-fragment
  no shutdown

! ===== escape route（★必須・ESP 外殻ループ防止）=====
! r2 は GOOG で 34.64.0.0/10 を BGP 広告 (GOOG rule690, 34.97.197.104 を内包) し IX も受信する。
! /32 escape が無いと IX→r2 の ESP 外殻が Tunnel1 にループする。
! 旧 r1-home.conf:235 'route 34.97.197.104/32 interface pppoe0' の IX 等価。
ip route 34.97.197.104/32 <IX-WAN-PPPoE-IF>   ! <要確認: PPPoE IF 名 / 上流GW 指定形式>
```

#### VyOS 側（r3 / r2、strongSwan）— IX と proposal 完全一致

> VyOS 2026.03(Circinus) の `vpn ipsec` / `interfaces vti` / `prf` 構文は rolling で変動余地あり、IX 側同様 bring-up 照合対象（`<要確認: VyOS 2026.03 Circinus 構文>`）。

```
# ===== IKE/ESP group（r2/r3 共通）=====
set vpn ipsec ike-group IKE-GCM key-exchange 'ikev2'
set vpn ipsec ike-group IKE-GCM proposal 1 encryption 'aes256gcm128'   # AES-GCM-256/ICV128 = aes-gcm-256-16 相当
set vpn ipsec ike-group IKE-GCM proposal 1 prf 'prfsha256'             # <要確認: Circinus prf キーワード>
set vpn ipsec ike-group IKE-GCM proposal 1 dh-group '15'              # MODP-3072
set vpn ipsec ike-group IKE-GCM dead-peer-detection action 'restart'
set vpn ipsec ike-group IKE-GCM dead-peer-detection interval '10'
set vpn ipsec ike-group IKE-GCM dead-peer-detection timeout '30'
set vpn ipsec esp-group ESP-GCM proposal 1 encryption 'aes256gcm128'
set vpn ipsec esp-group ESP-GCM proposal 1 dh-group '15'              # PFS。<要確認: PFS 要否を IX と一致>
set vpn ipsec esp-group ESP-GCM mode 'tunnel'
```

r3 側（旧 wg0 → vti10、link-net 流用）:

```
set vpn ipsec interface 'eth1'
set vpn ipsec site-to-site peer IX-r1 authentication mode 'pre-shared-secret'
set vpn ipsec site-to-site peer IX-r1 authentication pre-shared-secret '<要確認: PSK_IX_r3>'
set vpn ipsec site-to-site peer IX-r1 authentication local-id '<要確認: r3 IKE ID>'
set vpn ipsec site-to-site peer IX-r1 authentication remote-id '<要確認: IX IKE ID>'
set vpn ipsec site-to-site peer IX-r1 ike-group 'IKE-GCM'
set vpn ipsec site-to-site peer IX-r1 default-esp-group 'ESP-GCM'
set vpn ipsec site-to-site peer IX-r1 connection-type 'initiate'      # r3 は NAT 内
set vpn ipsec site-to-site peer IX-r1 remote-address '<要確認: IX 公開 outer IP/DDNS>'
set vpn ipsec site-to-site peer IX-r1 vti bind 'vti10'
set vpn ipsec site-to-site peer IX-r1 vti esp-group 'ESP-GCM'
set interfaces vti vti10 address '10.255.0.2/30'                       # 旧 wg0 流用
set interfaces vti vti10 address 'fd00:255:0::2/126'                   # 旧 wg0 流用
set interfaces vti vti10 mtu '1400'
set interfaces vti vti10 ip adjust-mss 'clamp-mss-to-pmtu'
set interfaces vti vti10 ipv6 adjust-mss 'clamp-mss-to-pmtu'
set interfaces vti vti10 description 'IPsec VTI to IX(r1) - replaces wg0'
```

r2 側（旧 wg1 → vti11、link-net 流用。wg2/r3 は触らない）:

```
set vpn ipsec interface 'eth0'
set vpn ipsec site-to-site peer IX-r1 authentication mode 'pre-shared-secret'
set vpn ipsec site-to-site peer IX-r1 authentication pre-shared-secret '<要確認: PSK_IX_r2>'
set vpn ipsec site-to-site peer IX-r1 authentication local-id '<要確認: r2 IKE ID>'   # 1:1 NAT 内、IP 不可
set vpn ipsec site-to-site peer IX-r1 authentication remote-id '<要確認: IX IKE ID>'
set vpn ipsec site-to-site peer IX-r1 ike-group 'IKE-GCM'
set vpn ipsec site-to-site peer IX-r1 default-esp-group 'ESP-GCM'
set vpn ipsec site-to-site peer IX-r1 connection-type 'respond'        # IX→r2 initiate に対し respond
set vpn ipsec site-to-site peer IX-r1 remote-address '<要確認: IX 公開 outer IP/DDNS>'
set vpn ipsec site-to-site peer IX-r1 vti bind 'vti11'
set vpn ipsec site-to-site peer IX-r1 vti esp-group 'ESP-GCM'
set interfaces vti vti11 address '10.255.1.2/30'                       # 旧 wg1 流用
set interfaces vti vti11 address 'fd00:255:1::2/126'                   # 旧 wg1 流用
set interfaces vti vti11 mtu '1400'
set interfaces vti vti11 ip adjust-mss 'clamp-mss-to-pmtu'
set interfaces vti vti11 ipv6 adjust-mss 'clamp-mss-to-pmtu'
set interfaces vti vti11 description 'IPsec VTI to IX(r1) - replaces wg1'
# r2↔r3 WireGuard (wg2) は据え置き＝本セクション対象外、制御面は無変更
```

**触らない明記（制御面）**: r2↔r3 WireGuard（r2 `wg2` `10.255.2.2/30`/`fd00:255:2::2/126` port51821 ↔ r3 `wg1` `10.255.2.1/30`/`fd00:255:2::1/126` port51822、鍵 `pjQ5…`/`Mrqb…`）は VyOS↔VyOS で**制御面は据え置き**。**ただし外殻パスは §3・§5-I2 で wg0 から張り替える**。

### 1.2 v4 — eBGP4（IX で維持）

設計サマリ（現行マップを全量温存、transport を WG→VTI に載せ替え）:

| 項目 | 現行(VyOS r1) | IX 載せ替え | 出典 |
|---|---|---|---|
| system-as | 65002 | 維持 65002 | r1-home.conf:234 |
| router-id | 10.255.255.1 (dum0 /32) | Loopback0=10.255.255.1/32, router-id 明示 | r1-home.conf:233,68 |
| 広告 network(v4) | 10.255.255.1/32, 192.168.10.0/24 | 維持 | r1-home.conf:207-208 |
| peer: r3 | 10.255.0.2 / AS65001 / via wg0 | **同 10.255.0.2** / via VTI(Tunnel0) | r1-home.conf:209-220 |
| peer: r2 | 10.255.1.2 / AS64512 / via wg1 | **同 10.255.1.2** / via VTI(Tunnel1) | r1-home.conf:221-232 |
| default-originate | r3・r2 両 neighbor (v4) | 維持（両 neighbor） | r1-home.conf:209,221 |
| import route-map | r3=WG-IN(LP250) / r2=GCP-IN | 名称・意味維持（★WG-IN は misnomer、後述） | r1-home.conf:210,222 |
| BFD | profile FAST + peer BFD | **全廃**（IX 非対応）。holdtime 9 + network-monitor 代替 | r1-home.conf:196-206,214,226 |
| timers | connect15 / holdtime9 / keepalive3 | 維持 | r1-home.conf:218-220,230-232 |

> ★ **`WG-IN` は misnomer（既知・温存）**: transport が IPsec VTI になり r1 脚に WireGuard は無いが、route-map 名 `WG-IN` を改名すると r3 側 (r3-venue.conf:140,142) も触る必要があり risk が増すため、**名称は安定優先で温存**。WireGuard が r1 脚 transport だと誤読しないこと。

#### IX 側 eBGP4 — 骨子

> IX BGP CLI 綴り（`router bgp` 階層・`neighbor route-map in`・`network`・`default-originate`・`graceful-restart disable` 相当・`timers`）は最新 IX3315 リファレンスで確認 = `<要確認: IX BGP CLI 綴り>`。peer アドレスは REUSE で現行と不変。

```
interface Loopback0.0
  ip address 10.255.255.1/32                          ! r1-home.conf:233,68

router bgp 65002                                      ! r1-home.conf:234
  bgp router-id 10.255.255.1                           ! r1-home.conf:233
  network 10.255.255.1/32                              ! r1-home.conf:207
  network 192.168.10.0/24                              ! r1-home.conf:208

  ! ===== neighbor: r3-venue (AS65001) over VTI(Tunnel0), addr REUSE =====
  neighbor 10.255.0.2 remote-as 65001                  ! r1-home.conf:217 (不変)
    description venue-r3                                ! r1-home.conf:215
    default-originate                                  ! r1-home.conf:209
    route-map WG-IN in                                 ! r1-home.conf:210 (LP250)
    timers 3 9                                         ! r1-home.conf:219-220
    timers connect 15                                  ! r1-home.conf:218
    ! graceful-restart disable 相当                     ! r1-home.conf:216 <要確認: IX GR 綴り>
    ! BFD なし（IX 非対応）← r1-home.conf:214 を意図的に落とす

  ! ===== neighbor: r2-gcp (AS64512) over VTI(Tunnel1), addr REUSE =====
  neighbor 10.255.1.2 remote-as 64512                  ! r1-home.conf:229 (不変)
    description r2-gcp                                  ! r1-home.conf:227
    default-originate                                  ! r1-home.conf:221
    route-map GCP-IN in                                ! r1-home.conf:222
    timers 3 9                                         ! r1-home.conf:231-232
    timers connect 15                                  ! r1-home.conf:230
    ! BFD なし ← r1-home.conf:226 を落とす

! ===== route-map / prefix-list（v4 のみ）=====
route-map WG-IN permit 10
  set local-preference 250                             ! r1-home.conf:190-191

ip prefix-list DEFAULT-ONLY permit 0.0.0.0/0           ! r1-home.conf:178-179
route-map GCP-IN permit 10
  match ip address prefix-list DEFAULT-ONLY            ! r1-home.conf:182-184
  set local-preference 50
route-map GCP-IN permit 20
  set local-preference 250                             ! r1-home.conf:188-189
```

> 注: 現行 GCP-IN rule15（v6 default-only LP50, r1-home.conf:185-187）と `nexthop-local unchanged`（v6, r1-home.conf:212,224）は v6 用＝**OSPFv3 へ移管、v4 route-map から除外**。

#### 対向 VyOS の v4 変更（REUSE = in-place 編集、delete+re-add しない）

**r3-venue（AS65001）**: 現行 r1 脚 neighbor `10.255.0.1`（r3-venue.conf:140-149）は **アドレス不変**。BFD と v6 AF を外すだけ。

```
# neighbor 10.255.0.1 は維持（アドレス・AS・route-map・timers 不変）
delete protocols bgp neighbor 10.255.0.1 bfd                          # r3-venue.conf:143 (IX 非対応)
delete protocols bgp neighbor 10.255.0.1 address-family ipv6-unicast  # r3-venue.conf:141-142 → OSPFv3 へ
delete protocols bfd peer 10.255.0.1                                  # r3-venue.conf:124-127【CONFIRMED】
# r2 脚 neighbor 10.255.2.2 (GCP-IN, WG 据え置き) と BFD peer 10.255.2.2 は不変
# v4 広告 network (10.255.255.3/32, 192.168.11/30/40, :135-138) 不変
# distance global external 20 (:160) は v4 BGP AD、不変
```

**r2-gcp（AS64512）**: 現行 r1 脚 neighbor `10.255.1.1`（r2-gcp.conf:284-293）も **アドレス不変**。

```
# neighbor 10.255.1.1 は維持
delete protocols bgp neighbor 10.255.1.1 bfd                          # r2-gcp.conf:287 (IX 非対応)
delete protocols bgp neighbor 10.255.1.1 address-family ipv6-unicast  # r2-gcp.conf:285-286 → OSPFv3 へ
delete protocols bfd peer 10.255.1.1                                  # r2-gcp.conf:271-274【CONFIRMED: source 10.255.1.2 = r1 脚】
# default-originate は r2→r1 には無い (r2-gcp.conf:284)。r2→r3 (10.255.2.1, :294) は WG 据え置き不変
# GOOG 広告 (network 10.255.255.2/32 + redistribute static GOOG-OUT, :282-283, :308-404 = 96 経路) 全量不変
```

> **§3 narrative 訂正**: GCP default の LP50 劣後は **r1 では発生しない**（r2 は r1 へ default-originate しない＝r1 の GCP-IN rule10 match-default は dead、rule20 LP250 のみ有効＝goog/v4 prefix に適用）。LP50 劣後は **r3 で発生**（r2-gcp.conf:294 default-originate→r3 + r3-venue.conf:150 GCP-IN）。route-map 自体は正しく温存される。

#### BFD 無しの v4 収束

IX は BFD 非対応のため全廃。代替:

1. **BGP holdtime 9 / keepalive 3 を維持**（r1-home.conf:219-220）→ ピア無応答は最大 holdtime 9s 検知。BFD 喪失で v4 高速 failover は 0.6–0.9s → **holdtime 9s 律速に劣化**する点を明記。
2. **network-monitor 併用**（path-aware 障害用）: VTI 越し対向（r3=10.255.255.3 / r2=10.255.255.2、または VTI /30 対向）を ICMP/probe 監視し down でルート/ポリシ無効化。IX 構文 = `<要確認: watch-group + action shutdown-policy + event source>`、interval/閾値も `<要確認>`。
3. BFD は v4/v6 共有だったため、IX 脚 BFD 撤去は **v6(OSPFv3)収束にも波及**。v6 は OSPFv3 dead-interval 1s で代替（§1.3）。

**out-of-plane（v4 は触らない・矛盾なし）**: GCP-src OPTAGE 漏れ / connected-shadow / OSPFv3 interop は v4 プレーンに無関係（src-PBR/PD/v6 を含まない）。firmware/BFD 非対応は与件として尊重。

### 1.3 v6 — OSPFv3 area0（IX + r2 + r3）

> ⚠️ **このプレーンは敵対的検証で verdict=null（未検証）。NEC IX↔FRR interop が最大の bring-up リスク**。下記は意味論を確定した骨子であり、隣接成立・LSDB・default 注入は §4 PoC で実機確認する。

責務分離: OSPFv3 は「どの脚も v6 で到達可能」の土台。**src 別の出口固定（OPTAGE-src→IX / GCP-src→r2）は src-PBR（table 100/101）が担い、OSPFv3 cost 単独では実現しない**（OSPFv3 は宛先ごと 1 ベスト経路）。

router-id は BGP と共用: IX `10.255.255.1` / r2 `10.255.255.2` / r3 `10.255.255.3`。

トポロジ（transport 混在）:

| 隣接 | transport | IX IF | VyOS IF | link-net (REUSE) |
|---|---|---|---|---|
| IX↔r3 | IPsec VTI | Tunnel0 | r3 vti10 | `fd00:255:0::/126` |
| IX↔r2 | IPsec VTI | Tunnel1 | r2 vti11 | `fd00:255:1::/126` |
| r2↔r3 | WireGuard 据え置き | — | r2 wg2 / r3 wg1 | `fd00:255:2::/126` |

#### r3-venue（VyOS/FRR）

```
# --- 削除: v6 BGP（src-PBR 維持で注入してなかったが neighbor v6 AF を撤去）---
delete protocols bgp address-family ipv6-unicast redistribute connected   # r3-venue.conf:139 ★§5-I 参照
delete protocols bgp neighbor 10.255.0.1 address-family ipv6-unicast       # :141-142 (IX 脚)
delete protocols bgp neighbor 10.255.2.2 address-family ipv6-unicast       # :151-152 (r2 脚)

# --- OSPFv3 area0 ---
set protocols ospfv3 parameters router-id '10.255.255.3'
set protocols ospfv3 interface vti10 area '0.0.0.0'
set protocols ospfv3 interface vti10 network 'point-to-point'
set protocols ospfv3 interface vti10 dead-interval '1'
set protocols ospfv3 interface vti10 hello-interval '1'        # FRR hello 最小 1s
set protocols ospfv3 interface wg1  area '0.0.0.0'             # r2 脚（WG 据え置き）
set protocols ospfv3 interface wg1  network 'point-to-point'
set protocols ospfv3 interface wg1  dead-interval '1'
set protocols ospfv3 interface wg1  hello-interval '1'

# --- 会場 v6 prefix を OSPFv3 へ（redistribute connected を route-map で /64 限定）---
set protocols ospfv3 redistribute connected route-map 'OSPF6-CONN'
set policy route-map OSPF6-CONN rule 10 action 'permit'
set policy route-map OSPF6-CONN rule 10 match ipv6 address prefix-list 'VENUE-V6'
set policy route-map OSPF6-CONN rule 20 action 'deny'
set policy prefix-list6 VENUE-V6 rule 20 prefix '2600:1900:41d1:92::/64'   # GCP (固定, r3:70,74)
# OPTAGE は D2-ii で PD 動的 → 固定 prefix-list 不可。下記いずれかで反映:
#   <要確認: PD client hook で VENUE-V6 を自動更新 or redistribute connected を広めに許可>
```

注意:

- **同一 /64 が eth2.30/eth2.40 に二重 connected**（OPTAGE/GCP とも、r3:69-74）。FRR は同一 prefix を 1 LSA に集約するが **LSDB 重複を bring-up 確認**。
- **OPTAGE /64 は PD 動的化**（§1.5）。固定で書けず PD 受領 prefix を反映する仕組みが要。GCP /64 は static で固定可。
- **★ connected-shadow（r3 側・§5-I）**: r3 が PD client 化し受領 /64 を eth2.30/40 に connected 付与すると、旧 `redistribute connected`（r3:139, BGP）に漏れる懸念。OSPFv3 移行で BGP v6 AF は削除するが、**PD 受領 /64 connected が OSPFv3 redistribute へ意図せず広がらないこと**を route-map で限定（上記 OSPF6-CONN）。旧 dum0 /128 強制（pd-update-venue.sh:44-50）が担っていた connected 抑止の代替を bring-up 確認。
- mgmt VLAN11（192.168.11.0/24, r3:66）は v4 only＝OSPFv3 対象外。

#### r2-gcp（VyOS/FRR）— v6 default 注入元

```
# --- 削除: v6 BGP ---
delete protocols bgp neighbor 10.255.1.1 address-family ipv6-unicast   # :285-286 (IX 脚)
delete protocols bgp neighbor 10.255.2.1 address-family ipv6-unicast   # :295-297 (r3 脚, default-originate 含む)

# --- OSPFv3 area0 ---
set protocols ospfv3 parameters router-id '10.255.255.2'
set protocols ospfv3 interface vti11 area '0.0.0.0'
set protocols ospfv3 interface vti11 network 'point-to-point'
set protocols ospfv3 interface vti11 dead-interval '1'
set protocols ospfv3 interface vti11 hello-interval '1'
set protocols ospfv3 interface wg2  area '0.0.0.0'             # r3 脚（WG 据え置き）
set protocols ospfv3 interface wg2  network 'point-to-point'
set protocols ospfv3 interface wg2  dead-interval '1'
set protocols ospfv3 interface wg2  hello-interval '1'

# --- v6 default を OSPFv3 へ注入（旧 v6 BGP default-originate の置換）---
set protocols ospfv3 default-information originate
# <要確認: always を付けるか。eth0 の ::/0 static(r2:405) 喪失時 default を流し続けると blackhole。
#  always 無し（default 経路存在時のみ）が安全寄り。FRR 挙動を bring-up 確認>
# NAT66 出口 /96 (2600:1900:41d0:9d::/96, eth0, r2:21) は OSPFv3 に出さない（redistribute connected しない）
```

> **DENY-DEFAULT-V6 の意図再表現**: 旧構成は r1 由来 BGP `::/0`(AD20) が GCP static default(AD210) を吸うのを import prefix-list `DENY-DEFAULT-V6`（r2:261-265,286,297）で防いでいた。OSPFv3 では r3/IX が学習する `::/0`(外部 LSA, AD110) が各ノードのローカル static / PBR table を壊さないことを確認。特に r3 の table 100/101 内 `::/0`（src-PBR 用 static, r3:174-177）は **別テーブルなので干渉しないが、main table(254) への OSPFv3 default の影響**を `show ipv6 route` で確認。

#### IX3315 側 OSPFv3 — 骨子

```
ipv6 router ospf
  router-id 10.255.255.1
interface Tunnel0
  ipv6 router ospf area 0           ! <要確認: area 指定書式 (一括列挙 or IF サブコマンド)>
  ipv6 ospf network point-to-point
  ipv6 ospf hello-interval 1
  ipv6 ospf dead-interval 1
  ipv6 ospf cost <要確認>
interface Tunnel1
  ipv6 router ospf area 0
  ipv6 ospf network point-to-point
  ipv6 ospf hello-interval 1
  ipv6 ospf dead-interval 1
  ipv6 ospf cost <要確認>
```

- IX は会場 v6 も default も生成しない（純トランジット）。redistribute 不要。
- **ECMP**: IX3315 v6 ECMP 最大 16。等コスト並列が出るのは限定状況。`<要確認: ECMP を効かせるか cost で単一寄せか>`。
- **cost による primary/backup**: 直結を低 cost・迂回をホップ合算で高 cost にすれば、明示 cost 無しでも primary=直結/backup=迂回が成立しうる。明示固定は `ipv6 ospf cost`(IX) / `set protocols ospfv3 interface X cost`(VyOS)。意図せぬ ECMP を LSDB で確認。

### 1.4 v6 src-PBR

> 固定値: GCP-src prefix = `2600:1900:41d1:92::/64`（D2-ii でも static, 確定）。OPTAGE-src prefix = `2001:ce8:180:5a79::/64`（**D2-ii で PD 動的＝現行リース値・参照用**、固定ではない）。

#### A. IX 側 v6 src-PBR（C-A-B 中継 = r3→IX→r2 の A→B 区間）

役割: r3 から IX に入った GCP-src を r2(GCP脚)へ中継。現行 r1 `route6 PBR-GCP`（wg0/wg1 着信→table100→`fd00:255:1::2`、r1-home.conf:192-195,237）の IX 置換。

**3 つの必須要件:**

1. **GCP-src のみマッチ**（OPTAGE-src ルールは置かない＝現行 r1 PBR-GCP も GCP-src 単一、r1:195 と一致）。
2. **discard フォールスルー（最重要・§5-I 最上位ブロッカー）**: `set interface Tunnel-r2` は IF down 時 RIB へフォールスルー → RIB default `::/0`→PPPoE WAN → **GCP-src が un-NAT66 で OPTAGE WAN から漏れる**。これを止める discard が必須。**RIB static では代替不可**（RIB は dst 一致のみ、src+dst discard を表現できない）。
3. **非マッチは通常 RIB へ透過**（OPTAGE-src/その他を PPPoE WAN へ）。

```
! === IX3315: v6 src-PBR (GCP-src → r2 中継) ===
! 【主案・確定アーキ名指しの multi-nexthop 形式】
!   set interface Tunnel1 Null0 = Tunnel1 down 時に Null0 へ自動 failover（discard 内包）
route-map PBR-V6-GCP-SRC permit 10
  match ipv6 address-list GCP-SRC          ! <要確認: NEC match 構文 (access-list/prefix-list)>
  set interface Tunnel1 Null0              ! <要確認: NEC multi-nexthop set interface 構文・Null0 discard 名>

! 【副案・主案不可時のみ】seq 20 単独 discard（NEC が skip 後に次 seq を評価する場合のみ有効）
! route-map PBR-V6-GCP-SRC permit 20
!   match ipv6 address-list GCP-SRC
!   set interface Null0

! --- 非マッチ透過: OPTAGE-src/その他は通常 RIB(PPPoE WAN) ---
!   <要確認: NEC policy route-map の default-action。暗黙 deny なら末尾 permit (no match/no set) を追加>

! GCP-src 定義
ipv6 access-list GCP-SRC permit src 2600:1900:41d1:92::/64 dst any   ! <要確認: NEC ACL 構文>

! 適用 (★ Tunnel0=r3 着信 単独推奨。Tunnel1 両適用は hairpin リスクのため optional)
interface Tunnel0
  ipv6 policy route-map PBR-V6-GCP-SRC
```

> **path-aware 障害（Tunnel1 up だが r2 dead）**: `set interface` は IF down しか追従しない。Network Monitor（`watch-group` + `action shutdown-policy route-map-seq` + `event source`）併用で seq 10 を論理 down → discard へ。構文 `<要確認>`。
> **hairpin**: Tunnel1 ingress で GCP-src を `set interface Tunnel1` すると着信 IF へ折り返す。Tunnel0 単独適用が clean。

#### B. r3 側 table100/101 next-hop（REUSE で IP 不変、IF が変わるのみ）

> **キーストン帰結**: `fd00:255::1`（= `fd00:255:0::1` = REUSE 時の IX VTI inner）を指す table 100/101 の static は **next-hop アドレス変更不要**。wg0→vti10 の解決 IF 切替は IPsec SA 確立で自動。**つまり明示の delete/set は原則不要**。ただし bring-up で「`fd00:255::1` が vti10 経由で解決される」ことを `show ipv6 route` で確認する（解決されない場合のみ next-hop を `fd00:255:0::1` に明示張り替え）。

```
# 確認対象（変更は原則不要。REUSE 前提）:
# table 100 route6 ::/0 next-hop fd00:255:2::2                  r3:174 (GCP-src primary = r2/WG)  ← 不変
# table 100 route6 ::/0 next-hop fd00:255::1 distance '210'     r3:175 (GCP-src backup = IX/VTI)  ← IP 不変、IF が vti10 に
# table 101 route6 ::/0 next-hop fd00:255:2::2 distance '210'   r3:176 (OPTAGE-src backup = r2/WG) ← §C/§5-I7 参照
# table 101 route6 ::/0 next-hop fd00:255::1                    r3:177 (OPTAGE-src primary = IX/VTI) ← IP 不変、IF が vti10 に
# table 100 route6 2600:1900:41d1:92::/64 interface eth2.30/40  r3:172-173 (connected) ← 触らない
# src-PBR 振り分け (PBR-V6 :118-123 / local-route6 :100-103) は next-hop を含まず ← 変更不要
```

> v4 escape `101.143.12.214/32 dhcp-interface eth1`（r3:171 = r1 公開 IP/WG outer）は IX outer endpoint へ要張り替え（§3、transport/cutover 担当領域）。

#### C. r2 の PBR-OPTAGE 不要化 → **削除可（条件付き）**

```
delete policy route6 PBR-OPTAGE                                       # r2-gcp.conf:268-270
delete protocols static table 101 route6 ::/0 next-hop fd00:255:1::1  # r2-gcp.conf:406
```

理由: PBR-OPTAGE は `interface wg2`(r3 から) かつ src=OPTAGE/64 を table101→`fd00:255:1::1`(r1) で中継する **C-B-A（r3→r2→r1）の OPTAGE-src 迂回**。D2-ii では OPTAGE-src failover が **host-driven** に変わるため役割を失う。削除後 OPTAGE-src が万一 r2 到達 → eth0 から un-NAT66 → GCP /96 外 drop（clean discard、intent と整合）。

surface すべき 2 点:

1. 削除は host-driven deprecate の即応性に依存。PD lease 失効ギャップ中、in-flight OPTAGE-src は r2 で blackhole（許容、§1.5 の v6-health-monitor 残置と連動）。
2. **r3-venue.conf:176（OPTAGE-src backup→r2）が dead path 化**。タスクは「再ポイント」だが、ここは設計判断: `<要確認: r3:176 を削除する or 意図的 blackhole として残置>`（§5-I7）。

### 1.5 PD 再委任（D2-ii）+ host-driven failover

#### IX: OPTAGE /64 を r3 へ再委任（connected 化しない）

```
ipv6 dhcp client-profile OPTAGE-PD
  ia-pd 0
interface <IX-WAN-PPPoE-IF>
  ipv6 dhcp client OPTAGE-PD          ! WAN で OPTAGE PD 受信 (= r1:103 length 64)

ipv6 dhcp server-profile R3-REDELEG
  ia-pd redistribute pool OPTAGE-PD nla-length 0   ! 受信 /64 を 1:1 再委任 (/64→/64)
interface Tunnel0                                  ! IX↔r3 VTI
  ipv6 dhcp server R3-REDELEG
  ! ⚠ ia-pd subscriber は張らない = 委任 /64 を connected にしない
  !   (connected AD0 > OSPFv3 AD110 の connected-shadow 回避)
```

> `<要確認: ia-pd redistribute pool ... nla-length 0 の正確構文・/64→/64 1:1 を意味するか・VTI 上 DHCPv6 server サポート>`

#### r3: DHCPv6-PD client 化（同一 /64 共有のため hook 方式）

**構造的注意**: 現行は OPTAGE `2001:ce8:180:5a79::/64` を **VLAN30(::1)/VLAN40(::2) で同一 /64 共有**（r3:69,73）。VyOS の `sla-id` 委任は VLAN ごと別 sub-/64 を切るモデル＝**同一 /64 共有と非互換**。よって受領 /64 を両 vif に直接 `address` 投入する hook を使う（現行 pd-update の 6 要素を r1 push → r3 local hook に移すだけ、prefix 展開ロジック温存）。

```
# r3: VTI(対 IX) で OPTAGE /64 を PD client 受信
set interfaces vti10 dhcpv6-options pd 0 length '64'   # <要確認: Circinus PD client 構文・受信 IF>

# /config/scripts/pd-apply-local.sh (PD client hook から起動。現行 push 6 要素と同型)
#   PREFIX_ADDR=<受領/64ネットワークアドレス>, NEW_PREFIX=<受領/64>
set interfaces ethernet eth2 vif 30 address ${PREFIX_ADDR}1/64
set interfaces ethernet eth2 vif 40 address ${PREFIX_ADDR}2/64
set service router-advert interface eth2.30 prefix ${NEW_PREFIX}      # lifetime 未指定=radvd 既定 (現行 pd-update:120 踏襲)
set service router-advert interface eth2.40 prefix ${NEW_PREFIX}
set service router-advert interface eth2.30 name-server ${PREFIX_ADDR}1
set service router-advert interface eth2.40 name-server ${PREFIX_ADDR}2
```

> `<要確認: Circinus PD client の prefix 変更 hook (systemd-networkd / wide-dhcpv6 でフックポイント差)。同一 /64 共有を保つ展開方式>`
> **除外維持（pd-update-venue.sh:17-20 踏襲）**: GCP prefix / RA interval / other-config-flag は触らない、DHCPv6-server 投入しない（SLAAC only）、interval は radvd 既定（Min200/Max600）、managed-flag 不使用。RA lifetime は明示 set しない（v6-health-monitor.sh の OPTAGE restore=delete モード, health-monitor:52,119-121 と衝突回避）。

#### 全廃する r1 機構

| 廃止対象 | 出典 |
|---|---|
| r1 task-scheduler `pd-update`（1分） | pd-update-venue.sh:4-6 / r1:339-340 |
| dum0 /128 強制（/64 connected が BGP v6 阻害の回避） | pd-update-venue.sh:44-50 |
| dum0 connected /64 削除 | pd-update-venue.sh:79,88 |
| r3 VyOS API push（delete6+set6） | pd-update-venue.sh:100-147 |
| STATE 差分検知 | pd-update-venue.sh:25,72-83,150 |
| r1 PD 委任先 `pppoe0 ... pd 0 interface dum0 sla-id 0` | r1-home.conf:102 |

→ r1-VyOS 自体が消える（純 IX）ため上記は移行で消滅。

#### host-driven failover の発火経路（設計結論）

非対称（§0.3 再掲）:

- **OPTAGE-src**: r3↔IX 断 → IX WAN PD は生きていても VTI 断で r3 への再委任途絶 → r3 の PD binding 期限切れ → OPTAGE prefix 無効化。ネットワーク迂回なし → **host-driven**（クライアントを GCP prefix へ）が唯一の手段。
- **GCP-src**: GCP /64 は r2 static で **C-A-B 迂回が生存**。ただし生存は **r3 が r2 に home(IX) 非依存で到達できること**＝**r3→r2 外殻を eth1 直に張り替える**ことが前提（§3、§5-I2）。
  - **重要訂正**: GCP-src primary は r3 table100 `fd00:255:2::2`（= r2、据え置き wg2/wg1 制御面）。この WG の**外殻**が現状 wg0(IX 経由) 二重カプセル化（wg-r1-tracker.sh:71）なので、**外殻を eth1 直にしない限り C-A-B は IX 障害で道連れ**。

**結論: VyOS の暗黙 Flash-RA に賭けず、明示 deprecate トリガを残す**:

1. **既存 `v6-health-monitor.sh` を残す**（r3:343-344, 1分間隔）。OPTAGE-src で src 指定 ping（health-monitor:66-79, src→table101 経由）→ 3 連続失敗で `deprecate_prefix`（RA preferred/valid=0 を API set, :90-106）。VyOS の暗黙挙動に依存せず確実に deprecate。
   - **★ probe 経路前提（§5-I）**: OPTAGE probe は src `2001:ce8:180:5a79::1` を table101 経由で出す（health-monitor:65,287-293）。REUSE で next-hop `fd00:255::1` は不変だが解決 IF が vti10 になる。**vti10 経由で OPTAGE probe が成立することを bring-up で確認してから health-monitor を有効化**（成立しないと無条件 FAIL→常時 deprecate 暴発）。
2. **高速トリガ**: VTI down / PD lease 喪失で `v6-health-monitor.sh --force-verify` 即時起動（health-monitor:27-29,209-216）。
   - **★ watcher 正規表現（§5-I）**: `v6-route-watcher.sh:36` の `default.*dev wg[01]` は **`dev (vti10|wg1)` へ更新**（wg0→vti10、wg1=r2 脚 据え置きは残す）。「dev vti10 系へ」の過剰縮約は誤り（wg1 喪失で GCP-src 出口検知が死ぬ）。
   - **★ 検知成立性（§5-I）**: IPsec route-based VTI の link-down が `ip -6 monitor route` に default 経路変化として出るか、PD lease 喪失 hook があるかは未確認。出ない場合の代替（lease expiry hook 直結 / VTI link-state watch）を bring-up で決める。

### 1.6 forensic D1=a（IX 内蔵 NAPT access-log → 既存 rsyslog→GCS）

設計の核:

- 現行 `conntrack -E | logger -t conntrack-nat -p local2.info`（conntrack-logger.sh:8-22）を **IX 内蔵 `ip napt access-log type normal`**（masquerade 全数記録）に置換。
- `syslog ... match nat-access-log` で分離送出 → 既存 rsyslog（CT200 `192.168.11.2`）→ 既存 conntrack ルーティング → GCS（180日）。
- **r1 conntrack-logger 退役**（自宅出口を IX が全数記録）。**r2-gcp の conntrack-logger は据え置き**（`conntrack-nat` v4 + `conntrack-nat6` v6、IX では代替不可）。

```
! --- NAPT 全数アクセスログ（normal=全数, sampled 禁止＝forensic 全数要件）---
ip napt access-log type normal            ! <要確認: キーワード綴り・適用単位(napt定義/interface)>

! --- logging subsystem（方針 warn/error）---
logging subsystem nat level warn          ! <要確認: NAPT access-log の facility/subsystem 名>

! --- syslog 分離送出: nat-access-log だけを CT200 へ ---
syslog ip host 192.168.11.2 match nat-access-log   ! <要確認: transport (TCP514 推奨/UDP514), port/protocol 構文>

! --- ★ 送出元アドレス固定（rsyslog src-ip フィルタ通過条件）---
!   rsyslog は 192.168.11.* / 10.255.* / 127.0.0.1 のみ受理 (rsyslog-60:44-50)
!   IX の syslog source を 10.255.* (VTI transfer の IX 側 /126 or loopback 10.255.255.1) に固定
syslog source-address <要確認: 10.255.x.x>   ! <要確認: source-address 指定構文>
```

**rsyslog 受信側（CT200）の統合整理**（フレーミング訂正）:

- **データ喪失ブロッカーではない**: ruleset 末尾に **無条件 `all/` 保険コピー**（rsyslog-60:84-88, stop 無し）があり、facility が local2 でなくても IX ログは `syslog-archive/all/` 経由で GCS に必ず到達する。
- よって facility 不一致は **「conntrack/ への集約 findability 問題」**。照会効率のため conntrack/ へ寄せるのが望ましい:
  - IX が facility=local2 相当で出せれば rsyslog 無改修で `conntrack/` 着地（rsyslog-60:52-58）。
  - 出せない場合のみ rsyslog に分岐 1 個追加:

    ```
    if ($fromhost-ip == "<IX src-ip>" and $syslogfacility-text == "<IX facility>") then {
      action(type="omfile" dynaFile="FileConntrack" template="BwAILogFmt" ... closeTimeout="300")
    }
    ```

- **src-ip フィルタ**（rsyslog-60:44-50）: IX source を `10.255.*` 固定で無改修通過。`10.255.*` に寄せられない場合のみ filter に IX IP 追記。
- **close 挙動**: per-action `closeTimeout="300"`（rsyslog-60:57,65,73,81,88）。グローバル `$DynaFileCloseTimeout` は当 conf に**存在しない**（logging-compliance.md:154 のレガシ指令表記は実 conf と乖離）。
- **Alloy/Loki fan-out**: ruleset 末尾の Alloy forward（rsyslog-60:90-98）に NAPT 全数も乗り CT201 Alloy→Loki(14日) に波及。Loki 流量/保持を bring-up 確認、必要なら IX NAPT を forward 前に分岐除外。

**GCS パーサ / 照会**:

- GCS 上は rsyslog 再整形後の行（BwAILogFmt = RFC3339 UTC + HOSTNAME + tag + msg, rsyslog-60:25-26）。IX 原文 envelope（`YYYY/MM/DD HH:MM:SS <FAC>.<NNN>: msg`）ではなく rsyslog 出力行をパースする。
- NAPT メッセージ ID 正規表現 `[A-Z]{2,4}\.\d{3}`（facility 略号+3桁）。**実物 1 行で略号を確定**してから cookbook grep を更新。
- **★ 変換後 port = forensic 必須要件（§5-I）**: 照会は「グローバル IP:port → 内部デバイス」。PPPoE 単一 IP を多数クライアントが共有するため **変換後 port こそが一意識別子**。cookbook 逆引き（`grep dport=…`, log-query-cookbook.md:51）が translated port に依存。**NAPT access-log が変換後 port を含むことを bring-up 最優先確認**。含まなければ逆引き不能＝設計差し戻し（PPPoE 単一 IP 定数注入は IP は補えても port=識別子は補えない）。
- **global src IP**: エントリに出ない前提なら PPPoE 単一グローバル IP を別ソース（IX PPPoE IF ログ/リース記録）から定数注入。PPPoE 割当 IP 変更履歴も forensic 保存対象に。
- **tag 互換**: cookbook の grep は tag/programname `conntrack-nat` 依存（log-query-cookbook.md:48,51,54）。IX に互換 tag を付けるか cookbook grep を IX 用に追補。

二重記録（経路相補）:

| 区間 | 記録主体 | facility/tag | 据え置き? |
|---|---|---|---|
| 自宅 PPPoE 出口 v4 NAPT | **IX `ip napt access-log`** | local2 合流目標 | 新規（r1 conntrack-logger 退役） |
| 会場 v4 NAPT（IX 経由 = r3→VTI→IX→OPTAGE） | **IX `ip napt access-log`** | 同上 | ★§1.7/§5-I4: 会場 user セッションの forensic 点 |
| r2-gcp v4 NAPT | r2 VyOS `conntrack-nat` | local2 | 据え置き |
| r2-gcp v6 NAT66 | r2 VyOS `conntrack-nat6` | local2 | 据え置き |

> v6 は IX 関与なし（NAT66 は r2 のみ）。GCP 向け v4 は r2 が記録、自宅/会場直接外向きは IX。**二重記録ではなく経路相補**。照会は両 hostname の conntrack ログ横断 grep。

### 1.7 home-lan（IX3315 自宅: PPPoE WAN + 家族 v4 LAN + ★会場 v4 NAPT）

> VyOS 側 config は無し（純 IX）。値は r1-home.conf 実値。IX 構文は NEC 公式マニュアル/FAQ 検証済み、未検証は `<要確認>`。

#### WAN (PPPoE/OPTAGE)

```
ppp profile optage-ppp
  authentication myname NTY97KV605@HF1G                ! r1:101
  authentication password NTY97KV605@HF1G <secret>     ! r1:100 (4nphkaun, secret 管理推奨)
interface <IX-WAN-PPPoE-IF>                            ! <要確認: OPTAGE 物理 GE 番号 (旧 IX=GE2)>
  encapsulation pppoe
  auto-connect
  ppp binding optage-ppp
  ip address ipcp                                       ! v4 = IPCP 取得 (= VyOS pppoe0)
  ipv6 enable
  ipv6 address autoconf                                 ! r1:105
  ip tcp adjust-mss auto                                ! r1:104
  ipv6 tcp adjust-mss auto                              ! r1:106
  no shutdown
ip route default <IX-WAN-PPPoE-IF>                      ! v4 default = WAN
ipv6 route ::/0 <要確認: fe80::290:1aff:fe00:3a が IX PPPoE で同一か> <IX-WAN-PPPoE-IF>   ! r1:236
```

#### LAN bridge → BVI

```
bridge irb enable
interface <LAN-GE-x>
  bridge-group 1
  no shutdown
interface BVI1
  ip address 192.168.10.1/24                            ! r1:65
  ip dhcp binding family-lan
  no shutdown
```

> ブリッジ物理ポート番号は実機配線依存 = `<要確認>`（旧 IX=GE0/1/3/4, ix3315-migration.md:12）。

#### DHCPv4

```
ip dhcp enable
ip dhcp profile family-lan
  assignable-range 192.168.10.3 192.168.10.199          ! r1:249-250
  default-gateway 192.168.10.1                          ! r1:246
  dns-server 192.168.10.1                               ! r1:247
  lease-time 86400                                      ! r1:245
  fixed-assignment 192.168.10.3 88:c2:55:2f:d5:14       ! r1:251-252 device-3
  fixed-assignment 192.168.10.4 9c:6b:00:04:ca:19       ! r1:253-254 main-pc
  ! NTP option 配布 = <要確認: ip dhcp profile での ntp-server option 構文> (r1:248)
```

> 旧 IX の `.9` 固定割当（ix3315-migration.md:14）は現 VyOS で router 自身（eth0 hw-id 70:85:c2:b1:6f:7b = r1:69）＝**復活させない**（`<要確認: 別ホストとして復活有無、既定: しない>`）。

#### source NAPT — ★会場 VLAN を含む（必須・home-lan draft の誤りを訂正）

```
! 家族 LAN
ip napt enable ...   192.168.10.0/24                    ! r1:153-155 rule100
! ★ 会場 v4（必須）: r3 は nat source も独自 v4 default も持たず、
!   会場非 goog v4 は r3→VTI→IX→OPTAGE で masquerade される。
!   落とすと会場 v4 全断 + D1=a forensic で会場 user セッション欠落。
ip napt enable ...   192.168.11.0/24                    ! r1:156-158 rule110 (mgmt)
ip napt enable ...   192.168.30.0/24                    ! r1:159-161 rule120 (staff-live)
ip napt enable ...   192.168.40.0/22                    ! r1:162-164 rule130 (user)
```

> disposition: rule20(172.16.0.0/30, r1:150-152) と rule150/160(WG transfer 10.255.0/30,10.255.1/30, r1:169-176) は **VTI 化で消える transfer 系＝drop**。rule140(10.64.56.0/22, eth3 シミュレータ, r1:165-168) は撤去済み環境用＝drop。

#### static port-forward（DNAT → 192.168.10.4）

```
! 指定 primary source = ix3315-migration.md:31 (ip napt static) 準拠
ip napt static  tcp 80   192.168.10.4    ! r1:130-134 SoftEther-HTTP
ip napt static  tcp 443  192.168.10.4    ! r1:135-139 wstunnel-HTTPS
ip napt static  tcp 5201 192.168.10.4    ! r1:140-144 iperf3-tcp
ip napt static  udp 5201 192.168.10.4    ! r1:145-149 iperf3-udp
! 旧 IX の tcp22/udp51820→.9 (ix3315-migration.md:17) は .9 時代の名残＝carry over しない
!   (現 VyOS DNAT rule20-50 は全て →.4)
! ヘアピン NAT は ix3315-migration.md:32 (ip napt hairpinning) 準拠。<要確認: 二重 NAT にならないこと>
```

#### v4/v6 FW

```
! WAN→自身 (= WAN-LOCAL, default drop, r1:36-53)
!   established/related (r1:37-39), ICMP (r1:40-41), SSH22 (r1:42-45) を温存
!   WG ポート 51820/51821 (r1:46-53) は IPsec(UDP500/4500) 受信許可に置換 (transport 担当)
! WAN→LAN (= WAN-LAN, default drop, r1:22-35): port-forward 宛のみ new 許可 (→.4)
! WANv6-LOCAL: established/related, icmpv6, DHCPv6 reply(udp546 src547, r1:54-64) を IX v6 ACL に
! <要確認: IX の stateful(established/related) 表現・自身宛/転送宛 ACL 分離・NAPT static の inbound 自動許可>
```

#### proxy-dns / NTP / v6 PD 受信

```
! proxy-dns: OPTAGE DNS 明示 (system 連鎖はループ回避)
proxy-dns ip enable
proxy-dns ip address 59.190.146.145 ...                 ! r1:268
proxy-dns ip address 59.190.147.97  ...                 ! r1:269
!   許可元は 192.168.10.0/24 主 (会場名前解決は r3 責務)。<要確認: 許可元 ACL/priority/cache 構文 (cache 2048 = r1:263)>
! NTP: 上流同期 + LAN/mesh へ NTP server 提供
ntp server ntp.jst.mfeed.ad.jp                          ! r1:286
ntp server ntp.nict.jp                                  ! r1:287 (time*.vyos.net は IX で IP/名前代替)
!   許可元: 192.168.10.0/24 + ★ mesh 10.0.0.0/8 (r1:280 相当)
!   ★ r3 は 'ntp server 10.255.0.1 prefer' (r3:285)。REUSE で 10.255.0.1 = IX Tunnel0。
!     IX が mesh からの NTP を許可しないと r3 の preferred 時刻源が cutover で死ぬ
!     (フォールバックは r3:286 の 10.255.2.2=r2、r2:428 で許可。非ブロッカーだが prefer を宙吊りにしない)。
!   <要確認: IX を NTP サーバ化し LAN/mesh 提供する構文と許可元>
! v6 PD 受信 = §1.5 (再委任は §1.5 の seam)
interface <IX-WAN-PPPoE-IF>
  ipv6 dhcp client OPTAGE-PD                             ! <要確認: PD client 有効化構文> (= r1:103 length 64)
```

> **★ §1.7 スコープ縮約で落ちる「家族 LAN 超の r1 提供サービス」（移行損失・要手当て）**:
>
> - **NTP to mesh**: 上記の通り r3:285 `prefer` 用に IX `ntp allow-client` へ mesh 範囲を追加（または r3:285 の `prefer` を生存源へ repoint）。Phase2 repoint 対象（§3 表に追記）。
> - **SNMP to NOC**: r1-home.conf:291-296 が `192.168.11.6`(BwAI-NOC) へ SNMP + `dhcp_status` script-extension を提供。IX は VyOS でないため script-extension を carry できず、IX 自身は手当てしないと Zabbix から消える。本タスクのプレーン外だが移行損失として明示＝**SNMP を NOC へ carry する（IX 標準 SNMP, script-extension は別途）か、明示的にスコープ外と判断する**。

---

## 2. v6 経路冗長の整理

> **前提（§3 で確定）**: r3→r2 外殻を **eth1 直 (DIRECT)** に張り替える。これにより GCP-src の C-A-B 生存（IX 非依存）が成立する。eth1 直が venue 上流の UDP 通過に依存する点は §4 PoC のゲート。

### 2.1 src 別 出口と冗長機構

| src | primary | backup | failover 機構 | IX 依存 |
|---|---|---|---|---|
| **GCP-src** `2600:1900:41d1:92::/64` | r3→r2 (wg2/wg1 制御面, 外殻 eth1 直) → NAT66 → GCP | r3→IX(VTI)→r2 = **C-A-B** | OSPFv3/static table100 + IX src-PBR(set interface Tunnel1) | **C-A-B のみ IX 依存**。primary は IX 非依存 |
| **OPTAGE-src** `2001:ce8:…/64`（PD 動的） | r3→IX(VTI) → OPTAGE WAN | （ネットワーク迂回なし） | **host-driven**: PD binding 喪失→r3 が OPTAGE RA Lifetime0 deprecate→クライアント GCP へ | primary が IX 経由 |

### 2.2 障害シナリオ別挙動

| シナリオ | GCP-src | OPTAGE-src | 備考 |
|---|---|---|---|
| **平常** | r3→r2(eth1直)→NAT66→GCP | r3→IX(VTI)→OPTAGE WAN | 両 src 正常 |
| **IX/home 全障害**（VTI 両断） | **生存**: primary が IX 非依存（r3→r2 eth1 直）。C-A-B backup は失うが primary 健在 | **host-driven failover**: r3 への PD 再委任途絶→OPTAGE prefix deprecate→クライアントが GCP prefix へ移行（GCP-src として GCP egress） | ★非対称の核。eth1 直前提が崩れる（r3→r2 を VTI 経由にする）と GCP-src も道連れ＝対称死 |
| **r3↔r2 断**（wg2/wg1 外殻 eth1 直が不通） | **C-A-B 迂回で生存**: r3→IX(VTI)→r2（IX src-PBR set interface Tunnel1）→NAT66→GCP | 影響なし（OPTAGE は IX 経由のまま） | C-A-B は IX 健在が前提 |
| **r2/GCP 全障害** | GCP-src 出口消失。IX src-PBR の **discard（set interface Tunnel1 Null0）が発火**し un-NAT66 漏れを防ぐ（§1.4 要件2） | 影響なし | discard が効かないと GCP-src が OPTAGE WAN から un-NAT66 で漏れる＝最重要ブロッカー(§5-I) |
| **PD lease 失効ギャップ** | 影響なし | in-flight OPTAGE-src は deprecate 完了まで r2 で blackhole（clean discard、許容） | v6-health-monitor の高速 deprecate(~20s) で短縮 |

### 2.3 収束時間の見込み（実測は §4）

- **v4**: BFD 廃止により holdtime 9s 律速（旧 0.6–0.9s から劣化）。network-monitor で短縮可だが interval/閾値は IX 仕様確認。
- **v6 OSPFv3**: dead-interval 1s で隣接喪失 ~1-3s 収束目標（NEC↔FRR で実際に 1s が噛むか §4）。
- **OPTAGE host-driven deprecate**: v6-health-monitor の force-verify で ~20s（旧 ~3分から短縮、netlink watcher 駆動）。**ただし VTI link-down 検知成立性は未確認**（§5-I）。

---

## 3. 移行手順とロールバック

> **全フェーズ貫通の前提（rollback anchor）**: r1-VyOS は Phase3 確認完了まで物理温存・config 凍結。ケーブル差し戻し（ix3315-migration.md:74-76）は r1 無傷で成立。
> **PPPoE 単一制約**: OPTAGE 回線・認証は 1 つ。r1-VyOS と IX は同時に PPPoE を所有できない。

### Phase 0 — lab 投入・家族 LAN 検証（IX 単独、WAN 未接続）

IX を別線でブートし家族 LAN 役（bridge/DHCPv4/proxy-dns/NTP/v4 FW）を検証。WAN 未接続。r1-VyOS 本番稼働のまま。ロールバック = IX 電源断のみ（本番影響ゼロ）。

### Phase 1 — VTI を現行 WG と共存、現行優先で待機

r2/r3 が WG(r1 経由) と VTI(IX 経由) の両経路を観測し、定常は WG/eBGP 優先。

- **Phase1 上流到達**: IX を r1-VyOS 背後に暫定収容し **NAT-T(UDP500+UDP4500) を IX へ port-forward**（raw ESP/proto50 は r1 NAT を通せない＝列挙しない。IKEv2 は NAT 背後で NAT-T/UDP4500 を自動選択）。`<要確認: 暫定上流到達手段と IX 暫定 outer アドレス>`
- r2/r3 に VTI + v4 eBGP(待機 LP) + OSPFv3 を**追加**しつつ現行 WG/eBGP を残す。
- **v6 現行優先の根拠（訂正）**: VLAN30/40 クライアント v6 egress は main-table default ではなく **src-PBR static table100/101（r3:172-177）が決める**。Phase1 ではこれを触らないため**構成上現行が保たれる**（「eBGP AD20 が OSPFv3 AD110 に勝つ」が理由ではない）。OSPFv3 default leak/interop は別ガードとして `show ipv6 route` で AD110 default が table100/101 を置換しないか確認。
- ロールバック: 追加した VTI/eBGP/OSPFv3 を delete。現行 WG/eBGP/src-PBR 無傷。

### Phase 2 — WAN・LAN カットオーバー + forensic 同時起動 + 外殻張り替え

PPPoE 所有権を r1-VyOS→IX へ。**IX が NAPT GW になる瞬間に forensic を同時起動**（D1=a、「NAPT したが記録なし」窓を作らない）。

- IX に WAN + 会場含む全 NAPT（§1.7）+ `ip napt access-log` + `syslog match nat-access-log` + escape `34.97.197.104/32`（§1.1）を投入。
- ケーブル: r1 PPPoE 切断 → WAN を IX へ → LAN を IX bridge へ → IX PPPoE 確立 → 家族 DHCP renew。
- **r3 外殻張り替え（★§5-I2）**: r3→r2 の外殻を eth1 直へ。`101.143.12.214/32 dhcp-interface eth1`（r3:171）を IX outer endpoint へ。**wg-r1-tracker.sh を退役**（後述）。
- r3 v4: neighbor 10.255.0.1 の BFD/v6 AF 削除 + VTI bind（§1.2、REUSE で in-place）。table100/101 は REUSE で next-hop 不変（§1.4-B、bring-up 確認のみ）。
- r2 v4: neighbor 10.255.1.1 の BFD/v6 AF 削除 + VTI bind。NAT66(r2:57-60) 不変。
- 検証: 家族/会場インターネット疎通、DNAT(.4)、r2↔r3 維持、IX NAPT access-log の GCS 着信（facility/port 1 行確認）、src-PBR 機能。
- ロールバック（ケーブルレベル即時）: WAN/LAN を r1 へ戻す。r1 config 凍結。

### Phase 3 — PD 切替（D2-ii）+ 旧 forensic 退役

OPTAGE /64 伝播を「r1 pd-update push」→「IX `ia-pd redistribute` + r3 PD client」へ。

- **⚠ Phase3 ロールバックは cable レベルでなく独立でもない（正直な明示）**: PD lease は PPPoE 所有者に紐づく。Phase2 で IX が WAN 所有後、r1 pd-update は lease を持たず動作しない。PD-client/redistribute 失敗時は **(i) fix-forward または (ii) Phase2 経由巻き戻し（ケーブルを r1 へ戻し push 方式復元）のみ**。「各 Phase 独立ロールバック」は PD/forensic については成立しない。
- IX: `ia-pd redistribute pool ... nla-length 0`（connected 化しない）。r3: PD client 化 + hook（§1.5）。r1: pd-update task 停止・conntrack-logger 退役。
- r2: PBR-OPTAGE + table101 static 削除（§1.4-C、Phase2 で静観可）。
- 検証: r3 PD /64 受領→eth2.30/40 + RA 反映→会場クライアント OPTAGE GUA 取得・v6 疎通。IX NAPT access-log のみ GCS 着信、r1 conntrack 停止確認。

### スクリプト退役（★§5-I2・移行で必須）

| スクリプト | 配置/登録 | 退役理由 |
|---|---|---|
| `scripts/r3-venue/wg-r1-tracker.sh`（r3:345-346） | r3 task 1m + bootup | line47=101.143.12.214/32 escape, line61=wg0 endpoint 書換, **line71-72=r3→r2 の wg0 二重カプセル化外殻**。wg0 消滅で機能不全＋毎分 dead wg0 を突く。**退役 or IX outer+eth1 直管理へ書換** |
| `scripts/r3-venue/wg-r1-tracker-r2.sh`（r2-gcp 用） | r2 task（r2-gcp.conf:462-463） | r2 の r1 endpoint 追従。r1 消滅で対象消失＝退役 or IX 向け書換 |
| `scripts/r3-venue/v6-route-watcher.sh:36` | r3 systemd 常駐 | 正規表現 `dev wg[01]` → `dev (vti10|wg1)` 更新（退役ではなく改修） |
| `scripts/r1-home/pd-update-venue.sh`（r1:339-340） | r1 task 1m | D2-ii で全廃（§1.5） |
| `scripts/r1-home/conntrack-logger.sh` + service | r1 systemd | D1=a で IX 置換（§1.6） |
| r3 `ntp server 10.255.0.1 prefer`（r3-venue.conf:285） | r3 config | REUSE で 10.255.0.1=IX Tunnel0。IX が mesh NTP を許可するか、`prefer` を生存源（10.255.2.2=r2）へ repoint（§1.7、非ブロッカー） |
| r1 SNMP→NOC（r1-home.conf:291-296） | r1 config | IX へ carry（script-extension 除く）or 明示スコープ外判断（§1.7、監視損失） |

---

## 4. bring-up PoC チェックリスト（実機半日）

| # | 項目 | 手順 / 合否基準 | 関連 |
|---|---|---|---|
| **P1** | **GCP-src 漏れ確認（最優先ブロッカー）** | Tunnel1 を意図 down → GCP-src `2600:1900:41d1:92::1` で外部 v6 ping。**OPTAGE WAN から un-NAT66 で出ない**こと（discard 発火）を IX NAPT ログ/上流 pcap で確認。判別質問: 「NEC は `set interface` IF-down skip 後に同 route-map 次 seq を評価するか / multi-nexthop `set interface Tunnel1 Null0` は Null0 member を受理するか」 | §1.4-A, §2.2 |
| **P2** | **NAPT facility 実 1 行確認** | IX で 1 セッション NAPT させ、CT200 `syslog-archive/`（all/ と conntrack/）に着信した実 1 行を採取。確認: (a) facility が local2 か、(b) **変換後 port を含むか（forensic 必須・含まねば差し戻し）**、(c) フィールド並び、(d) ID 略号 `[A-Z]{2,4}\.\d{3}`、(e) global src IP 有無 | §1.6 |
| **P3** | **OSPFv3 NEC↔FRR 隣接** | IX↔r3 / IX↔r2 で OSPFv3 Full 到達。確認: hello/dead 1s が実際に噛むか、P2P network type interop、**MTU 整合（ExStart スタック回避、WG/VTI 1400 ↔ IX VTI MTU）**、instance-id 0 一致、link-local next-hop 解決。`default-information originate`(r2) と `redistribute connected`(r3) が AD110 で table100/101 static を置換しないこと | §1.3（verdict=null＝最重点） |
| **P4** | **OPTAGE PPPoE 接続時の PD 受信（DH6.012 解消）** | IX が WAN で OPTAGE /64 を PD 受信 → `ia-pd redistribute` で r3 へ → r3 が PD client で受領（`show dhcpv6 client pd`）→ eth2.30/40 + RA 反映 → 会場クライアント OPTAGE GUA 取得。DUID 変更で別 /64 を払い出すかも確認 | §1.5 |
| **P5** | **収束時間実測** | (a) VTI 断 → v4 BGP 収束（holdtime 9s 律速の実測値）、(b) OSPFv3 収束（dead 1s, 目標 ~1-3s）、(c) **OPTAGE host-driven deprecate 実測**（v6-route-watcher が VTI link-down を `ip -6 monitor route` で拾えるか＝拾えねば代替 hook、force-verify→RA Lifetime0 まで ~20s 目標） | §2.3, §5-I |
| **P6** | **r3→r2 外殻 eth1 直の venue UDP 通過** | r3 から r2 endpoint(34.97.197.104) へ eth1 直で WG 外殻 UDP が通るか（venue 上流通過）。**通れば §2 の非対称（GCP-src 生存）が成立、通らねば外殻を IX VTI へ＝対称死を設計に反映** | §2, §3, §5-I2 |
| **P7** | **GCM/PRF/PFS 三点照合 + VTI 確立** | IX `aes-gcm-256-16`/`prf hmac-sha2-256`/`group15` ↔ VyOS `aes256gcm128`/`prfsha256`/`dh-group15`。ICV/PRF/PFS 不一致は CHILD SA 不成立。r3 initiator/IX responder、r2 NAT-T(UDP4500)、escape 34.97.197.104/32 でループしないこと | §1.1 |
| **P8** | **OPTAGE probe 経路 + connected-shadow** | OPTAGE probe src→table101→vti10 で外部到達（無条件 FAIL→常時 deprecate 暴発を回避）してから v6-health-monitor 有効化。r3 PD 受領 /64 connected が OSPFv3/redistribute に漏れない（OSPF6-CONN 限定） | §1.3, §1.5 |

---

## 5. 検証で残った issues（consistent≠yes を最上位）

> 6 プレーンの敵対的検証は全て **consistent=partial**（v6-ospfv3 は verdict=null＝未検証）。下記は本設計で fix を反映済みだが、bring-up で潰すまで closed にしない。

### I1. 【最重要ブロッカー】GCP-src discard 機構が机上で死ぬ恐れ（v6-srcpbr）

`set interface Tunnel-r2` の IF-down は「同 route-map 次 seq へ落ちる」ではなく「main RIB へ直行し残り seq をバイパス」と解するのが自然。その場合 seq-20 単独 discard は到達不能。**RIB static でも代替不可**（RIB は dst 一致のみ、src+dst discard を表現できない）。→ **fix 反映**: 主案を multi-nexthop `set interface Tunnel1 Null0`（確定アーキ名指し）に変更、seq-20 は「次 seq 評価が確認できた場合のみ」に条件付き降格。**PoC P1 で判別**。

### I2. 【Section 2 を決める】r3→r2 外殻の二重カプセル化と「r2↔r3 据え置き」の偽り（cutover/transport/pd）

`wg-r1-tracker.sh:71` が r3→r2 endpoint(34.97.197.104) を `via 10.255.0.1 dev wg0` で二重カプセル化＝**r3↔r2 は外殻で home を経由**。wg0 消滅で破綻。「r2↔r3 一切変更しない」は制御面のみ真、**外殻は wg0 から張り替え必須**。→ **fix 反映**: r3→r2 外殻を **eth1 直 (DIRECT)** に張り替え（GCP-src 非対称生存の前提）。wg-r1-tracker.sh(r3) + wg-r1-tracker-r2(r2) を退役/書換。**eth1 直の venue UDP 通過は PoC P6 でゲート**。通らねば §2 の非対称が崩れ対称死になる。

### I3. 【ESP 外殻ループ】IX に 34.97.197.104/32 escape が必要（transport）

r2 は GOOG で 34.64.0.0/10（rule690, 34.97.197.104 内包）を v4 BGP 広告し IX も受信。escape /32 が無いと IX→r2 の ESP 外殻が Tunnel1 にループ。→ **fix 反映**: IX に `ip route 34.97.197.104/32 <PPPoE>`（旧 r1:235 等価）。r3:171 の `101.143.12.214/32` は IX outer へ。

### I4. 【会場 v4 全断 + forensic 欠落】会場 NAPT(110/120/130) は IX で必須（home-lan）

r3 は nat source も独自 v4 default も持たず、会場非 goog v4 は r3→VTI→IX→OPTAGE で masquerade。落とすと会場 v4 全断＋D1=a で会場 user セッションが NAPT ログから欠落。→ **fix 反映**: IX に 192.168.11/30/40 source NAPT を**必須**として残す（§1.7）。home-lan draft の「本来不要」を訂正。

### I5. 【未検証プレーン】v6-ospfv3 は敵対的 verdict が無い（v6-ospfv3）

唯一 verdict=null。NEC↔FRR interop（MTU/ExStart, hello-dead 1s 噛み, instance-id）、`default-information originate` leak vs table100/101 static、cost/ECMP が未検証。→ **本設計でマーク**: §1.3 を骨子扱いとし **PoC P3 を最重点**に格上げ。隣接成立まで「未検証」を closed にしない。

### I6. 【probe 暴発】OPTAGE probe 経路が REUSE で IF 変化（pd/v6-srcpbr）

v6-health-monitor の OPTAGE probe は src→table101→（旧 wg0）で出る。REUSE で next-hop 不変だが解決 IF が vti10 に。vti10 経由で probe が成立しないと無条件 FAIL→常時 deprecate 暴発。→ **fix 反映**: table101 の vti10 解決を確認してから health-monitor 有効化（PoC P8）。watcher 正規表現は `dev (vti10|wg1)` へ（`dev vti10` 単独縮約は誤り＝wg1 喪失で GCP-src 検知が死ぬ）。

### I7. 【設計判断未決】r3-venue.conf:176（OPTAGE-src backup→r2）の処遇（v6-srcpbr）

r2 PBR-OPTAGE 撤去で r3:176（OPTAGE-src→r2 backup）が dead path 化。タスクは「再ポイント」だが host-driven 化で中継先消失。→ **未決として明示**: `<要確認: r3:176 を削除 or 意図的 blackhole 残置>`。

### I8. 【forensic 必須要件】変換後 port の確保（forensic）

照会は「グローバル IP:port→内部デバイス」。PPPoE 単一 IP 共有のため変換後 port が一意識別子（cookbook 逆引き依存, log-query-cookbook.md:51）。→ **fix 反映**: NAPT access-log が変換後 port を含むことを **PoC P2 で最優先確認**。含まねば逆引き不能＝設計差し戻し。global src IP 不在は PPPoE 単一 IP 定数注入で補うが、port は補えない。

### I9. 【VyOS 構文】Circinus の prf/vti/PD client 構文は IX 同様 bring-up 照合（transport/pd）

VyOS 2026.03 rolling の `prf prfsha256` / `vti bind` / `interfaces vti` / DHCPv6-PD client 構文は変動余地あり。→ **マーク**: GCM/PRF/PFS 三点照合（P7）に VyOS 側構文確認も含める。

### I10. 【正直な制約】Phase3 ロールバックは独立でない（cutover）

PD lease は PPPoE 所有者に紐づくため、Phase3 失敗時のロールバックは fix-forward か Phase2 経由のみ。「各 Phase 独立ロールバック」は PD/forensic に成立しない。→ **§3 に明示済み**。

### 既知の非ブロッカー（参考）

- `WG-IN` route-map 名は IPsec 化後 misnomer だが安定優先で温存（改名は r3 も触る）。
- facility 不一致は data-loss ブロッカーではない（rsyslog `all/` 保険コピー, :84-88）。conntrack/ 集約 findability の問題。
- BFD peer は CONFIRMED: r3 = r3-venue.conf:124-127、r2 = r2-gcp.conf:271-274（source 10.255.1.2 = r1 脚）。`<要確認>` ではなく delete 確定。

---

## 付録: 主要ファイルパス（実値出典）

- `C:\repository\BwAInet\docs\configs\r1-home.conf`（PPPoE/NAPT/BGP/route-map/PBR-GCP/BFD/PD/forensic 退役対象）
- `C:\repository\BwAInet\docs\configs\r2-gcp.conf`（GOOG static/default-originate/NAT66/PBR-OPTAGE/BFD :271-274/wg2 据え置き）
- `C:\repository\BwAInet\docs\configs\r3-venue.conf`（VLAN/RA dual-prefix/PBR-V6/table100-101/BFD :124-127/wg0→VTI）
- `C:\repository\BwAInet\docs\investigation\ix3315-migration.md`（IX↔VyOS 構文対応表、port-forward=ip napt static, hairpin=ip napt hairpinning）
- `C:\repository\BwAInet\scripts\r1-home\pd-update-venue.sh`（D2-ii で全廃）
- `C:\repository\BwAInet\scripts\r1-home\conntrack-logger.sh`（D1=a で IX 置換）
- `C:\repository\BwAInet\scripts\r3-venue\wg-r1-tracker.sh`（line71 二重カプセル化、退役/書換）
- `C:\repository\BwAInet\scripts\r3-venue\wg-r1-tracker-r2.sh`（r2 用、退役/書換）
- `C:\repository\BwAInet\scripts\r3-venue\v6-route-watcher.sh`（line36 正規表現 dev (vti10|wg1) へ）
- `C:\repository\BwAInet\scripts\r3-venue\v6-health-monitor.sh`（OPTAGE 高速 deprecate、残す）
- `C:\repository\BwAInet\scripts\local-server\rsyslog-60-bwai-forensic.conf`（src フィルタ:44-50, local2→conntrack:52-58, all/ 保険:84-88, Alloy:90-98）
