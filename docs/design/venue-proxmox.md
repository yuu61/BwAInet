# 会場 Proxmox サーバー設計書

## 概要

会場側のネットワーク機能 (r3 VyOS, ローカルサーバー) を単一の物理サーバー上の Proxmox VE で仮想化し、運搬する機材数を最小化する。

### 仮想化の動機

- **運搬コスト削減**: 会場に持ち込む物理サーバーを 1 台に集約
- **経路切替の柔軟性**: WireGuard 直接接続 / wstunnel 経由を VyOS 上で切り替え可能。物理配線の変更不要

### プロキシ回避方式

会場上流がプロキシ環境の場合、wstunnel (WebSocket トンネル) を VyOS 上の podman コンテナとして動作させる。wstunnel は WireGuard の UDP パケットを WebSocket (TLS over TCP 443) にカプセル化し、HTTP CONNECT プロキシを透過する。SoftEther のような専用 CT や内部ブリッジが不要で、VyOS の設定体系に統合できる。

技術調査の詳細は [`../investigation/tailscale-derp-tcp443-fallback-investigation.md`](../investigation/tailscale-derp-tcp443-fallback-investigation.md) を参照。

## ハードウェア

### 本体

**Dell OptiPlex 3070 Micro**

| 項目 | 仕様 |
|------|------|
| CPU | Intel Core i5-9500T (6C/6T) |
| RAM | DDR4 32GB |
| ストレージ | M.2 NVMe SSD 512GB + HDD 1TB |

RAM 割り当て:
.
| 用途 | RAM | 備考 |
|------|-----|------|
| VyOS VM (r3) | 6GB | BGP + DNS/DHCP + Flow Accounting + wstunnel (podman) の並行処理 |
| ローカルサーバー CT | 16GB | Grafana, rsyslog, nfcapd, SNMP Exporter (200名規模対応) |
| Proxmox ホスト | 3GB | Web UI, カーネル, ZFS ARC |
| **予備** | **7GB** | 追加 CT (キャプティブポータル, DNS キャッシュ等) や突発対応 |
| **合計** | **32GB** | |

※ wstunnel は VyOS の podman コンテナとして動作するため、SoftEther CT (旧設計: 1GB) は不要。予備 RAM が 1GB 増加。

ストレージ用途:
- **NVMe SSD 512GB**: Proxmox OS、VM/CT のルートディスク
- **HDD 1TB**: ログ保存 (rsyslog, nfcapd)、Grafana データなど長期保存用

### NIC 構成

| NIC | チップ | ドライバ | 速度 | Proxmox 上の扱い | 役割 |
|-----|--------|---------|------|-----------------|------|
| オンボード | Realtek RTL8168H | r8169 | 1GbE | ホスト側 `nic0` → `vmbr_trunk` (VLAN-aware bridge) | **トランク** (→ PoE スイッチ) |
| 外付け | Realtek RTL8156B USB 2.5GbE | r8152 (ゲスト側) | 2.5GbE | **VyOS VM に USB host passthrough** (`usb0: host=0bda:8156,usb3=1`) | **アップリンク** (→ blackbox) |

#### NIC 役割の割り当て理由

- **オンボード → トランク**: 物理的に安定。VLAN 11/30/40 の全トラフィックを担う。オンボード NIC の脱落リスクはゼロ。Proxmox ホストも `vmbr_trunk.11` 経由で同じ VLAN 11 トランク上に管理 IP を持つ
- **USB NIC → アップリンク**: 会場の上流回線は 1GbE 未満が想定され、2.5GbE の帯域は不要。万一 USB NIC が抜けても会場内 LAN (DHCP/DNS/VLAN 間通信) は維持される。Proxmox ホストは USB NIC を touch しない (passthrough 対象) ため、ホスト側から `nic1` としては見えない

#### USB passthrough の方針

USB NIC は Proxmox ホストでブリッジに収容せず、**qemu の USB host passthrough で VyOS VM に直接渡す**。これにより:

- VyOS 内で `eth3` (hw-id `00:e0:4c:92:ee:41`) として直接認識される
- ホスト側ブリッジ (`vmbr0` 等) を経由しないため中間 L2 が 1 段減る
- 旧設計 (`vmbr0` に USB NIC を bridge-ports として収容) で発生していた dhclient や apparmor の重複取得を回避

VM conf の該当行:

```
usb0: host=0bda:8156,usb3=1
```

USB NIC はテープで物理的に固縛し、抜け落ちを防止する。

#### ドライバに関する注意

**Realtek RTL8111H (オンボード)**:

Proxmox (Debian カーネル) では `r8169` ドライバで認識されることが多い。不安定な場合は `r8168` DKMS パッケージを導入する。

```bash
# ドライバ確認
ethtool -i <interface> | grep driver

# r8169 で不安定な場合
apt install pve-headers-$(uname -r)
apt install r8168-dkms
```

**USB 2.5GbE NIC (Realtek RTL8156B)**:

