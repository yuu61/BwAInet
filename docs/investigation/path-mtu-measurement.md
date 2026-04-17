# パス MTU 実測と WG MTU 算定

WG MTU を 1400 に決定した根拠の生データと計算過程。設計上の結論は [`../design/architecture.md`](../design/architecture.md) の MTU 設計セクションを参照。

## 自宅回線の実測パス MTU

Cloudflare (1.1.1.1) への DF ビット付き ICMP で計測:

```
1464B payload + 28B header = 1492B  ← 通過
1465B payload + 28B header = 1493B  ← DF エラー (192.168.10.1 から ICMP Fragmentation Needed)
```

**パス MTU = 1492** (PPPoE オーバーヘッド 8B: 1500 - 8 = 1492)

## トンネル経由の実効 MTU

```
自宅パス MTU:                                    1492

WireGuard 直接 (UDP/IPv4):
  1492 - 20(IPv4) - 8(UDP) - 32(WG header) =    1432

WireGuard over wstunnel (WebSocket + TLS):
  1492 - 20(IPv4) - 20(TCP) - 5(TLS record) - 14(WS frame) - 32(WG) = ~1401
```

## WG MTU 設定: 1400 の根拠

wstunnel を使用せず WireGuard 直接接続とする方針により、GCP VPC MTU (1460) がボトルネックとなる。全 WG インターフェースを 1400 に統一することで、BGP フェイルオーバー (wg0→wg1) 時の TCP MSS 不整合を防ぐ。

- GCP パス: 1400 + 60 = 1460 = GCP VPC MTU (余裕 0B、ちょうど収まる)
- PPPoE パス: 1400 + 60 = 1460 < 1492 (余裕 32B)
- 会場上流: 1400 + 60 = 1460 < 1500 (余裕 40B)
- トンネル内 IPv6 の TCP MSS: 1400 - 40(IPv6) - 20(TCP) = **1340**
- IPv6 最小 MTU (1280, RFC 8200) まで **120B の余裕**

## MSS Clamping 採用根拠

PMTUD はパス上の ICMP フィルタリングにより信頼できない場合がある (Azure 等では ICMP が 50B 超でドロップされることを確認済み)。wg0 で TCP MSS clamping を設定し、PMTUD に依存しない設計にする。

```
# VyOS
set firewall options interface wg0 adjust-mss clamp-mss-to-pmtu
```
