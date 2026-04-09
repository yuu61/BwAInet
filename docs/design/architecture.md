# BwAI ネットワーク アーキテクチャ設計書

## 設計方針

- 元々の 4 VLAN 設計 (mgmt/live/staff/user) は、会場上流が細い環境での QoS 制御が目的だった
- 今回は QoS を WLC (Wireless LAN Controller) に委譲し、VLAN を 3 つに簡素化
- 配信用 VLAN (live) を廃止し、配信 PC は運営 VLAN (30) に統合
- IPv6 は OPTAGE から DHCPv6-PD で /64 を取得し、自宅 VyOS 経由で会場に転送

## VLAN 設計

| VLAN ID | 名称 | サブネット (v4) | IPv6 | 用途 |
|---------|------|----------------|------|------|
| 11 | mgmt | 192.168.11.0/24 | なし (v4 only) | NW 機器管理、DNS/DHCP サーバー |
| 30 | staff + live | 192.168.30.0/24 | DHCPv6-PD /64 (共有) | 運営スタッフ、配信 PC、スピーカー |
| 40 | user | 192.168.40.0/22 | DHCPv6-PD /64 (共有) | 来場者 |

### VLAN 統合の理由

- **live (旧 VLAN 20) → VLAN 30 に統合**: 配信機材は運営と同じアクセス権限で問題ない。専用 VLAN の必要なし
- **VLAN 30/40 で同一 /64 を共有**: /64 は分割不可 (SLAAC の最小単位)。mgmt が v4 only のためセキュリティ上問題なし

## ACL (v4)

```
# VLAN 30 (staff) → VLAN 11 (mgmt): 許可
# 運営スタッフは管理 VLAN のインフラ (DNS, DHCP, Grafana 等) にフルアクセス

# VLAN 40 (user) → 192.168.11.1 (default GW): 許可
# インターネットアクセス、DNS、DHCP は全てデフォルトゲートウェイ経由

# VLAN 40 (user) → VLAN 11 (上記以外): 拒否
# GW 以外の管理 VLAN 機器 (Grafana, Proxmox, スイッチ等) へのアクセスを遮断

# VLAN 40 (user) → 他 VLAN: 拒否
# 来場者から運営ネットワーク (VLAN 30) へのアクセスを遮断
```

## IPv6 設計

### 概要

OPTAGE (自宅 ISP) から DHCPv6-PD で /64 を取得する。OPTAGE は /64 のみ委任のため、自宅 LAN (192.168.10.0/24) は IPv4 only とし、取得した /64 は全て WireGuard トンネル経由で会場に転送する。会場側 r3 が VLAN 30 と 40 の両方で同一 /64 を RA 広告する。

### トラフィックフロー

```
会場端末 (SLAAC)
  → r3 (会場 VyOS) vlan30 or vlan40
    → WireGuard tunnel
      → r1 (自宅 VyOS)
        → OPTAGE
          → Internet
```

### セキュリティモデル

VLAN 30/40 が同一 /64 を共有しても安全である理由:

1. **mgmt (VLAN 11) は v4 only** → IPv6 による管理 VLAN への迂回経路が存在しない
2. **v4 ACL は独立して機能** → VLAN 40 から VLAN 11 のインフラへの v4 アクセスは DNS/DHCP のみ許可
3. **機密資産は全て VLAN 11 に隔離** → VLAN 30/40 間の v6 通信が発生しても影響は限定的

### RA フラグと DHCPv6

SLAAC と DHCPv6 を併用する。iOS/Android は DHCPv6 IA_NA 非対応のため、SLAAC を維持しつつ Windows/macOS 向けに DHCPv6 も有効化する。RDNSS は Android の DNS 解決に必須。RA フラグ: A=1, M=1, O=1, RDNSS 設定。

### ndppd (NDP Proxy)

同一 /64 を複数の VLAN インターフェースに割り当てる場合、インバウンド IPv6 トラフィックを正しいインターフェースに振り分けるために ndppd が必要。

