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

**Minisforum MS-01**

| 項目 | 仕様 |
|------|------|
| CPU | Intel Core i9-12900H (6P+8E = 14C/20T, 最大 5.0 GHz) |
| RAM | DDR4 32GB |
| ストレージ | M.2 NVMe SSD 954GB (OS) + M.2 NVMe SSD 512GB (データ保存用、旧 OptiPlex から移設) |

RAM 割り当て:

| 用途 | RAM | 備考 |
|------|-----|------|
| VyOS VM (r3) | 4GB | BGP + DNS/DHCP + Flow Accounting + wstunnel (podman) の並行処理 |
| Zabbix + Grafana VM | 8GB | Zabbix Server + DB + Grafana + Alloy (運用監視・可視化・ログ収集) |
| ローカルサーバー CT | 8GB | rsyslog, nfcapd (法執行対応ログ集約専用) |
| Proxmox ホスト | 4GB | Web UI, カーネルバッファ, I/O キャッシュ |
| **予備** | **8GB** | 追加 CT (キャプティブポータル, DNS キャッシュ等) や突発対応 |
| **合計** | **32GB** | |

ストレージ用途:
- **NVMe SSD 954GB (スロット 1)**: Proxmox OS、VM/CT のルートディスク (LVM thin pool)
- **NVMe SSD 512GB (スロット 2)**: ログ保存用データドライブ (nfcapd, rsyslog, Kea forensic log)。旧 Dell OptiPlex 3070 Micro から移設。マウント先は local-server CT に提供

### NIC 構成

MS-01 はオンボードで Intel I226-V 2.5GbE x2 および Intel X710 SFP+ 10GbE x2 を搭載する。旧 OptiPlex で課題だった USB NIC の不安定さと 1GbE トランクのボトルネックが解消された。

| NIC | Proxmox 名 | チップ | ドライバ | 速度 | Proxmox 上の扱い | 役割 |
|-----|-----------|--------|---------|------|-----------------|------|
| I226-V #1 | `nic0` | Intel I226-V | igc | 2.5GbE | ホスト側 `vmbr_wan` (bridge) → VM に virtio-net で提供 | **アップリンク** (→ blackbox) |
| I226-V #2 | `nic1` | Intel I226-V | igc | 2.5GbE | 未使用 | 予備 |
| X710 SFP+ #1 | `nic2` | Intel X710 | i40e | 10GbE | ホスト側 `vmbr_trunk` (VLAN-aware bridge) | **トランク** (→ PoE スイッチ) |
| X710 SFP+ #2 | `nic3` | Intel X710 | i40e | 10GbE | 未使用 | 予備 |
| Intel AX211 | `wlp90s0` | Intel AX211 | — | Wi-Fi 6E | 未使用 | — |

#### NIC 役割の割り当て理由

- **X710 SFP+ #1 → トランク**: 10GbE で VLAN 11/30/40 の全トラフィックを処理。i40e ドライバは安定かつ高性能。Proxmox ホストも `vmbr_trunk.11` 経由で VLAN 11 トランク上に管理 IP を持つ
- **I226-V #1 → アップリンク**: 会場の上流回線は 1GbE 未満が想定され、2.5GbE の帯域は十分。オンボード NIC であり旧設計の USB NIC のような物理的脱落リスクがない。`vmbr_wan` ブリッジに収容し、VM には virtio-net で提供する
- **nic1 / nic3 → 予備**: 障害時のフェイルオーバーや将来の拡張用に確保。現時点では未使用 (link down)

#### アップリンク NIC の接続方式: ホスト側ブリッジ + virtio-net

アップリンク NIC はホスト側で `vmbr_wan` ブリッジに収容し、VM には **virtio-net (`net3`)** で提供する。これにより:

- **vhost-net** によるカーネルレベルのゼロコピー転送で高スループットを実現
- virtio-net は GSO/GRO/TSO を安定してサポートし、multiqueue にも対応
- ホスト側ブリッジの追加 hop はサブマイクロ秒で実用上無視できる

