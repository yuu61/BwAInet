# 会場 Proxmox サーバー設計書

## 概要

会場側のネットワーク機能 (r3 VyOS, 監視, ログ集約) を単一の物理サーバー上の Proxmox VE で仮想化し、運搬機材を最小化する。

### 仮想化の動機

- **運搬コスト削減**: 会場に持ち込む物理サーバーを 1 台に集約
- **経路切替の柔軟性**: WireGuard 直接 / wstunnel 経由を VyOS 上で切り替え可能。物理配線の変更不要

### プロキシ回避方式

会場上流がプロキシ環境の場合、wstunnel (WebSocket トンネル) を VyOS 上の podman コンテナとして動作させる。SoftEther のような専用 CT や内部ブリッジが不要で、VyOS の設定体系に統合できる。技術調査は [`../investigation/tailscale-derp-tcp443-fallback-investigation.md`](../investigation/tailscale-derp-tcp443-fallback-investigation.md)、切替手順は [`../operations/nic2-wan-switchover.md`](../operations/nic2-wan-switchover.md) を参照。

## ハードウェア

**Minisforum MS-01** (借用機)

| 項目 | 仕様 |
|------|------|
| CPU | Intel Core i9-12900H (6P+8E = 14C/20T, 最大 5.0 GHz) |
| RAM | DDR4 32GB |
| ストレージ | M.2 NVMe SSD 954GB (OS) + M.2 NVMe SSD 512GB (データ、旧 OptiPlex から移設) |

### RAM 割り当て

| 用途 | RAM | 備考 |
|------|-----|------|
| VyOS VM (r3) | 4GB | BGP + DNS/DHCP + Flow Accounting + wstunnel |
| zabbix-grafana CT | 8GB | Zabbix + DB + Grafana + Alloy |
| local-server CT | 8GB | rsyslog + nfcapd (法執行対応専用) |
| Proxmox ホスト | 4GB | Web UI, カーネルバッファ, I/O キャッシュ |
| 予備 | 8GB | 追加 CT や突発対応 |
| **合計** | **32GB** | |

### ストレージ

- **NVMe #1 (954GB)**: Proxmox OS、VM/CT ルートディスク (LVM thin pool)
- **NVMe #2 (512GB)**: ログ保存用。旧 OptiPlex 3070 Micro から移設。local-server CT にマウント (`/mnt/data`)

### NIC 構成

| NIC | Proxmox 名 | チップ | 速度 | 役割 |
|-----|-----------|--------|------|------|
| I226-V #1 | nic0 | Intel I226-V (igc) | 2.5GbE | 予備 |
| I226-V #2 | nic1 | Intel I226-V (igc) | 2.5GbE | 予備 |
| X710 SFP+ #1 | nic2 | Intel X710 (i40e) | 10GbE | トランク → PoE スイッチ |
| X710 SFP+ #2 | nic3 | Intel X710 (i40e) | 10GbE | アップリンク → blackbox / 自宅 r1 |

旧 OptiPlex で課題だった USB NIC の不安定さと 1GbE トランクのボトルネックは解消済み。

#### 役割選択の理由

- **nic2 (トランク)**: 10GbE で VLAN 11/30/40 の全トラフィック。Proxmox ホスト自身も `vmbr_trunk.11` 経由で VLAN 11 tagged で管理 IP を持つ
- **nic3 (WAN)**: i226-V 2.5GbE から移行。WG トンネル越しの単方向スループットが nic0 (igc) では ~900 Mbps で頭打ちだったが、nic3 (i40e 10G SFP+) + FW 9.56 で Linux↔Linux TCP 単フロー 1.22 Gbps / 並列 4 フロー 5.4 Gbps / bidir aggregate 5.15 Gbps に拡張。i40e の IRQ 分散 (最大 20 queues) と adaptive coalescing が高 BDP で有利

実測詳細は [`../investigation/wg-throughput-measurement.md`](../investigation/wg-throughput-measurement.md) を参照。

