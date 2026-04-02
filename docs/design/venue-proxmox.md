# 会場 Proxmox サーバー設計書

## 概要

会場側のネットワーク機能 (r3 VyOS, SoftEther, ローカルサーバー) を単一の物理サーバー上の Proxmox VE で仮想化し、運搬する機材数を最小化する。

### 仮想化の動機

- **運搬コスト削減**: 会場に持ち込む物理サーバーを 1 台に集約
- **SoftEther 配置の制約**: 会場 (発信側) では VyOS の**前段**に SoftEther を置く必要がある。自宅 (受信側) は r1 配下に SoftEther サーバーを置けるが、会場側は SoftEther クライアントがプロキシを経由して外部に接続を発信するため、VyOS のアップリンク経路上に SoftEther が位置しなければならない
- **経路切替の柔軟性**: WireGuard 直接接続 / SoftEther 経由を仮想ネットワーク上で切り替え可能。物理配線の変更不要

## ハードウェア

### 本体

**Dell OptiPlex 3070 Micro**

| 項目 | 仕様 |
|------|------|
| CPU | Intel Core i5-9500T (6C/6T) |
| RAM | DDR4 32GB |
| ストレージ | M.2 NVMe SSD 512GB + HDD 1TB |
| フォームファクタ | Micro (約 182 × 178 × 36 mm) |

RAM 目安: VyOS VM 4GB + SoftEther CT 512MB + ローカルサーバー CT 8GB + Proxmox ホスト 2GB = 約 14.5GB。32GB あるため余裕は十分。

ストレージ用途:
- **NVMe SSD 512GB**: Proxmox OS、VM/CT のルートディスク
- **HDD 1TB**: ログ保存 (rsyslog, nfcapd)、Grafana データなど長期保存用

### NIC 構成

| NIC | チップ | 速度 | 接続 | 役割 |
|-----|--------|------|------|------|
| オンボード | Realtek RTL8111H | 1GbE | 内蔵 | **トランク** (→ PoE スイッチ) |
| 外付け | USB 2.5GbE | 2.5GbE | USB 3.0 | **アップリンク** (→ blackbox) |

#### NIC 役割の割り当て理由

- **オンボード → トランク**: 物理的に安定。VLAN 11/30/40 の全トラフィックを担う。オンボード NIC の脱落リスクはゼロ
- **USB NIC → アップリンク**: 会場の上流回線は 1GbE 未満が想定され、2.5GbE の帯域は不要。万一 USB NIC が抜けても会場内 LAN (DHCP/DNS/VLAN 間通信) は維持される

#### USB NIC の物理固定

USB NIC はテープで固縛し、物理的な抜け落ちを防止する。

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

**USB 2.5GbE NIC**:

`udev` ルールでインターフェース名を固定し、再起動時の名前変動を防ぐ。

```bash
# /etc/udev/rules.d/70-persistent-net.rules
SUBSYSTEM=="net", ACTION=="add", ATTR{address}=="<USB NIC MAC>", NAME="enxusb0"
```

推奨チップ: RTL8156B 系 (r8152 ドライバ) または AX88179A — いずれも Proxmox で安定動作。

## Proxmox 仮想ネットワーク設計

### ブリッジ構成

| ブリッジ | 接続先 | 用途 |
|---------|--------|------|
| vmbr0 | USB NIC (アップリンク) | 会場上流 (blackbox) への接続 |
| vmbr1 | (内部ブリッジ、物理 NIC なし) | SoftEther ↔ VyOS 間のトンネル経路 |
| vmbr_trunk | オンボード NIC (Realtek) | VyOS → PoE スイッチ (VLAN トランク) |

### ネットワークトポロジ

```
会場アップリンク (blackbox / proxy)
  │
  └─ vmbr0 [USB NIC]
       │
       ├─ SoftEther CT ← プロキシ CONNECT 経由で自宅 SoftEther サーバーへ接続
       │    └─ tap → vmbr1 (内部ブリッジ)
       │
       └─ VyOS VM (r3)
            ├─ eth0 → vmbr0 (WG 直接時のアップリンク)
            ├─ eth1 → vmbr1 (SoftEther 経由時のアップリンク)
            └─ eth2 → vmbr_trunk (VLAN 11/30/40 トランク)

  vmbr_trunk [オンボード NIC]
       │
       └─ PoE スイッチ → AP / 配信 PC / スピーカー

  vmbr1 or vmbr_trunk (native VLAN 11)
       │
       └─ ローカルサーバー CT
            └─ Grafana, rsyslog, nfcapd, SNMP Exporter
```

## VM / CT 構成

