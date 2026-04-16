# 会場 VyOS (r3) 設計書

## 概要

r3-vyos は会場 Proxmox サーバー上の VM として動作する VyOS ルーター。会場ネットワークの中核として以下を担う:

- VLAN 間ルーティング (VLAN 11/30/40)
- DNS フォワーディング / DHCP サーバー
- WireGuard VPN (自宅 r1・r2-gcp との接続)
- BGP (デフォルトルート受信、AS65001)
- ファイアウォール (inter-VLAN ACL)
- NetFlow v9 + NDP ダンプ (法執行対応ログ)

VM リソース: 4 vCPU (host, affinity 0-11), 4GB RAM。配置詳細は [`venue-proxmox.md`](venue-proxmox.md) を参照。

**投入用コマンド集**: [`../configs/r3-venue.conf`](../configs/r3-venue.conf)

> **NIC 命名**: Proxmox VM では `net2` (virtio, トランク) と `net3` (virtio, WAN) を定義する。Linux カーネルの enumeration の結果、VyOS 内部では `eth1` が WAN、`eth2` がトランクとなる。`eth0` は存在しない。再起動時の命名揺らぎを防ぐため両方 `hw-id` で MAC 固定する。

## 1. インターフェース

### 物理マッピング

| VyOS IF | Proxmox 接続 | 役割 |
|---------|-------------|------|
| eth1 | virtio-net (`net3`, `bridge=vmbr_wan,queues=4`) | アップリンク (→ blackbox) |
| eth2 | virtio-net (`net2`, `bridge=vmbr_trunk,trunks=2-4094,queues=4`) | VLAN トランク (→ PoE スイッチ) |

- **eth1**: X710 10GbE (nic3) をホスト側 `vmbr_wan` に収容、virtio-net + vhost-net でゼロコピー転送
- **eth2**: Proxmox VLAN-aware ブリッジ `vmbr_trunk` をトランクで受け、VyOS 内部で `vif 11/30/40` を tag 付け

### VLAN サブインターフェース

| VIF | VLAN | アドレス (v4) | IPv6 | 用途 |
|-----|------|--------------|------|------|
| eth2.11 | 11 | 192.168.11.1/24 | なし | 管理 (mgmt) |
| eth2.30 | 30 | 192.168.30.1/24 | OPTAGE /64 `::1`, GCP /64 `::1` | 運営 (staff + live) |
| eth2.40 | 40 | 192.168.40.1/22 | OPTAGE /64 `::2`, GCP /64 `::2` | 来場者 (user) |

### WireGuard

| IF | アドレス | ポート | 対向 | 用途 |
|---|---|---|---|---|
| wg0 | 10.255.0.2/30 | 51820 | r1 (自宅) | プライマリ |
| wg1 | 10.255.2.1/30 | 51822 | r2-gcp | GCP トランジット (double encap 経由) |

全 WG で MTU=1400 統一 (GCP VPC の 1460 がボトルネック、詳細は [`../investigation/path-mtu-measurement.md`](../investigation/path-mtu-measurement.md))。

> wg1 listen port は wstunnel (127.0.0.1:51821 bind) と wg0 (51820) との UDP 衝突回避のため 51822 を使用する。

## 2. DHCP サーバー (v4)

VyOS 内蔵 Kea で VLAN 11/30/40 の DHCPv4 を提供。アドレス表は [`mgmt-vlan-address.md`](mgmt-vlan-address.md) を参照。

| VLAN | レンジ | GW | DNS | リース |
|---|---|---|---|---|
| 11 (mgmt) | 192.168.11.20–.199 | 192.168.11.1 | 192.168.11.1 | 3600s |
| 30 (staff) | 192.168.30.100–.254 | 192.168.30.1 | 192.168.30.1 | 3600s |
| 40 (user) | 192.168.40.100–43.254 | 192.168.40.1 | 192.168.40.1 | 3600s |

