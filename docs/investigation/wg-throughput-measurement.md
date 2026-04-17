# WireGuard トンネル スループット実測

FW 9.56 + X710 SFP+ (nic3) + 全チューニング (CPU affinity、virtio multiqueue、sysctl、i40e ring buffer、WG offload) 投入後の実測値。自宅検証環境 (r1 eth3 ↔ r3 nic3 直結 10G SFP+ DAC) で測定。

会場 Proxmox / venue-vyos の設計判断 (NIC 割当、リソース配分等) の裏付け資料。設計判断本体は [`../design/venue-proxmox.md`](../design/venue-proxmox.md), [`../design/venue-vyos.md`](../design/venue-vyos.md) を参照。

## r3 ↔ r1 間 WG トンネル越し (Linux ↔ Linux, iperf3)

**これが r3/r1 infrastructure の真の path capacity**。WG 暗号化・復号を両端で行う最も重い条件。

| テスト | Bitrate |
|--------|---------|
| TCP 単方向 1 stream (TX) | **1.22 Gbps** |
| TCP 単方向 1 stream (RX) | **1.31 Gbps** |
| UDP 単方向 1 stream (TX, receiver) | **3.34 Gbps** (16% loss、path capacity 示す) |
| UDP 単方向 1 stream (RX) | **2.90 Gbps** (loss 0.074%) |
| TCP 並列 4 stream (TX) | **4.91 Gbps** |
| TCP 並列 4 stream (RX) | **5.40 Gbps** |
| TCP bidir 1 stream | **TX 1.74 / RX 1.95 Gbps** (aggregate 3.69 Gbps) |
| TCP bidir 並列 4 stream | **TX 3.72 / RX 1.43 Gbps** (aggregate 5.15 Gbps) |

## Windows client (192.168.11.40) ↔ 自宅 iperf サーバ (r1 LAN の main PC)

Windows TCP stack が単フロー TX で深刻に制約される (典型的な OS 起因の既知挙動)。**Linux ↔ Linux の数値が真のインフラ性能**、Windows 数値は Windows client のワーストケース参考値。

| テスト | Windows client | 参考: Linux ↔ Linux |
|--------|---------------|-------------------|
| TCP 単方向 TX | 238 Mbps | 1.22 Gbps (5.1x) |
| TCP 単方向 RX | 1.64 Gbps | 1.31 Gbps |
| UDP 単方向 TX (receiver) | 1.72 Gbps | 3.34 Gbps |
| TCP 並列 4 TX | 551 Mbps | 4.91 Gbps (9x) |
| TCP bidir 1 TX | 139 Mbps | 1.74 Gbps (12.5x) |

## 実運用への含意

- **200 名規模の同時利用**: 多様な OS・多数の TCP フローが混在するため、Linux ↔ Linux ベンチに近い **5 Gbps 級の aggregate** を期待できる。r3/r1 は十分な余裕を持つ
- **単一 Windows 端末の heavy upload**: Windows TCP 単フロー TX ~240 Mbps が worst case。並列ダウンロード (Steam, ブラウザ多数接続) では問題なし
- **r3 側の CPU 使用率**: bidir -P 4 時で 40-50% (4 vCPU aggregate)。CPU が飽和する前に NIC/client 側が先に頭打ち

## 計測手順

```bash
# r1 側 (server) で iperf3 待受起動
ssh r1-home "sudo iperf3 -s -D"

# r3 側 (client) から WG エンドポイント 10.255.0.1 に対して計測
ssh r3-venue "sudo iperf3 -c 10.255.0.1 --bidir -P 4 -t 30"

# Windows client からは iperf3.exe -B <venue VLAN IP> -c <server IP> で
# 必ず venue VLAN 経由・r3 WG 経由を強制 (Wi-Fi 等のバイパス経路を排除)
```