VM conf の該当行:

```
net3: virtio=BC:24:11:76:48:AC,bridge=vmbr_wan,queues=4
```

#### ドライバに関する注意

**Intel I226-V (nic0, nic1)**: igc ドライバ。Proxmox カーネルに標準搭載。安定動作を確認済み。対向が 1GbE の場合は auto-negotiate で 1000 Mbps にフォールバックする。

**Intel X710 SFP+ (nic2, nic3)**: i40e ドライバ。Proxmox カーネルに標準搭載。SFP+ モジュールの互換性に注意（Intel 純正または DAC ケーブル推奨）。

## Proxmox 仮想ネットワーク設計

### ブリッジ構成

| ブリッジ | bridge-ports | モード | Proxmox 側 L3 | 用途 |
|---------|-------------|--------|--------------|------|
| `vmbr_trunk` | `nic2` (X710 SFP+ 10GbE) | **VLAN-aware** (`bridge-vids 2-4094`) | なし (L2 のみ) | VyOS VM / Zabbix+Grafana VM / local-server CT / Proxmox 管理 IP の VLAN トランク |
| `vmbr_trunk.11` | (親: vmbr_trunk) | tagged child (VID 11) | **`192.168.11.3/24`** (管理 IP) + gateway `192.168.11.1` | Proxmox ホスト自身の管理 IP を VLAN 11 tagged で集約 |
| `vmbr_wan` | `nic0` (I226-V 2.5GbE) | plain bridge | なし (L2 のみ) | I226-V 2.5GbE → VyOS VM の WAN アップリンク |

- **Proxmox ホストは管理 VLAN 11 にのみ参加する**。VLAN 30/40 は VyOS VM および将来の VM/CT が各自 tagged で参加する
- **スイッチの trunk `native vlan` 設定に依存しない**。全員が tagged VLAN 11 で自力参加する設計 ([`venue-switch.md`](venue-switch.md) 参照)

`/etc/network/interfaces` の実体:

```
auto lo
iface lo inet loopback

iface nic0 inet manual

iface nic1 inet manual

iface nic2 inet manual

iface nic3 inet manual

iface nic4 inet manual


source /etc/network/interfaces.d/*

# VLAN トランクブリッジ (X710 SFP+ → PoE スイッチ、VLAN 11/30/40)
auto vmbr_trunk
iface vmbr_trunk inet manual
        bridge-ports nic2
        bridge-stp off
        bridge-fd 0
        bridge-vlan-aware yes
        bridge-vids 2-4094

# Proxmox 管理 IP (VLAN 11 tagged、トランク経由)
auto vmbr_trunk.11
iface vmbr_trunk.11 inet static
        address 192.168.11.3/24
        gateway 192.168.11.1

# WAN アップリンクブリッジ (I226-V 2.5GbE → blackbox)
auto vmbr_wan
iface vmbr_wan inet manual
        bridge-ports nic0
        bridge-stp off
        bridge-fd 0
```

### ネットワークトポロジ

```
会場アップリンク (blackbox / proxy)
  │
  └─ Intel I226-V 2.5GbE (nic0, igc)
       │
       └─ vmbr_wan (plain bridge, inet manual)
            │
            └─ VyOS VM (r3-vyos)
                 ├─ eth1 (virtio net3, bridge=vmbr_wan, queues=4) → アップリンク DHCP
                 ├─ eth2 (virtio net2, bridge=vmbr_trunk, trunks=2-4094, queues=4)
                 │    ├─ eth2.11 → 192.168.11.1/24 (mgmt)
                 │    ├─ eth2.30 → 192.168.30.1/24 (staff + live)
                 │    └─ eth2.40 → 192.168.40.1/22 (user)
                 └─ [内部] wstunnel (podman) → WireGuard

Intel X710 SFP+ 10GbE (nic2, i40e)
  │
  └─ vmbr_trunk (VLAN-aware, bridge-vids 2-4094)
       ├─ tap100i2 (VyOS VM eth2, VLAN トランク透過)
       ├─ Zabbix+Grafana VM net0 bridge=vmbr_trunk,tag=11
       ├─ local-server CT net0 bridge=vmbr_trunk,tag=11
       ├─ vmbr_trunk.11 → 192.168.11.3/24 (Proxmox 管理 IP)
       │
       └─ SFP+ → PoE スイッチ → AP / 配信 PC / スピーカー
```