法執行対応の DHCP リース記録は **Kea の標準 syslog 出力** (`programname=kea-dhcp4`) で完結する。`DHCP4_QUERY_LABEL`, `DHCP4_PACKET_RECEIVED`, `DHCP4_LEASE_ALLOC`, `DHCP4_PACKET_SEND` の各行に hwtype/MAC/client-id/IP/interface/lease time が含まれており、追加の forensic hook (`libdhcp_legal_log.so`) は不要。VyOS 2026.03 では `service dhcp-server global-parameters` の CLI パスが存在しないため hook 設定自体できない点とも整合。詳細は [`logging-compliance.md`](logging-compliance.md)。

## 3. DNS フォワーディング

VyOS 内蔵 PowerDNS Recursor を**フルリゾルバ** (再帰解決) として使用。上流フォワーダー指定せず、ルートから再帰解決。DNSSEC は `process-no-validate` (処理するが検証失敗で利用者を止めない)。

クエリログ (`quiet=no`) を有効化し法執行対応に記録する。VyOS 2026.03 (Circinus) で `service dns forwarding options` の自由キーが廃止されたため、**post-commit hook** `/config/scripts/commit/post-hooks.d/99-pdns-quiet-no.sh` で `/run/pdns-recursor/recursor.conf` に `quiet=no` を追記し pdns-recursor を restart する。`/config/` 配下はイメージ更新でも保持されるため永続。

> `source-address` を明示すると PowerDNS Recursor が IPv4 の外向き再帰問い合わせを無効化し、twitter.com / x.com / t.co 等が SERVFAIL になる (2026-04-13 検証)。フルリゾルバ運用では送信元選択をカーネルに任せる。

## 4. IPv6 / RA

### デュアルプレフィックス構成

VLAN 30/40 では **2 つの IPv6 GUA プレフィックス**を RA で同時広告する。

| プレフィックス | 取得元 | 経路 | preferred-lifetime |
|---|---|---|---|
| OPTAGE /64 | r1 DHCPv6-PD | wg0 → r1 → OPTAGE | 14400 (4h、優先) |
| GCP /64 (`2600:1900:41d1:92::/64`) | GCP subnet (venue-v6-transit) | wg1 → r2-gcp → NAT66 | 1800 (30m) |

RFC 6724 により、通常は preferred-lifetime が長い OPTAGE が優先される。r3 の source-based PBR で src prefix に応じて出口を振り分けるため、どちらが選ばれても通信は成立する。VLAN 11 は v4 only。

NAT66 が必要な理由は [`../investigation/gcp-v6-prefix-constraint.md`](../investigation/gcp-v6-prefix-constraint.md) を参照。

### RA フラグ

SLAAC のみでアドレス配布 (DHCPv6 廃止)。

| フラグ | 値 | 効果 |
|---|---|---|
| A (autonomous) | 1 | SLAAC 有効 |
| M (managed) | 0 | DHCPv6 アドレス割当 廃止 |
| O (other-config) | 1 | RDNSS 非対応クライアントの保険 |
| RDNSS | 設定 | Android DNS 解決に必須 |

RA 送信間隔 max=60s / min=20s (大規模 Wi-Fi での L2MC テーブル枯渇対策)。スイッチ側の対策は [`venue-switch.md`](venue-switch.md) §7 参照。

### DHCPv6 廃止の方針

iOS/Android IA_NA 非対応、source address 選択の OS 依存、NDP ダンプで代替可能。詳細は [`../policy/logging-policy.md`](../policy/logging-policy.md) を参照。

### Source-based PBR (IPv6) + 3 拠点抜け fallback

src アドレスで出口を決定し、片方の wg 単独障害時は **src 維持** で他拠点経由に fallback。

| src | primary table | primary next-hop | fallback (distance 210) |
|-----|--------------|------------------|------------------------|
| OPTAGE /64 | table 101 | wg0 → r1 (fd00:255::1) | wg1 → r2 経由 → r1 (fd00:255:2::2) |
| GCP /64    | table 100 | wg1 → r2 (fd00:255:2::2) | wg0 → r1 経由 → r2 (fd00:255::1) |