Proxmox ホスト側ではブリッジ収容せず USB host passthrough にするため、ホスト側で `udev` による名前固定は不要。ゲスト (VyOS) 側では `hw-id '00:e0:4c:92:ee:41'` を config で指定してインターフェース命名を固定する ([`venue-vyos.md`](venue-vyos.md) 参照)。実機確認済み: RTL8156B (r8152 ドライバ, FW: rtl8156b-2 v3)。

## Proxmox 仮想ネットワーク設計

### ブリッジ構成

| ブリッジ | bridge-ports | モード | Proxmox 側 L3 | 用途 |
|---------|-------------|--------|--------------|------|
| `vmbr_trunk` | `nic0` | **VLAN-aware** (`bridge-vids 2-4094`) | なし (L2 のみ) | VyOS VM / local-srv CT / Proxmox 管理 IP の VLAN トランク |
| `vmbr_trunk.11` | (親: vmbr_trunk) | tagged child (VID 11) | **`192.168.11.3/24`** (管理 IP) + gateway `192.168.11.1` | Proxmox ホスト自身の管理 IP を VLAN 11 tagged で集約 |

- 旧設計の `vmbr0` (USB NIC のアップリンクブリッジ) は USB passthrough 化により廃止
- 旧設計の `vmbr1` (SoftEther ↔ VyOS 間の内部ブリッジ) は wstunnel 移行により廃止
- USB NIC は Proxmox ホストで掴まず、VM に USB host passthrough で直接渡す
- **Proxmox ホストは管理 VLAN 11 にのみ参加する**。VLAN 30/40 は VyOS VM および将来の VM/CT が各自 tagged で参加する
- **スイッチの trunk `native vlan` 設定に依存しない**。全員が tagged VLAN 11 で自力参加する設計 ([`venue-switch.md`](venue-switch.md) 参照)

`/etc/network/interfaces` の実体:

```
auto lo
iface lo inet loopback

iface nic0 inet manual

# VLAN-aware トランクブリッジ (管理 IP は持たない)
auto vmbr_trunk
iface vmbr_trunk inet manual
        bridge-ports nic0
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware yes
        bridge-vids 2-4094

# Proxmox 管理 IP (VLAN 11 tagged で統一)
auto vmbr_trunk.11
iface vmbr_trunk.11 inet static
        address 192.168.11.3/24
        gateway 192.168.11.1

source /etc/network/interfaces.d/*
```

### ネットワークトポロジ

```
会場アップリンク (blackbox / proxy)
  │
  └─ USB 2.5GbE NIC (usb0 passthrough)
       │
       └─ VyOS VM (r3-vyos)
            ├─ eth3 (USB NIC 直結, hw-id 00:e0:4c:92:ee:41) → アップリンク DHCP
            ├─ eth2 (virtio net2, bridge=vmbr_trunk, trunks=2-4094)
            │    ├─ eth2.11 → 192.168.11.1/24 (mgmt)
            │    ├─ eth2.30 → 192.168.30.1/24 (staff + live)
            │    └─ eth2.40 → 192.168.40.1/22 (user)
            └─ [内部] wstunnel (podman) → WireGuard

オンボード NIC (nic0)
  │
  └─ vmbr_trunk (VLAN-aware, bridge-vids 2-4094)
       ├─ tap100i2 (VyOS VM eth2, VLAN トランク透過)
       ├─ vmbr_trunk.11 → 192.168.11.3/24 (Proxmox 管理 IP)
       └─ (将来) local-srv CT net0 bridge=vmbr_trunk,tag=11
       │
       └─ オンボード NIC → PoE スイッチ → AP / WLC / 配信 PC / スピーカー
```

## VM / CT 構成

| 種別 | 名称 | OS | vCPU | RAM | ディスク | NIC / passthrough | 役割 |
|------|------|-----|------|-----|---------|-------------------|------|
| VM | r3-vyos | VyOS | 2 | 6GB | SSD 8GB | `net2: virtio=BC:24:11:EA:46:88,bridge=vmbr_trunk,trunks=2-4094` + `usb0: host=0bda:8156,usb3=1` | ルーター、DNS/DHCP、BGP、NetFlow、wstunnel (podman) |
| CT | local-srv | Debian | 4 | 16GB | SSD 32GB + HDD 1TB マウント | `net0: bridge=vmbr_trunk,tag=11` (VLAN 11) | Grafana, rsyslog, nfcapd, SNMP Exporter |

- r3-vyos VM は `net0`/`net1` を持たない。トランクは `net2` (virtio) に集約し、アップリンクは `usb0` で USB NIC を直接渡す
- `trunks=2-4094` により Proxmox は tap100i2 に VLAN 2-4094 を tagged で登録する。これが抜けていると VLAN-aware ブリッジが tagged フレームを drop する
- local-srv CT は VLAN-aware ブリッジの機能で `tag=11` を指定するだけで VLAN 11 tagged 子ポートに自動参加する

### リソース割り振りの根拠