## VM / CT 構成

| 種別 | VMID | 名称 | OS | vCPU | RAM | ディスク | NIC | 役割 |
|------|------|------|-----|------|-----|---------|-----|------|
| VM | 100 | r3-vyos | VyOS | 4 (host) | 4GB | NVMe#1 8GB | `net2: virtio,bridge=vmbr_trunk,trunks=2-4094,queues=4` + `net3: virtio,bridge=vmbr_wan,queues=4` | ルーター、DNS/DHCP、BGP、NetFlow、wstunnel (podman) |
| CT | 200 | local-server | Debian 12 | 2 | 8GB | NVMe#1 16GB (root) + NVMe#2 マウント (データ) | `net0: name=eth0,bridge=vmbr_trunk,tag=11,ip=192.168.11.2/24,gw=192.168.11.1` | rsyslog, nfcapd (法執行対応ログ集約専用) |
| CT | 201 | zabbix-grafana | Debian 12 | 4 | 8GB | NVMe#1 32GB | `net0: name=eth0,bridge=vmbr_trunk,tag=11,ip=192.168.11.6/24,gw=192.168.11.1` | Zabbix Server + DB + Grafana + Alloy (運用監視・可視化・ログ収集) |

削除対象:

| VMID | 名称 | 理由 |
|------|------|------|
| 101 | Zabbix (旧) | Ubuntu Server + Docker Compose 構成。CT 201 で直インストールに再作成するため廃止 |
| 102 | UptimeKuma | Zabbix と機能重複、Google Chat webhook のみの用途で廃止。アラートは Zabbix に移管 |

- r3-vyos VM は `net0`/`net1` を持たない。トランクは `net2` (virtio)、アップリンクは `net3` (virtio, `vmbr_wan` 経由) に集約。両方 `queues=4` で virtio multiqueue を有効化
- `trunks=2-4094` により Proxmox は tap100i2 に VLAN 2-4094 を tagged で登録する。これが抜けていると VLAN-aware ブリッジが tagged フレームを drop する
- local-server CT (200) および zabbix-grafana CT (201) は VLAN-aware ブリッジの `tag=11` 指定で VLAN 11 に参加する

### zabbix-grafana CT の構成方針

旧 VM 101 は Ubuntu Server 上に Docker Compose (zabbix-server-mysql + zabbix-web-nginx-mysql + mysql:8.0) で構築されていた。以下の理由により、**LXC CT への直インストール**で再作成する:

- **Docker-in-LXC の複雑さ回避**: LXC 内で Docker を動かすには `nesting=1` + `keyctl` 等の特権設定が必要で、セキュリティとデバッグの観点で不利
- **リソース効率**: Docker デーモン + overlay2 のオーバーヘッドが不要になり、同一スペックでもパフォーマンスが向上
- **運用の単純化**: systemd で直接管理でき、ログも journald/syslog に統合される。Docker Compose の YAML 管理が不要
- **Zabbix agent との整合性**: Zabbix agent2 を CT 内で直接動かすことで、host メトリクスの取得が素直になる

インストール構成:

| コンポーネント | インストール方法 | 備考 |
|--------------|----------------|------|
| Zabbix Server | Zabbix 公式 APT リポジトリ | 7.0 LTS 推奨 |
| Zabbix Frontend | nginx + PHP-FPM (Zabbix 公式パッケージ) | |
| DB | MySQL 8.0 または PostgreSQL 16 | Zabbix 公式パッケージの依存に従う |
| Grafana | Grafana 公式 APT リポジトリ | OSS 版 |
| Grafana Alloy | Grafana 公式 APT リポジトリ | local-server rsyslog からログ収集 |
| Zabbix Agent2 | Zabbix 公式パッケージ | 自ホスト + 他ホスト監視用 |