- **r3 自身発信** (src 指定 ping 等): `policy local-route6` (rule 10=GCP, rule 20=OPTAGE) で table 選択
- **r3 を通過する forward パケット** (VLAN 端末): `policy route6 PBR-V6` を eth2.30/40 inbound に適用 (`set policy route6 PBR-V6 interface eth2.30`)
- **対向ルーターでの forward**: r2 wg2 inbound に `PBR-OPTAGE` (src OPTAGE → wg1 経由 r1 へ)、r1 wg0/wg1 inbound に `PBR-GCP` (src GCP → wg1 経由 r2 へ)

3 拠点抜け検証結果 (2026-04-15):
- wg0 単独死 → OPTAGE src 維持 (r3→wg1→r2→wg1→r1→pppoe0)、loss **0.5 秒**
- wg1 単独死 → GCP src 維持 (r3→wg0→r1→wg1→r2→NAT66)、loss **0.5 秒**
- r1/r2 完全死 (両 WG 死亡) は v6-health-monitor で **~6 秒で対応 src の RA deprecate**

#### ★ 重要な落とし穴: BGP nexthop tracking と /64 connected の衝突

r1 dum0 に `inet6 ${OPTAGE}/64` (DHCPv6-PD delegation) があると、kernel が /64 connected 経路を生成し FRR が distance 0 connected を best として認識、BGP の wg1 fallback 経路を kernel FIB に install しなくなる。**dum0 は /128 で保持**する (`pd-update-venue.sh` で毎分 enforce)。

### RA マルチキャスト対策

- **radvd UnicastOnly** (緊急対策): VyOS CLI 未対応のため、L2MC 枯渇時は `/run/radvd/radvd.conf` を sed で直接編集し radvd 再起動。commit で上書きされるため永続化は postconfig script に記述
- **IPv6 ファイアウォール**: VLAN 30/40 のクライアント側から送信される不正 RA (ICMPv6 type 134) を drop (WLC/AP 側 RA Guard との多層防御)

## 5. ndppd (NDP Proxy)

VLAN 30/40 が同一 /64 を共有するため、インバウンド IPv6 NS を正しい IF に振り分ける。デュアルプレフィックス構成で OPTAGE (wg0) / GCP (wg1) 両方の proxy ルールを定義。

ndppd systemd unit は `/run/ndppd/ndppd.conf` を参照するため、`/etc/ndppd.conf` をマスターとし `/config/scripts/vyos-postconfig-bootup.script` でコピーする。

## 6. BGP (AS65001)

### ピアリング

| ピア | アドレス | AS | IF | 用途 |
|------|---------|-----|-----|------|
| r1-home | 10.255.0.1 | 65002 | wg0 | 自宅直接 |
| r2-gcp | 10.255.2.2 | 64512 | wg1 | GCP トランジット |

### 経路優先度

- WireGuard 直接 (r1): local-preference 250 (優先)
- GCP 経由 default route: LP=50 (r1 優先を維持)
- GCP 経由の Google プレフィックス (goog.json): LP=250 (r2-gcp 直接を優先)

BGP 広告・受信の詳細コマンドは [`../configs/r3-venue.conf`](../configs/r3-venue.conf) 参照。

### BFD / BGP 高速フェイルオーバー

BGP hold timer (180s 既定) では障害検知が遅いため、BFD profile `FAST` + BGP timers 短縮の併用で **切替 ~0.4 秒** (実測、カオステスト結果)。

| 項目 | 設定 | 備考 |
|---|---|---|
| BFD profile `FAST` | multiplier 2 / rx 200ms / tx 200ms | 検知上限 400ms |
| BGP timers | keepalive 3 / holdtime 9 | FRR 内部の `BFD Hold Time (30s)` 回避のため TCP 層でも早期検知 |
| graceful-restart | 全 6 neighbor で `disable` | helper モード由来の stale 保持を避ける |
| 適用範囲 | r1/r2/r3 全 6 neighbor に対称展開 | 片側のみだと非対称 timer で遅延 |

対称展開が必須。片方向のみの適用だと BFD down 検知後の BGP peer down が 30 秒保留される FRR の `BFD Hold Time` タイマーに引っかかる (FRR 10.5.2 時点、変更手段なし)。

### IPv6 出口ヘルスチェック