| 種別 | 名称 | OS | vCPU | RAM | ディスク | NIC | 役割 |
|------|------|-----|------|-----|---------|-----|------|
| VM | r3-vyos | VyOS | 2 | 4GB | SSD 8GB | eth0 (vmbr0), eth1 (vmbr1), eth2 (vmbr_trunk) | ルーター、DNS/DHCP、BGP、NetFlow |
| CT | softether | Debian / Alpine | 1 | 512MB | SSD 4GB | eth0 (vmbr0), tap→vmbr1 | SoftEther クライアント、プロキシ経由トンネル |
| CT | local-srv | Debian | 2 | 8GB | SSD 32GB + HDD 1TB マウント | eth0 (vmbr_trunk, VLAN 11) | Grafana, rsyslog, nfcapd, SNMP Exporter |

### リソース割り振りの根拠

- **r3-vyos**: VyOS 自体は軽量だが、BGP・DNS/DHCP・Flow Accounting を同時処理するため RAM 4GB を確保。ディスクは設定とログ程度なので 8GB で十分
- **softether**: トンネル維持のみの最小構成。LXC コンテナのためオーバーヘッドも小さい
- **local-srv**: Grafana + rsyslog + nfcapd + SNMP Exporter が同居するため最もリソースを消費。RAM 8GB は Grafana のダッシュボード描画と nfcapd のフローデータ処理に必要。HDD 1TB を `/var/log` や nfcapd データディレクトリにマウントし長期保存に使用
- **残余リソース**: RAM 約 17GB、SSD 約 450GB が空き。追加の CT (監視系等) にも対応可能

## SoftEther の役割分担

| 拠点 | 役割 | 配置 | 動作 |
|------|------|------|------|
| 自宅 | SoftEther **サーバー** | r1 配下 (192.168.10.4 等) | TCP 443 で待ち受け。r1 の DNAT で外部からアクセス可能 |
| 会場 | SoftEther **クライアント** | Proxmox 上の CT | プロキシ (HTTP CONNECT) 経由で自宅サーバーに接続し、L2 トンネルを確立 |

自宅は受信側のため、SoftEther サーバーを r1 配下の任意のホストに配置できる。会場は発信側であり、SoftEther クライアントがプロキシを通過して外部に接続を開始する必要があるため、VyOS (r3) の前段 (アップリンク側) に配置する。

## WireGuard 経路の切替

上位レイヤー (BGP, IPv6, firewall) は常に wg0 に統一されており、下位トンネルの切替のみで対応する。

### WireGuard 直接接続 (プロキシ解除時)

```
r3 VyOS (wg0) → eth0 (vmbr0) → USB NIC → blackbox → Internet → 自宅 r1
```

- r3 のデフォルトルートを vmbr0 (blackbox) に向ける
- WireGuard endpoint: `<自宅グローバル IP>:51820`
- SoftEther CT は起動不要

### SoftEther 経由 (プロキシ環境時)

```
r3 VyOS (wg0) → eth1 (vmbr1) → SoftEther CT → eth0 (vmbr0) → proxy CONNECT → 自宅 SoftEther → r1
```

- r3 のデフォルトルートを vmbr1 (SoftEther トンネル) に向ける
- WireGuard endpoint: `<SoftEther tap 対向 IP>:51820`
- SoftEther CT がプロキシ経由で自宅に HTTPS トンネルを確立

### 切替手順

```bash
# WG 直接 → SoftEther 経由に切り替え
# 1. SoftEther CT を起動し、トンネル確立を確認
# 2. r3 VyOS でデフォルトルートを変更
set protocols static route 0.0.0.0/0 next-hop <vmbr1 側 GW>
delete protocols static route 0.0.0.0/0 next-hop <vmbr0 側 GW>
commit

# 3. WireGuard endpoint を変更
set interfaces wireguard wg0 peer r1 endpoint '<SoftEther tap 対向 IP>:51820'
commit
```

## 物理構成図

```
[Dell OptiPlex 3070 Micro]
  ┌──────────────────────────────┐
  │  Proxmox VE                  │
  │  ┌─────────┐ ┌───────────┐  │
  │  │ r3-vyos │ │ softether │  │
  │  │  (VM)   │ │   (CT)    │  │
  │  └─────────┘ └───────────┘  │
  │  ┌───────────┐               │
  │  │ local-srv │               │
  │  │   (CT)    │               │
  │  └───────────┘               │
  ├──────────────────────────────┤
  │ [RJ45] Realtek RTL8111H     │──── トランク ──→ PoE スイッチ
  │ [USB]  2.5GbE NIC (テープ固縛)│──── アップリンク ──→ blackbox
  └──────────────────────────────┘
```