### VM/CT の役割分離

運用監視と法執行対応ログを物理的に分離し、責務の混在を防ぐ。

```
[法執行対応ログ系統]
  r1/r2-gcp/r3 ──syslog/NetFlow──→ local-server (CT 200)
                                     ├─ rsyslog  → ログファイル保存 (NVMe #2)
                                     ├─ nfcapd   → NetFlow 保存 (NVMe #2)
                                     └─ rsyslog  ──forward──→ Alloy (CT 201)
                                                                ↓
                                                       Grafana で可視化

[運用監視系統]
  r1/r2/r3/スイッチ/AP ──SNMP/agent──→ Zabbix (CT 201)
                                         ↓
                                    Grafana で可視化
                                    (Zabbix datasource plugin)
```

- **local-server (CT 200)**: 法執行対応ログの**原本保管場所**。rsyslog + nfcapd でログを受信・保存し、GCS WORM バケットへ転送する。運用監視ツール (Zabbix, Grafana, SNMP Exporter 等) は配置しない
- **zabbix-grafana (CT 201)**: 運用監視の**中央ノード**。Zabbix が SNMP/agent でデバイス状態を収集し、Grafana で可視化する。Alloy が local-server の rsyslog からログを読み取り、Grafana のログダッシュボードに表示する。ログの原本はあくまで local-server 側に保持される

### リソース割り振りの根拠

- **r3-vyos (4GB, 4 vCPU, CPU host)**: WireGuard 暗号化と virtio multiqueue の割り込み処理を並列化するため 4 vCPU を割り当て。i9-12900H の AES-NI/AVX2 を活用するため CPU type は `host` を指定。BGP・DNS/DHCP・Flow Accounting・wstunnel (podman) を同時処理。10GbE トランクに移行したが WireGuard 対向 (自宅回線) がボトルネックのため旧 3 vCPU からの増分は余裕確保が主目的。RAM 4GB は現行運用で十分。ディスクは設定とログ程度のため 8GB
- **zabbix-grafana (8GB, 4 vCPU, CT 201)**: Zabbix Server + DB + Grafana + Alloy が同居する運用監視の中核 CT。旧 VM 101 (Ubuntu Server + Docker Compose) を廃止し、Debian 12 LXC CT に直インストールで再作成。200 名規模のイベントで 30 台程度のデバイス (VyOS 3 台、スイッチ、AP、Proxmox、GCE) を SNMP/agent で監視。Grafana のダッシュボードレンダリングと Alloy のログ処理に対応するため 8GB を割り当て。Docker オーバーヘッドがないため同一スペックでも VM 比で効率が良い。ディスク 32GB は Zabbix DB + Grafana データに十分
- **local-server (8GB, 2 vCPU)**: 法執行対応ログ集約専用。nfcapd (NetFlow v9 コレクタ) と rsyslog (syslog アグリゲータ) のみ稼働する軽量構成。2 vCPU で十分な処理能力。8GB RAM は rsyslog のバッファリングと nfcapd のファイル I/O キャッシュに使用。ルートディスクは 16GB (OS + ツール)、ログデータの実体は NVMe #2 (512GB) にマウントして書き込む
- **Proxmox ホスト (4GB)**: Web UI のレスポンス、カーネルバッファ、3 VM/CT の virtio I/O 処理に対応
- **予備 (8GB)**: 当日の追加 CT (キャプティブポータル、DNS キャッシュ/フィルタリング等) や、既存 VM/CT の動的拡張に使用可能

## wstunnel の役割分担

| 拠点 | 役割 | 配置 | 動作 |
|------|------|------|------|
| 自宅 | wstunnel **サーバー** | r1 配下 (192.168.10.4) | TCP 443 (WSS) で待ち受け。r1 の DNAT で外部からアクセス可能 |
| 会場 | wstunnel **クライアント** | r3 VyOS 上の podman コンテナ | WSS (TCP 443) で自宅サーバーに接続し、UDP トンネルを確立 |