BFD/BGP はルーター間リンクのみ検知。出口の ISP 障害 (r1 正常だが OPTAGE 停止) は検知できないため、アクティブプローブで監視し、障害時は該当プレフィックスの RA を lifetime=0 に変更する。

- **スクリプト**: [`../../scripts/v6-health-monitor.sh`](../../scripts/v6-health-monitor.sh)
- **配置**: `/config/scripts/v6-health-monitor.sh`
- **間隔**: 5 秒
- **判定**: 3 回連続失敗 (15 秒) で障害、3 回連続成功で復旧

### WG peer 公開 IP の escape route

r1 から `default-originate` で `0.0.0.0/0` を受けると、何も対策しないと WG 外殻パケット (outer dst = WG peer の公開 IP) が wg0 に吸われてループする。r3 の WG peer は 2 つあり、どちらも対策が必要。

| peer | 公開 IP | IP 性質 | 対策 |
|---|---|---|---|
| r1-home (wg0) | tukushityann.net → pppoe0 | ISP 由来で変動 | tracker スクリプトで kernel 直叩き (DDNS 追従) |
| r2-gcp (wg1) | `34.97.197.104` | GCP 予約 static | tracker スクリプトで wg0 経由 double encapsulation |

#### wg-r1-tracker.sh の役割

VyOS CLI/API validator は `peer address` に FQDN を許可しない (commit 時に再検証) が、kernel の `wg set endpoint <fqdn>:<port>` と `ip route replace` は FQDN/動的 IP に対応する。そのため VyOS config の外で tracker スクリプトを配置し、kernel 直叩きで管理する。

- r1-home: `tukushityann.net` を解決し、wg0 peer endpoint と `/32` escape route を最新 IP に追従
- r2-gcp: `ip route replace 34.97.197.104 via 10.255.0.1 dev wg0` + `wg set wg1 peer <r2-key> endpoint 34.97.197.104:51821` で wg0 (r1) 経由の double encapsulation パス構成 (blackbox の UDP ブロック回避)

詳細は [`home-vyos.md`](home-vyos.md) および [`../../scripts/wg-r1-tracker.sh`](../../scripts/wg-r1-tracker.sh)。

## 7. ファイアウォール

### ACL ポリシー ([`architecture.md`](architecture.md))

| ルール | 動作 |
|--------|------|
| VLAN 30 → VLAN 11 | 全許可 (運営) |
| VLAN 40 → 192.168.11.1 (router) | 許可 (GW/DNS/DHCP) |
| VLAN 40 → VLAN 11 (上記以外) | 拒否 |
| VLAN 40 → VLAN 30 | 拒否 |

### Forward / Input の分離

VLAN 40 クライアントの GW は 192.168.40.1 (r3 の VLAN 40 IF)。クライアントから 192.168.40.1 宛は **input** チェインで処理され forward には乗らない。そのため forward で VLAN 11 全体を deny しても、router 自身へのアクセス (DNS/DHCP/GW) は影響しない。

- **Forward filter**: VLAN 40 → VLAN 11/30 を deny
- **Input filter**: VLAN 40 → r3 の SSH (22), SNMP (161), BGP (179) を deny

## 8. MSS Clamping

WireGuard トンネル上の TCP で MTU 超過による断片化を防止。PMTUD に依存しない設計。`firewall options interface wg0 adjust-mss clamp-mss-to-pmtu`。

## 9. Flow Accounting (NetFlow v9)

VLAN 30/40 + wg0 + wg1 の 5-tuple を記録し、法執行機関対応に備える。VLAN 11 (mgmt) は対象外。

- 送信先: local-server CT (192.168.11.2:2055)
- version 9、engine-id 100、サンプリング無効 (フルキャプチャ)
- 対象 interface: `eth2.30` / `eth2.40` / `wg0` / `wg1`

> **VyOS 2026.03 パス注意**: `system flow-accounting interface` は廃止され、**`system flow-accounting netflow interface`** に移動。`source-ip` は CLI 上存在しない (egress interface の IP が自動使用される)。投入例は [`../configs/r3-venue.conf`](../configs/r3-venue.conf)。

詳細は [`logging-compliance.md`](logging-compliance.md) §6 参照。

