# マルチベンダースイッチ CLI 対比リファレンス

会場スイッチ共通設計 ([`../design/venue-switch.md`](../design/venue-switch.md)) の各ベンダー CLI 実装例。Cisco IOS/IOS-XE、FS (Cisco-like)、HPE Aruba CX、Juniper Junos ELS、MikroTik RouterOS をカバー。

**注意**: 厳密な構文はベンダー公式ドキュメントで確認すること (バージョン依存あり)。

## 基本操作対比

| 操作 | Cisco IOS / IOS-XE (ESM) / FS | HPE Aruba CX | Juniper Junos (ELS) | MikroTik RouterOS |
|------|-------------------------------|--------------|---------------------|-------------------|
| VLAN 作成 | `vlan 11` `name mgmt` | `vlan 11` `name mgmt` | `set vlans mgmt vlan-id 11` | `/interface bridge vlan add bridge=bridge1 vlan-ids=11` |
| Access (T3/T4) | `switchport mode access` `switchport access vlan 30` | `interface 1/1/1` `no routing` `vlan access 30` | `set interfaces ge-0/0/0 unit 0 family ethernet-switching interface-mode access vlan members staff` | `/interface bridge port add bridge=bridge1 interface=ether3 pvid=30` |
| Trunk T1 (native なし) | `switchport mode trunk` `switchport trunk allowed vlan 11,30,40` | `interface 1/1/1` `no routing` `vlan trunk allowed 11,30,40` `no vlan trunk native` | `set interfaces ge-0/0/0 unit 0 family ethernet-switching interface-mode trunk vlan members [mgmt staff user]` | `/interface bridge port add bridge=bridge1 interface=ether1 frame-types=admit-only-vlan-tagged` + `/interface bridge vlan add bridge=bridge1 tagged=ether1 vlan-ids=11,30,40` |
| Trunk T2 (native 11) | `switchport mode trunk` `switchport trunk allowed vlan 11,30,40` `switchport trunk native vlan 11` | `interface 1/1/1` `no routing` `vlan trunk allowed 11,30,40` `vlan trunk native 11` | `set interfaces ge-0/0/0 unit 0 family ethernet-switching interface-mode trunk vlan members [mgmt staff user]` `set interfaces ge-0/0/0 native-vlan-id 11` | `/interface bridge port add bridge=bridge1 interface=ether1 pvid=11 frame-types=admit-all` + `/interface bridge vlan add bridge=bridge1 tagged=ether1 vlan-ids=11,30,40` |
| 管理 SVI (VLAN 11 IP) | `interface Vlan11` `ip address 192.168.11.x 255.255.255.0` | `interface vlan 11` `ip address 192.168.11.x/24` | `set interfaces irb unit 11 family inet address 192.168.11.x/24` `set vlans mgmt l3-interface irb.11` | `/interface vlan add interface=bridge1 name=vlan11 vlan-id=11` + `/ip address add address=192.168.11.x/24 interface=vlan11` |
| デフォルト GW | `ip default-gateway 192.168.11.1` | `ip route 0.0.0.0/0 192.168.11.1` | `set routing-options static route 0.0.0.0/0 next-hop 192.168.11.1` | `/ip route add dst-address=0.0.0.0/0 gateway=192.168.11.1` |
| LLDP 有効化 | `lldp run` | `lldp` | `set protocols lldp interface all` | `/interface bridge port set auto-isolate=no` + LLDP は別設定 |

### 注意点

- **Native VLAN は T2 (AP) のみ**: T1 (幹線) では native VLAN を設定しない。対向が全て tagged VLAN 11 で参加しているため (tagged 自力参加設計)、native 設定があると L2 不一致
- **Cisco `native vlan 11` / Junos `native-vlan-id 11` / MikroTik `pvid 11`** — 意味は同じ、構文が異なる
- **Aruba CX** はデフォルト `vlan trunk native 1`。明示的に `vlan trunk native 11` 必要
- **Junos ELS**: EX2300/3400 以降は `interface-mode`、旧機種は `port-mode`
- **MikroTik**: `/interface bridge set bridge1 vlan-filtering=yes` を忘れると VLAN が機能しない
- **FS (FSOS)**: Cisco-like だがハイフン区切りが多い (例: `mld-snooping`)

## IPv6 マルチキャスト対策 CLI 対比

| 操作 | Cisco IOS / IOS-XE (ESM) / FS | HPE Aruba CX | Juniper Junos (ELS) | MikroTik RouterOS |
|------|-------------------------------|--------------|---------------------|-------------------|
| MLD Snooping (グローバル) | `ipv6 mld snooping` (Cisco) / `ipv6 mld-snooping enable` (FS) | デフォルト有効 (AOS-CX 10.16+) | `set protocols mld-snooping vlan <vlan>` | `/interface bridge set <bridge> igmp-snooping=yes` |
| MLD Snooping (VLAN) | `ipv6 mld snooping vlan <id>` (Cisco) / `ipv6 mld-snooping vlan <id>` (FS) | `vlan <id>` → `ipv6 mld snooping enable` | VLAN 名で指定 | bridge 単位で一括 |
| Storm Control (マルチキャスト) | `storm-control multicast level <pps>` (Cisco) / `storm-control multicast <threshold>` (FS) | `storm-control <if> multicast level <pps>` | `set interfaces <if> unit 0 family ethernet-switching storm-control` | `/interface bridge port set storm-rate` |

> **RA Guard**: スイッチでは設定しない (本プロジェクトの方針)。不正 RA 対策は WLC/AP 側で実施。

### 機種別の注意

- **Cisco ISR 1100 (ESM)**: MLD Snooping の ESM 対応は文書上不明確 — 実機で `ipv6 mld snooping ?` で確認。WAN 側 EVC + bridge-domain では IP マルチキャスト非サポート

## 関連

- [`../design/venue-switch.md`](../design/venue-switch.md) — 共通設計 (ポート種別 T1-T5、tagged 自力参加)
- [`../design/venue-switch1.md`](../design/venue-switch1.md) — sw01 (FS) 実装
- [`../design/venue-switch2.md`](../design/venue-switch2.md) — sw02 (Cisco ISR 1100) 実装
- [`../design/mgmt-vlan-address.md`](../design/mgmt-vlan-address.md) — 管理 VLAN アドレス表