```
# /etc/ndppd.conf
proxy wg0 {
    rule <delegated-prefix>::/64 {
        iface eth2.30
        iface eth2.40
    }
}
```

ルーターが外部からの Neighbor Solicitation を受信した際、ndppd が VLAN 30/40 の両方で代理 NDP を行い、対象デバイスが存在するインターフェースに転送する。

## QoS 設計

QoS は VLAN レベルではなく、WLC の SSID ごとのポリシーで制御する。

```
WiFi:
  SSID: staff → WLC QoS: 高帯域 (運営用)
  SSID: guest → WLC QoS: 帯域制限あり (来場者用)

有線:
  WLC 管理外 → QoS 制限なし → 実質最優先
```

- **WiFi 来場者**: WLC が帯域上限を設定
- **WiFi 運営**: WLC が優先キューを割り当て
- **有線接続 (運営/配信)**: WLC を経由しないため QoS 制限なし。有線で接続するだけで実質的に最高優先度

## 会場 Proxmox サーバー設計

詳細は [`venue-proxmox.md`](venue-proxmox.md) を参照。

### 概要

会場側のネットワーク機能を Dell OptiPlex 3070 Micro 上の Proxmox VE で仮想化し、運搬機材を 1 台に集約する。

| VM/CT | 役割 | リソース |
|-------|------|---------|
| r3-vyos (VM) | ルーター、DNS/DHCP、BGP、NetFlow、wstunnel (podman) | 2 vCPU, 4GB RAM |
| local-srv (CT) | Grafana, rsyslog, nfcapd, SNMP Exporter | 2 vCPU, 8GB RAM |

| NIC | チップ | 役割 |
|-----|--------|------|
| オンボード | Realtek RTL8111H (1GbE) | トランク → PoE スイッチ |
| 外付け | USB 2.5GbE (テープ固縛) | アップリンク → blackbox |

プロキシ環境時は VyOS 上の wstunnel (podman コンテナ) が WireGuard UDP パケットを WebSocket (TLS over TCP 443) にカプセル化し、HTTP CONNECT プロキシを透過する。プロキシ解除時は WireGuard endpoint を直接接続に切り替える。

## 自宅 VyOS (r1) 設計

詳細は [`home-vyos.md`](home-vyos.md) を参照。

### 概要

自宅ルーターを NEC IX3315 から VyOS に移行する。家族用ネットワーク 192.168.10.0/24 は現行と同一の IP 体系・DHCP・DNS 設定を維持し、ダウンタイムを最小化する。

| 機能 | 設定 |
|------|------|
| WAN | PPPoE (OPTAGE) → pppoe0 |
| LAN | br0 (eth0, eth2): 192.168.10.1/24 |
| DHCP | 192.168.10.3–199, 固定割り当て 3 台 |
| DNS | フォワーディング (192.168.10.1) |
| NAT | source masquerade + destination (→.9: SSH/HTTP/HTTPS/iperf3/WireGuard) |
| IPv6 | DHCPv6-PD /64 を取得、自宅 LAN は IPv4 only、/64 は全て wg0 経由で会場へ転送 |
| WireGuard | wg0: 10.255.0.1/30 (r3 直接), wg1: 10.255.1.1/30 (r2-gcp) |
| WireGuard | wg0: r3 直接, wg1: r2-gcp (GCE) |
| BGP | AS65002 (r3 直接 + r2-gcp トランジット) |

## VPN / ルーティング

### 会場 ↔ 自宅 (VyOS 間)

| プロトコル | 用途 |
|-----------|------|
| WireGuard (or wstunnel 経由) | アンダーレイ VPN トンネル |
| BGP (AS65001 ↔ AS65002) | v4 デフォルトルート (AD20) でユーザートラフィックを自宅経由 |
| DHCPv6-PD /64 転送 | 自宅で取得した /64 を会場へ static route |

### VPN 方式の選択

上位レイヤーは常に WireGuard (wg0) に統一し、BGP/IPv6/firewall 設定を1セットに保つ。