#### ドライバと FW 要件

i40e は Proxmox カーネル標準搭載。**FW 9.56 以上を推奨** — 9.20 以下では libie の MAC フィルタ追加時に `LIBIE_AQ_RC_ENOSPC` エラー → overflow promiscuous モードへ遷移してブリッジ経由 TX 性能が著しく劣化する。FW 更新 + i40e チューニング (ring 4096, ntuple off) の手順は [`../operations/nic-firmware-update.md`](../operations/nic-firmware-update.md) を参照。

#### アップリンク NIC: ホスト側ブリッジ + virtio-net

`vmbr_wan` ブリッジに収容し、VM には virtio-net (`net3`) で提供:

- vhost-net によるカーネルレベルのゼロコピー転送で高スループット
- virtio-net は GSO/GRO/TSO 安定対応、multiqueue (queues=4) 対応
- ホスト側ブリッジの追加 hop はサブマイクロ秒で無視できる

## Proxmox 仮想ネットワーク

### ブリッジ構成

| ブリッジ | bridge-ports | モード | L3 (Proxmox) | 用途 |
|---------|-------------|--------|--------------|------|
| `vmbr_trunk` | nic2 | VLAN-aware (vids 2-4094) | なし (L2 のみ) | VyOS / CT / Proxmox 管理 IP のトランク |
| `vmbr_trunk.11` | (親 vmbr_trunk) | tagged child (VID 11) | **192.168.11.3/24** + gw 192.168.11.1 | Proxmox ホスト自身の管理 IP |
| `vmbr_wan` | nic3 | plain bridge | なし | X710 SFP+ → VyOS VM の WAN |

**Proxmox ホストは VLAN 11 にのみ参加する**。VLAN 30/40 は VyOS VM および将来の VM/CT が各自 tagged で参加する設計 (全員 tagged 自力参加 — [`venue-switch.md`](venue-switch.md) §6 参照)。

### ネットワークトポロジ

```
会場アップリンク (blackbox / proxy) / 自宅 r1 eth3 (10G SFP+)
  └─ X710 SFP+ #2 (nic3) → vmbr_wan (plain bridge)
       └─ VyOS VM eth1 (virtio net3, queues=4)

X710 SFP+ #1 (nic2) → vmbr_trunk (VLAN-aware, VID 2-4094)
  ├─ VyOS VM eth2 (virtio net2, trunks=2-4094, queues=4)
  │    ├─ eth2.11 → 192.168.11.1/24 (mgmt)
  │    ├─ eth2.30 → 192.168.30.1/24 (staff+live)
  │    └─ eth2.40 → 192.168.40.1/22 (user)
  ├─ zabbix-grafana CT (tag=11, 192.168.11.6)
  ├─ local-server CT (tag=11, 192.168.11.2)
  ├─ vmbr_trunk.11 → 192.168.11.3/24 (Proxmox 管理)
  └─ SFP+ → PoE スイッチ → AP / 配信 PC / スピーカー
```

## VM / CT 構成

| 種別 | VMID | 名称 | OS | vCPU | RAM | ディスク | 役割 |
|------|------|------|-----|------|-----|---------|------|
| VM | 100 | r3-vyos | VyOS | 4 (host, affinity 0-11) | 4GB | NVMe#1 8GB | ルーター、DNS/DHCP、BGP、NetFlow、wstunnel |
| CT | 200 | local-server | Debian 12 | 2 | 8GB | NVMe#1 16GB + NVMe#2 mount | rsyslog + nfcapd (法執行対応) |
| CT | 201 | zabbix-grafana | Debian 12 | 4 | 8GB | NVMe#1 32GB | Zabbix + DB + Grafana + Alloy |

削除済み: VM 101 (旧 Zabbix Docker Compose), VM 102 (UptimeKuma)。

### r3-vyos の CPU アフィニティ