- **r3-vyos (6GB, 2 vCPU)**: VyOS 自体は軽量だが、BGP・DNS/DHCP・Flow Accounting を同時処理するため RAM 6GB を確保。200名規模の DNS クエリと NetFlow 生成を余裕をもって処理。wstunnel は podman コンテナとして動作し、メモリ消費は数十 MB 程度で VyOS の 6GB 内に十分収まる。ディスクは設定とログ程度なので 8GB で十分
- **local-srv (16GB, 4 vCPU)**: Grafana + rsyslog + nfcapd + SNMP Exporter が同居し、最もリソースを消費。200名・100台以上のデバイスからの NetFlow v9 データのリアルタイム集計、Grafana の複数ダッシュボード同時描画、rsyslog の高スループット書き込みに対応。vCPU も 4 に増強し並列処理能力を確保。HDD 1TB を `/var/log` や nfcapd データディレクトリにマウントし長期保存に使用
- **Proxmox ホスト (3GB)**: Web UI のレスポンス向上とカーネルバッファに余裕を持たせる
- **予備 (7GB)**: 当日の追加 CT (キャプティブポータル、DNS キャッシュ/フィルタリング等) や、既存 CT の動的拡張に使用可能。旧設計の SoftEther CT (1GB) 廃止分が上乗せ

## wstunnel の役割分担

| 拠点 | 役割 | 配置 | 動作 |
|------|------|------|------|
| 自宅 | wstunnel **サーバー** | r1 配下 (192.168.10.4) | TCP 443 (WSS) で待ち受け。r1 の DNAT で外部からアクセス可能 |
| 会場 | wstunnel **クライアント** | r3 VyOS 上の podman コンテナ | WSS (TCP 443) で自宅サーバーに接続し、UDP トンネルを確立 |

wstunnel は WireGuard の UDP パケットを WebSocket (TLS) にカプセル化する。会場側は VyOS 内部の podman コンテナとして動作するため、専用 CT や内部ブリッジが不要。WireGuard は `endpoint = 127.0.0.1:51820` で wstunnel に接続し、wstunnel が eth3 (USB passthrough) 経由で TCP 443 により自宅に到達する。プロキシ環境の場合は `--http-proxy` オプションを追加する。

## WireGuard 経路の切替

上位レイヤー (BGP, IPv6, firewall) は常に wg0 に統一されており、下位トンネルの切替のみで対応する。wstunnel 方式ではデフォルトルートの変更が不要で、WireGuard endpoint の切替のみで済む。

### WireGuard 直接接続 (プロキシ解除時)

```
r3 VyOS (wg0) → eth3 (USB passthrough) → USB NIC → blackbox → Internet → 自宅 r1
```

- WireGuard endpoint: `<自宅グローバル IP>:51820`
- wstunnel コンテナは停止

### wstunnel 経由 (ポート制限環境時)

```
r3 VyOS (wg0 → localhost:51820) → wstunnel (podman) → eth3 (USB passthrough) → WSS (TCP 443) → 自宅 wstunnel → r1
```

- WireGuard endpoint: `127.0.0.1:51820`
- wstunnel コンテナが eth3 (USB passthrough) 経由で TCP 443 (WSS) により自宅に WebSocket (TLS) トンネルを確立
- **デフォルトルートの変更は不要** (wstunnel は VyOS 自身の eth3 から外に出る)

### 切替手順

```bash
# WG 直接 → wstunnel 経由に切り替え
# 1. wstunnel コンテナを起動 (VyOS CLI で設定済みの場合は restart)
restart container wstunnel

# 2. WireGuard endpoint を変更
set interfaces wireguard wg0 peer r1 endpoint '127.0.0.1:51820'
commit

# wstunnel 経由 → WG 直接に切り替え
# 1. WireGuard endpoint を変更
set interfaces wireguard wg0 peer r1 endpoint '<自宅グローバルIP>:51820'
commit

# 2. wstunnel コンテナを停止 (任意)
stop container wstunnel
```

## 物理構成図

```
[Dell OptiPlex 3070 Micro]
  ┌────────────────────────────────────────┐
  │  Proxmox VE                            │
  │  ┌──────────────────────────────┐      │
  │  │ r3-vyos (VM)                 │      │
  │  │  eth2 (virtio, vmbr_trunk)   │      │
  │  │  eth3 (USB passthrough)      │      │
  │  │  └─ wstunnel (podman)        │      │
  │  └──────────────────────────────┘      │
  │  ┌──────────────────────────────┐      │
  │  │ local-srv (CT)               │      │
  │  │  net0 bridge=vmbr_trunk,tag=11│     │
  │  └──────────────────────────────┘      │
  │  vmbr_trunk (VLAN-aware, VID 2-4094)   │
  │   └ vmbr_trunk.11 → 192.168.11.3/24    │
  ├────────────────────────────────────────┤
  │ [RJ45] Realtek RTL8111H (nic0)        │──── トランク (tagged VLAN 11/30/40) ──→ PoE スイッチ
  │ [USB]  2.5GbE NIC (テープ固縛)         │══ USB host passthrough ══→ VyOS VM eth3 ──→ blackbox
  └────────────────────────────────────────┘
```