```
プロキシ解除が可能 → WireGuard 直接 (UDP)
プロキシ解除が不可 → WireGuard over wstunnel (WebSocket/TLS over TCP 443 経由)
```

会場の上流 (blackbox) がプロキシを挟む可能性があるため、当日の環境に応じて下位トンネルのみ切り替え。

- 直接接続時: `endpoint = <自宅グローバルIP>:51820`
- wstunnel 経由時: `endpoint = 127.0.0.1:51820` (VyOS 上の wstunnel podman コンテナが中継)

### MTU 設計

#### 自宅回線の実測パス MTU

Cloudflare (1.1.1.1) への DF ビット付き ICMP で計測:

```
1464B payload + 28B header = 1492B  ← 通過
1465B payload + 28B header = 1493B  ← DF エラー (192.168.10.1 から ICMP Fragmentation Needed)
```

**パス MTU = 1492** (PPPoE オーバーヘッド 8B: 1500 - 8 = 1492)

#### トンネル経由の実効 MTU

```
自宅パス MTU:                                    1492

WireGuard 直接 (UDP/IPv4):
  1492 - 20(IPv4) - 8(UDP) - 32(WG header) =    1432

WireGuard over wstunnel (WebSocket + TLS):
  1492 - 20(IPv4) - 20(TCP) - 5(TLS record) - 14(WS frame) - 32(WG) = ~1401
```

#### WG MTU 設定: 1400

wstunnel を使用せず WireGuard 直接接続とする方針により、GCP VPC MTU (1460) がボトルネックとなる。全 WG インターフェースを 1400 に統一することで、BGP フェイルオーバー (wg0→wg1) 時の TCP MSS 不整合を防ぐ。

- GCP パス: 1400 + 60 = 1460 = GCP VPC MTU (余裕 0B、ちょうど収まる)
- PPPoE パス: 1400 + 60 = 1460 < 1492 (余裕 32B)
- 会場上流: 1400 + 60 = 1460 < 1500 (余裕 40B)
- トンネル内 IPv6 の TCP MSS: 1400 - 40(IPv6) - 20(TCP) = **1340**
- IPv6 最小 MTU (1280, RFC 8200) まで **120B の余裕**

#### MSS Clamping

PMTUD はパス上の ICMP フィルタリングにより信頼できない場合がある (Azure 等では ICMP が 50B 超でドロップされることを確認済み)。wg0 で TCP MSS clamping を設定し、PMTUD に依存しない設計にする。

```
# VyOS
set firewall options interface wg0 adjust-mss clamp-mss-to-pmtu
```

### GCP 接続 (GCE VyOS トランジットルーター)

GCE 上に VyOS インスタンス (r2-gcp) を配置し、WireGuard メッシュ + BGP フルメッシュでトランジットルーターとして機能させる。HA VPN や NCC は使用しない。

#### r2-gcp インスタンス

| 項目 | 値 |
|------|-----|
| GCP プロジェクト | bwai-noc |
| ゾーン | asia-northeast2-a (大阪) |
| マシンタイプ | e2-micro |
| VyOS | 2026.03 Stream (自前 GCE イメージ) |
| 内部 IP | 10.174.0.4 |
| AS | 64512 |

GCE イメージは VyOS Stream ISO から自前で raw ディスクイメージに変換し、GCS 経由で GCE カスタムイメージとして登録したもの。マーケットプレイス版 (~$100/月) を回避し、e2-micro (~$7/月、無料枠対象) で運用。

#### WireGuard メッシュ

```
r1-home (AS65002)        r2-gcp (AS64512)        r3-venue (AS65001)
  wg0 ◄══════════════════════════════════════════► wg0   ← 直接 (優先)
  wg1 ◄════► wg0                        wg1 ◄════► wg1   ← GCP 経由 (フォールバック)
```