wstunnel は WireGuard の UDP パケットを WebSocket (TLS) にカプセル化する。会場側は VyOS 内部の podman コンテナとして動作するため、専用 CT や内部ブリッジが不要。WireGuard は `endpoint = 127.0.0.1:51820` で wstunnel に接続し、wstunnel が eth1 (virtio, vmbr_wan 経由) で TCP 443 により自宅に到達する。プロキシ環境の場合は `--http-proxy` オプションを追加する。

## WireGuard 経路の切替

上位レイヤー (BGP, IPv6, firewall) は常に wg0 に統一されており、下位トンネルの切替のみで対応する。wstunnel 方式ではデフォルトルートの変更が不要で、WireGuard endpoint の切替のみで済む。

### WireGuard 直接接続 (プロキシ解除時)

```
r3 VyOS (wg0) → eth1 (virtio) → vmbr_wan → I226-V (nic0) → blackbox → Internet → 自宅 r1
```

- WireGuard endpoint: `<自宅グローバル IP>:51820`
- wstunnel コンテナは停止

### wstunnel 経由 (ポート制限環境時)

```
r3 VyOS (wg0 → localhost:51820) → wstunnel (podman) → eth1 (virtio) → vmbr_wan → WSS (TCP 443) → 自宅 wstunnel → r1
```

- WireGuard endpoint: `127.0.0.1:51820`
- wstunnel コンテナが eth1 (virtio, vmbr_wan 経由) で TCP 443 (WSS) により自宅に WebSocket (TLS) トンネルを確立
- **デフォルトルートの変更は不要** (wstunnel は VyOS 自身の eth1 から外に出る)

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
[Minisforum MS-01]
  ┌─────────────────────────────────────────────────┐
  │  Proxmox VE 9.1.7 (i9-12900H, 32GB, NVMe x2)  │
  │                                                  │
  │  ┌───────────────────────────────┐               │
  │  │ r3-vyos (VM 100)             │               │
  │  │  4 vCPU (host), 4GB          │               │
  │  │  eth2 (virtio, vmbr_trunk)   │               │
  │  │  eth1 (virtio, vmbr_wan)     │               │
  │  │  └─ wstunnel (podman)        │               │
  │  └───────────────────────────────┘               │
  │  ┌───────────────────────────────┐               │
  │  │ local-server (CT 200)        │               │
  │  │  2 vCPU, 8GB                 │               │
  │  │  rsyslog + nfcapd            │               │
  │  │  tag=11 → 192.168.11.2       │               │
  │  │  NVMe#2 512GB → /mnt/data    │               │
  │  └───────────────────────────────┘               │
  │  ┌───────────────────────────────┐               │
  │  │ zabbix-grafana (CT 201)      │               │
  │  │  4 vCPU, 8GB                 │               │
  │  │  Zabbix + Grafana + Alloy    │               │
  │  │  tag=11 → 192.168.11.6       │               │
  │  └───────────────────────────────┘               │
  │                                                  │
  │  NVMe#1 954GB: Proxmox OS + VM/CT root (LVM)    │
  │  NVMe#2 512GB: データ保存用 (CT 200 マウント)      │
  │                                                  │
  │  vmbr_trunk (nic2, VLAN-aware, VID 2-4094)       │
  │   └ vmbr_trunk.11 → 192.168.11.3/24              │
  │  vmbr_wan (nic0, plain bridge)                    │
  ├──────────────────────────────────────────────────┤
  │ [SFP+] X710 10GbE  (nic2) │── トランク (tagged VLAN 11/30/40) ──→ PoE スイッチ
  │ [SFP+] X710 10GbE  (nic3) │   (予備)
  │ [RJ45] I226-V 2.5GbE (nic0) │── vmbr_wan ── virtio net3 ──→ VyOS VM eth1 ──→ blackbox
  │ [RJ45] I226-V 2.5GbE (nic1) │   (予備)
  └──────────────────────────────────────────────────┘
```