## 10. Syslog

全 syslog を local-server (192.168.11.2) に **TCP 514** で転送。facility 別に受信側 rsyslog で `/mnt/data/syslog-archive/<dns|dhcp|conntrack|ndp>/` に振り分け (all/ に保険コピー)。転送対象:

- `pdns-recursor` クエリログ (quiet=no)
- `kea-dhcp4` DHCP リースログ
- `ndp-dump` NDP テーブルダンプ (facility local1)
- conntrack-logger は r1/r2-gcp のみ配置、r3 では conntrack ログを直接取らない (NetFlow で代替)

設定: `set system syslog remote 192.168.11.2 facility all level info protocol tcp port 514`。

## 11. NDP テーブルダンプ

1 分間隔の task-scheduler で `ip -6 neigh show` をロギング (facility local1)。iOS/Android (SLAAC のみ) を含む全デバイスの IPv6 ↔ MAC 対応を取得する。

- スクリプト: `/config/scripts/ndp-dump.sh`

## 12. wstunnel (ポート制限環境時)

会場上流で UDP 51820 がブロックされる場合、wstunnel を podman コンテナとして VyOS 上で動作させ、WireGuard UDP を WebSocket (TLS over TCP 443) にカプセル化する。切替手順は [`../operations/nic2-wan-switchover.md`](../operations/nic2-wan-switchover.md) を参照。

### 設計上のポイント

- `allow-host-networks` でホスト NS を共有 (localhost 経由で wg0 と UDP)
- wstunnel listen = `127.0.0.1:51821` (wg0 自身の 51820 との衝突回避)
- wg1 (r2-gcp) は 51822 に割り当て (wstunnel 51821 との衝突回避)
- コマンド文字列に `?`/`/` が含まれるため VyOS CLI `set` で投入不可 → REST API 経由
- `/home/app/wstunnel` 絶対パス必須 (dumb-init が execve するため、サブコマンドから始めると無限ループ)

自宅側サーバーはメインPC (192.168.10.4) で稼働、r1 DNAT で pppoe0:443 → 192.168.10.4:443。詳細は [`home-vyos.md`](home-vyos.md)。

## 13. システム基本設定

- host-name: r3-vyos
- time-zone: **UTC** (全ネットワーク機器・ログ集約層で UTC 統一、運用者向けの画面表示のみ JST)
- name-server: 127.0.0.1
- SSH: port 22, disable-password-authentication (VLAN 40 は input filter でブロック)

## 14. パフォーマンスチューニング (sysctl)

高 BDP 経路 (自宅 r1 との 10G 直結 + WG トンネル) で帯域を引き出すため、以下を永続適用。

| カテゴリ | 設定 | 理由 |
|---|---|---|
| 輻輳制御 | `tcp_congestion_control=bbr` + `default_qdisc=fq` | BBR は pacing 前提で fq と組み合わせ必須 |
| TCP バッファ | `tcp_rmem/wmem` max 16 MiB | 1Gbps × 100ms RTT = 12.5 MiB BDP をカバー |
| UDP バッファ | `udp_mem` 上限 16 MiB | WG encrypted UDP のバースト吸収 |
| backlog | `netdev_max_backlog=5000` | IRQ バースト時の drop 耐性 |

Proxmox host 側では nic3 (WAN) の ring buffer 4096 + ntuple off を永続適用しており ([`../operations/nic-firmware-update.md`](../operations/nic-firmware-update.md))、両者で協調して高スループットを実現。

## 15. 関連ドキュメント

- [`../configs/r3-venue.conf`](../configs/r3-venue.conf) — 投入用 VyOS CLI コマンド集
- [`../operations/nic2-wan-switchover.md`](../operations/nic2-wan-switchover.md) — WG / wstunnel 切替手順
- [`../operations/nic-firmware-update.md`](../operations/nic-firmware-update.md) — i40e FW・チューニング
- [`../investigation/wg-throughput-measurement.md`](../investigation/wg-throughput-measurement.md) — 実測結果
- [`../investigation/path-mtu-measurement.md`](../investigation/path-mtu-measurement.md) — MTU 算定