| トンネル | アドレス | ポート |
|---------|---------|--------|
| r1 ↔ r3 (wg0, 直接) | 10.255.0.1/30 ↔ 10.255.0.2/30 | 51820 |
| r1 ↔ r2 (wg1) | 10.255.1.1/30 ↔ 10.255.1.2/30 | 51821 / 51820 |
| r3 ↔ r2 (wg1) | 10.255.2.1/30 ↔ 10.255.2.2/30 | 51821 |

#### BGP フルメッシュとフォールバック

3 台の VyOS で eBGP フルメッシュを構成。AS path の長さで自然に経路選択される。

```
通常時:
  r3 → wg0 → r1 (直接)                    AS path: 65001 → 65002 (2 hop)

WireGuard 障害時 (自動フォールバック):
  r3 → wg1 → r2-gcp → wg0 → r1           AS path: 65001 → 64512 → 65002 (3 hop)
```

WireGuard 直接リンク断で BGP セッションも落ち、自動的に r2-gcp 経由にフォールバック。local-preference で制御: r1 直接 = 200、r2-gcp の Google プレフィックス = 250 (r2-gcp 直接優先)、r2-gcp の default route = 50 (r1 優先を維持)。Google 宛 v4 トラフィックは r3 → r2-gcp 直接で、r1 を経由しない。

#### GCE/GCS 向けトラフィック

r2-gcp が同一 VPC 内にいるため、GCE/GCS 向けトラフィックを r2-gcp 経由にルーティングできる。r2-gcp が BGP で GCE サブネットを r1/r3 に広告し、r1-r3 直接リンク断でも r3 → r2-gcp → GCE/GCS のログ転送は継続する。

```
r3 (local-srv)
  ├── デフォルトルート → wg0 → r1 → pppoe0 → Internet (一般)
  └── GCE subnet 宛   → wg1 → r2-gcp → VPC 内部 → GCE/GCS (ログ転送)
```

## DNS / DHCP (VyOS 統一構成)

DNS・DHCP を VyOS (r3) に統合し、別サーバー + GCE 冗長構成を廃止。アップリンクが 1 本のため r3 障害時には GCE standby にも到達不能であり、冗長化の実効性がない。

| サービス | 実装 | 備考 |
|---------|------|------|
| DNS | VyOS `service dns forwarding` (PowerDNS Recursor) | クエリログ有効 |
| DHCPv4 | VyOS `service dhcp-server` (内部 Kea) | forensic log 有効 |
| DHCPv6 | VyOS `service dhcpv6-server` (内部 Kea) | Windows/macOS 用。iOS/Android は SLAAC |

### RA フラグ設定

| フラグ | 値 | 効果 |
|---|---|---|
| A (autonomous) | 1 | SLAAC 有効 (iOS/Android 用) |
| M (managed) | 1 | DHCPv6 アドレス割り当て (Windows/macOS 用) |
| O (other-config) | 1 | DHCPv6 で DNS 等の追加情報取得 |
| RDNSS | 設定 | Android の DNS 解決に必須 |

## サービス構成

| サービス | 配置 | 役割 |
|---------|------|------|
| DNS / DHCP | VyOS (r3) | 名前解決 / IP 配布 |
| Grafana | Local Server (local) / GCE (active, 外部公開) | 監視ダッシュボード |
| rsyslog | Local Server → GCE → GCS | ログ集約・アーカイブ |
| nfcapd | Local Server | NetFlow 収集 |

## 通信ログ保存 (法執行機関対応)

詳細は [`logging-compliance.md`](logging-compliance.md) を参照。

| ログ種別 | 記録元 | 収集先 | 保存期間 |
|---------|--------|--------|---------|
| NetFlow v9 (5-tuple) | VyOS flow-accounting | nfcapd → GCE → GCS | 180 日 |
| DNS クエリログ | VyOS dns forwarding | rsyslog → GCE → GCS | 180 日 |
| DHCP forensic log | VyOS dhcp-server (Kea hook) | rsyslog → GCE → GCS | 180 日 |
| NDP テーブルダンプ | VyOS cron (1 分間隔) | rsyslog → GCE → GCS | 180 日 |