i9-12900H ハイブリッド構成で `affinity: 0-11` を設定し P-core (6P×2HT=12 論理) に限定、E-core (CPU 12-19, 3.8GHz) へのスケジュールを防止する。WG 暗号化 workqueue の E-core migration を抑止し安定したスループットを確保。`numa: 1` / `agent: 1` (qemu-guest-agent) 併用。

### zabbix-grafana の LXC 直インストール方針

旧 VM 101 は Ubuntu + Docker Compose 構成だったが、以下の理由で Debian 12 LXC CT への直インストールに再作成:

- Docker-in-LXC の `nesting=1` + `keyctl` 特権を回避 (セキュリティ・デバッグ)
- Docker デーモン + overlay2 オーバーヘッドを削減 (同一スペックで性能向上)
- systemd 直管理、journald/syslog 統合 (運用単純化)
- Zabbix agent2 をホスト監視と素直に統合

### 役割分離 (運用監視 vs 法執行対応ログ)

```
[法執行対応ログ系統]
  r1/r2-gcp/r3 ──syslog/NetFlow──→ local-server (CT 200)
                                     ├─ rsyslog  → ログ保存 (NVMe #2)
                                     ├─ nfcapd   → NetFlow 保存 (NVMe #2)
                                     └─ rsyslog  ──forward──→ Alloy (CT 201) → Grafana

[運用監視系統]
  r1/r2/r3/スイッチ/AP ──SNMP/agent──→ Zabbix (CT 201) → Grafana
```

- **local-server (CT 200)**: 法執行対応ログの**原本保管場所**。運用監視ツールは配置しない
- **zabbix-grafana (CT 201)**: 運用監視の中央ノード。ログの原本は local-server 側に保持、Alloy は読み取り専用経路

詳細は [`logging-compliance.md`](logging-compliance.md) を参照。

## wstunnel (ポート制限環境時)

| 拠点 | 役割 | 配置 |
|------|------|------|
| 自宅 | wstunnel **サーバー** | r1 配下 (192.168.10.4, DNAT 経由) |
| 会場 | wstunnel **クライアント** | r3 VyOS 上の podman コンテナ |

上位レイヤー (BGP, IPv6, firewall) は常に wg0 に統一。WG 直接 / wstunnel 経由の切替手順は [`../operations/nic2-wan-switchover.md`](../operations/nic2-wan-switchover.md) を参照。

## 性能測定結果

**結論サマリ**: Linux↔Linux で TCP 並列 4 stream 約 5 Gbps、bidir aggregate 約 5.15 Gbps を達成。200 名規模の同時利用に対し r3/r1 共に十分な余裕。Windows 単フロー TX のみ約 240 Mbps と OS 制約あり (並列接続では問題なし)。

実測値・計測手順は [`../investigation/wg-throughput-measurement.md`](../investigation/wg-throughput-measurement.md) を参照。

## venue 返却制約 (借用機)

MS-01 は借用品。イベント後のフロー:

1. 会場で予備封印 → 電源オフ ([`../operations/log-sealing.md`](../operations/log-sealing.md))
2. 自宅ラボへ物理搬送
3. 起動し GCS への転送完了を確認
4. 転送完了確認後に初期化 (ディスクワイプ)
5. 借用元へ返送

**初期化は GCS 転送完了確認が取れるまで行わない**。初期化後はローカルデータが不可逆に失われる。

## 関連

- [`../configs/r3-venue.conf`](../configs/r3-venue.conf) — r3-vyos 投入コマンド
- [`../operations/nic-firmware-update.md`](../operations/nic-firmware-update.md) — FW 更新と i40e チューニング
- [`../operations/nic2-wan-switchover.md`](../operations/nic2-wan-switchover.md) — WG / wstunnel 切替
- [`../operations/log-sealing.md`](../operations/log-sealing.md) — 封印・GCS 転送・ディスクワイプ手順
- [`../investigation/wg-throughput-measurement.md`](../investigation/wg-throughput-measurement.md) — 実測値
