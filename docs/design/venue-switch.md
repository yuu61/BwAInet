# 会場スイッチ (sw01) 設計書

## 概要

| 項目 | 値 |
|------|-----|
| ホスト名 | sw01 |
| 機種 | FS (Cisco ライク CLI) |
| 管理 VLAN | 11 |
| 管理 IP | 192.168.11.4/24 |
| デフォルト GW | 192.168.11.1 (r3-vyos) |
| 構築時 GW | 192.168.11.254 (r1-home eth3.11) |

## ポート一覧

| ポート | 速度 | タイプ |
|--------|------|--------|
| XSGigabitEthernet 0/1 | 10G | fiber (SFP+) |
| XSGigabitEthernet 0/2 | 10G | fiber (SFP+) |
| FiveGigabitEthernet 0/1 | 5G | copper |
| FiveGigabitEthernet 0/2 | 5G | copper |
| GigabitEthernet 0/3–10 | 1G | copper |

## VLAN 定義

| VLAN ID | 名称 | 用途 |
|---------|------|------|
| 11 | mgmt | NW 機器管理、AP CAPWAP |
| 30 | staff | 運営スタッフ、配信 PC |
| 40 | user | 来場者 |

## ポートアサイン

| ポート | 接続先 | モード | VLAN | 備考 |
|--------|--------|--------|------|------|
| XSGe 0/1 | 予備 | shutdown | — | 10G fiber 予備 |
| XSGe 0/2 | r1-home eth3 (構築時) | trunk | 11,30,40 | 構築時のみ。会場では未使用 |
| 5Ge 0/1 | Proxmox onboard NIC | trunk | 11,30,40 | r3-vyos VLAN トランク (1GbE ネゴ) |
| 5Ge 0/2 | WLC (Cisco 3504) | trunk | 11,30,40 | native VLAN 11 |
| Ge 0/3–7 | AP (Aironet 3800) | access | 11 | CAPWAP、PoE 給電 |
| Ge 0/8–9 | 運営有線 | access | 30 | 配信 PC、スピーカー |
| Ge 0/10 | 予備 | shutdown | — | |

## コンフィグ

```
! ============================================================
! sw01 Configuration (FS switch, Cisco-like CLI)
! ============================================================

! --- 基本設定 ---
hostname sw01
no ip domain-lookup

! --- VLAN 定義 ---
vlan 11
 name mgmt
vlan 30
 name staff
vlan 40
 name user

! --- 管理インターフェース ---
interface vlan 11
 ip address 192.168.11.4 255.255.255.0
 no shutdown

ip default-gateway 192.168.11.1

! --- 未使用 VLAN 1 無効化 ---
interface vlan 1
 shutdown

! === Trunk ポート ===

! XSGe 0/2: r1-home eth3 SFP+ (構築時のアップリンク)
interface XSGigabitEthernet 0/2
 description Uplink-r1-home(construction)
 switchport mode trunk
 switchport trunk allowed vlan 11,30,40
 switchport trunk native vlan 11
 spanning-tree portfast trunk
 no shutdown

! 5Ge 0/1: Proxmox onboard NIC (Realtek 1GbE → 5Ge で auto-negotiate)
interface FiveGigabitEthernet 0/1
 description Trunk-Proxmox
 switchport mode trunk
 switchport trunk allowed vlan 11,30,40
 switchport trunk native vlan 11
 spanning-tree portfast trunk
 no shutdown

! 5Ge 0/2: WLC (Cisco 3504)
interface FiveGigabitEthernet 0/2
 description Trunk-WLC
 switchport mode trunk
 switchport trunk allowed vlan 11,30,40
 switchport trunk native vlan 11
 spanning-tree portfast trunk
 no shutdown

! === Access ポート ===

! Ge 0/3-7: AP (Aironet 3800) — CAPWAP、WLC が VLAN 振り分け
interface range GigabitEthernet 0/3-7
 description AP-Aironet3800
 switchport mode access
 switchport access vlan 11
 spanning-tree portfast
 no shutdown

! Ge 0/8-9: 運営有線 (配信 PC、スピーカー)
interface range GigabitEthernet 0/8-9
 description Staff-Wired
 switchport mode access
 switchport access vlan 30
 spanning-tree portfast
 no shutdown

! === 未使用ポート (shutdown) ===

interface XSGigabitEthernet 0/1
 description Reserved
 shutdown

interface GigabitEthernet 0/10
 description Reserved
 shutdown

! --- Spanning Tree ---
spanning-tree mode rapid-pvst

! --- SSH ---
ip ssh version 2
line vty 0 15
 transport input ssh
 login local

end
```

## 構築時の変更点

構築時 (自宅) は `ip default-gateway` を r1-home に向ける:

```
ip default-gateway 192.168.11.254
```

会場搬入時に戻す:

```
ip default-gateway 192.168.11.1
```

## 設計メモ

- **XSGe 0/2 を構築用に使用**: r1-home eth3 は X710-DA4 の SFP+ ポート。10G fiber 同士で接続
- **5Ge ポートに Proxmox/WLC を収容**: 1GbE 機器でも auto-negotiate で接続可能。Ge ポートを AP/有線用に確保
- **AP は access VLAN 11**: CAPWAP トンネルで WLC に集約。WLC がクライアントトラフィックを VLAN 30/40 にマッピング
- **未使用ポートは shutdown**: 誤接続防止
- **native VLAN 11**: trunk の native VLAN を mgmt に統一。管理トラフィックの untagged 通信を許可
