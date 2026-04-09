# GCP 連携強化設計

## 背景

現状の GCP 活用は以下の 2 点に留まっている:

| 機能 | 内容 |
|------|------|
| r2-gcp (トランジット) | WireGuard mesh + BGP でフォールバック経路 |
| GCS ログ保存 | rsyslog → GCE → GCS (bwai-compliance-logs) で 180 日保持 |

経路冗長化とログアーカイブのみで、GCP の活用としては薄い。Google グローバルの DevRel Central からカメラクルー・GDEなどの大物ゲストが来場する規模のイベントとして、GCP との機能連携を強化し、ネットワーク運用の質とデモンストレーション価値を高めたい。

ハンズオンセッション等で GCP 向けトラフィックが多いことが予想されるため、r2-gcp を活用した GCP トラフィック最適化を最優先で設計する。

---

## GCP トラフィック最適化設計

### 1. 設計概要

GCP 向けトラフィックを r2-gcp (GCE 大阪) 経由で Google 内部ネットワークに直接流し、自宅回線 (OPTAGE) の負荷を軽減する。

- **IPv4**: r2-gcp が Google IP レンジ (`goog.json`) を BGP で広告し、宛先ベースで Google 向けトラフィックを r2-gcp 経由に最適化。r2-gcp で SNAT。
- **IPv6**: OPTAGE /64 に加え GCP /64 を会場で RA 広告し、r3 の source-based PBR で振り分け。r2-gcp で **NAT66** (GCP の制約により E2E ネイティブ v6 は不可)。

```
[IPv6]
会場デバイス (SLAAC: OPTAGE GUA + GCP GUA)
  │
  ▼
r3 (PBR: src prefix で振り分け)
  ├── src = OPTAGE /64 → wg0 → r1 → OPTAGE → Internet
  └── src = GCP /64    → wg1 → r2-gcp → NAT66 → Google backbone → GCP / Internet

[IPv4]
r3 (BGP: dst で振り分け)
  ├── dst = Google IP (goog.json) → wg1 → r2-gcp → SNAT → Google backbone
  └── dst = その他                → wg0 → r1 → OPTAGE → Internet
```

### 2. GCP IPv6 制約と NAT66 が必要な理由

#### GCP IPv6 プレフィックス階層

| レベル | プレフィックス | 割り当て |
|--------|-------------|---------|
| VPC | /48 | ULA (`fd20::/20`) または GUA (Google リージョナル) |
| サブネット | **/64** | VPC の /48 から切り出し |
| **VM** | **/96** | サブネットの /64 から自動割り当て (これ以上は不可) |

#### /64 を r3 まで持ってこれない理由

GCP データプレーンは、サブネットの /64 内で **VM の /96 に割り当てられていないアドレス宛のパケットをドロップする**:

> "If the packet's destination isn't associated with a resource or belongs to a stopped VM, the packet is dropped."
> — [GCP VPC Routes ドキュメント](https://docs.cloud.google.com/vpc/docs/routes)

会場デバイスが SLAAC で生成するアドレスは r2-gcp の /96 外であるため、Internet からの戻りパケットが GCP で drop される。

```
サブネット /64: 2600:1901:xxxx:yyyy::/64
  ├── r2-gcp VM:  2600:1901:xxxx:yyyy:0:0:0:4/96  ← GCP がルーティング可能
  └── 会場デバイス: 2600:1901:xxxx:yyyy:<random>/64 ← GCP が drop
```

以下の回避策を全て調査したが、いずれも IPv6 では利用不可:

| 回避策 | IPv6 対応 | 備考 |
|--------|:---------:|------|
| カスタム静的ルートで /64 → VM | × | サブネットルートと重複するルートは作成不可 |
| Alias IP ranges で /64 全体を VM に | × | IPv4 のみ対応 |
| NCC Router Appliance + Cloud Router | × | IPv4 only |
| Hybrid Subnet (VM 外アドレスを VPN 転送) | × | IPv4 only (コンセプトは理想的だが v6 非対応) |
| HA VPN + Cloud Router | ○ | IPv6 対応だが、サブネットルーティングの drop は回避不可 |

#### NAT66 による解決

r2-gcp で **NAT66** を行い、会場デバイスの src アドレスを r2-gcp の /96 アドレスに変換する。戻りパケットは r2-gcp の /96 宛となるため、GCP が正しくルーティングする。

```
[Outbound]
会場デバイス (src: GCP /64 SLAAC addr, dst: Internet)
  → r3 PBR → wg1 → r2-gcp
    → NAT66 masquerade (src → r2-gcp /96 addr)
      → Google backbone → Internet / GCP サービス

[Inbound (戻り)]
Internet → Google backbone → VPC
  → dst = r2-gcp /96 addr → VM に到達 ✓
    → conntrack で un-NAT66 (dst → 会場デバイスの SLAAC addr)
      → wg1 → r3 → 会場デバイス
```

#### NAT66 の影響

| 項目 | 影響 |
|------|------|
| Internet から見た src | r2-gcp の /96 アドレス (会場デバイスの実アドレスは見えない) |
| 会場内の通信 | 影響なし (NAT は r2-gcp 通過時のみ) |
| ログ追跡 | r2-gcp の NAT テーブル (conntrack) の参照が必要 |
| デュアル RA の価値 | **維持** — PBR による経路分離、r1 障害時の GCP 経由継続は機能する |

### 3. メリット

| 項目 | 現状 (全て r1 経由) | 最適化後 |
|------|-------------------|---------|
| GCP 向け v4 経路 | WG → OPTAGE → 公衆Internet → GCP | WG → GCE → SNAT → Google 内部 NW |
| GCP 向け v6 経路 | WG → OPTAGE → Internet → GCP | WG → GCE → NAT66 → Google 内部 NW |
| 自宅回線負荷 | 全トラフィックを消費 | GCP 向けをオフロード |
| r1 障害耐性 | r1 断 = 全断 | **r1 断でも GCP 向け通信は r2-gcp 経由で継続** |
| v4 GCP 向け | 公衆 Internet 経由 | Google 内部 NW |

### 4. デュアルプレフィックス RA 設計

NAT66 が必要ではあるが、デュアルプレフィックス RA は**経路分離と耐障害性のために維持する**。

#### アドレス体系

| プレフィックス | 取得元 | 経路 | NAT | 用途 |
|--------------|--------|------|-----|------|
| OPTAGE /64 | DHCPv6-PD (r1 経由) | wg0 → r1 → OPTAGE | なし | 一般 Internet (既存) |
| GCP /64 | GCP VPC external IPv6 | wg1 → r2-gcp → Google | NAT66 | GCP サービス + Google backbone 経由 |

#### クライアント側の動作

- 両 /64 が RA で広告され、SLAAC で GUA を 2 つ取得
- OS の source address selection (RFC 6724) でどちらかが選ばれる
- **どちらが選ばれても通信は成立する** (r3 の PBR で正しい出口に振り分け)

#### preferred-lifetime による誘導

GCP /64 の preferred-lifetime を短めに設定し、一般 Internet 向けは OPTAGE が優先されるよう軽くバイアスをかける。GCE egress 課金の最適化が目的。

```
# OPTAGE: デフォルト (preferred-lifetime 14400s)
set service router-advert interface eth2.30 prefix <optage-prefix>::/64

# GCP: やや短め (preferred-lifetime 1800s)
# → deprecated にはならないが、OS は OPTAGE を若干優先する
set service router-advert interface eth2.30 prefix <gcp-prefix>::/64 preferred-lifetime 1800
set service router-advert interface eth2.30 prefix <gcp-prefix>::/64 valid-lifetime 14400
```

#### RFC 8028 問題への対応

マルチプレフィックス環境では「プレフィックスとゲートウェイの紐付けが OS 側で保証されない」問題がある ([参考: JANOG57 NOC L1-L3 設計](https://segre.hatenablog.com/entry/2026/01/18/183203))。本設計では r3 が唯一のゲートウェイであり、**PBR で src prefix を見て振り分ける**ため、クライアント側の source address selection に依存しない。

### 5. GCP インフラ構成

#### VPC dual-stack 有効化

既存の `default` VPC (auto-mode から custom-mode に変換済み) に外部 IPv6 を有効化。VPC に Google GUA /48 が割り当てられる。

```bash
# VPC を custom mode に変換（auto-mode では dual-stack 不可）
gcloud compute networks update default --switch-to-custom-subnet-mode
```

#### サブネット構成

既存の default サブネットを dual-stack 化する。r2-gcp は /64 から /96 を自動取得し、この /96 アドレスが NAT66 の変換先となる。

会場向けに別サブネット (venue-v6-transit) を作成し、その /64 を RA 広告用のプレフィックスとして会場に転送する。このサブネットに VM は配置しない (RA 広告用のプレフィックス確保のみ)。

| サブネット | IPv4 | IPv6 | 用途 |
|-----------|------|------|------|
| default (既存) | 10.174.0.0/20 | `2600:1900:41d0:9d::/64` (external) | r2-gcp 配置、NAT66 src |
| venue-v6-transit (新規) | 10.174.16.0/24 | `2600:1900:41d1:92::/64` (external) | 会場 RA 広告用 (VM なし) |

```bash
# 既存サブネットを dual-stack に更新
gcloud compute networks subnets update default \
    --region=asia-northeast2 \
    --stack-type=IPV4_IPV6 \
    --ipv6-access-type=EXTERNAL

# 会場 RA 広告用プレフィックス確保
gcloud compute networks subnets create venue-v6-transit \
    --network=default \
    --region=asia-northeast2 \
    --range=10.174.16.0/24 \
    --stack-type=IPV4_IPV6 \
    --ipv6-access-type=EXTERNAL
```

※ venue-v6-transit の /64 は会場で RA 広告されるが、Internet からこの /64 宛の戻りパケットは r2-gcp の NAT66 conntrack 経由で処理される (r2-gcp /96 宛として到着)。venue-v6-transit サブネット自体にパケットが到達する必要はない。

#### r2-gcp VM 更新

default サブネット (dual-stack 化済み) に配置。r2-gcp (10.174.0.7) は /64 から /96 を自動取得する。NAT66 により会場トラフィックの src をこの /96 アドレスに変換するため、GCP データプレーンは r2-gcp /96 宛として正しくルーティングする。

```bash
# IP forwarding 有効化 (VM 再作成が必要な場合がある)
gcloud compute instances create r2-gcp \
    --zone=asia-northeast2-a \
    --machine-type=e2-small \
    --can-ip-forward \
    --network-interface=network=default,subnet=default,stack-type=IPV4_IPV6 \
    --image=<vyos-custom-image>
```

※ イベント期間中は e2-micro → **e2-small** ($3.5/月 → $7/月) への引き上げを推奨。WireGuard 暗号処理 + NAT66 + ルーティング負荷を考慮。

### 6. WireGuard IPv6 拡張

#### P2P リンクアドレス (ULA)

既存の v4 アドレス体系に合わせた ULA を追加:

| トンネル | 両端 IF 名 | IPv4 | IPv6 (新規) |
|---------|-----------|------|-------------|
| r1 ↔ r3 | r1:wg0 ↔ r3:wg0 | 10.255.0.1/30 ↔ .2 | fd00:255:0::1/126 ↔ ::2 |
| r1 ↔ r2-gcp | r1:wg1 ↔ r2-gcp:wg1 | 10.255.1.1/30 ↔ .2 | fd00:255:1::1/126 ↔ ::2 |
| r3 ↔ r2-gcp | r3:wg1 ↔ **r2-gcp:wg2** | 10.255.2.1/30 ↔ .2 | fd00:255:2::1/126 ↔ ::2 |

> **注**: r2-gcp 側は 1 ホストに r1 向け・r3 向けの 2 本を同居させるため、IF 名が `wg1` / `wg2` に分かれる (r1/r3 側はそれぞれ `wg0`/`wg1`)。listen port は r2-gcp:wg1=51820 (r1 ペア)、r2-gcp:wg2=51821 (r3 ペア)。

#### r3 wg1 更新

```
# 既存 v4 に v6 アドレスを追加
set interfaces wireguard wg1 address fd00:255:2::1/126

# allowed-ips に v6 を追加
set interfaces wireguard wg1 peer r2-gcp allowed-ips fd00:255:2::2/128
set interfaces wireguard wg1 peer r2-gcp allowed-ips <gcp-prefix>::/64
```

#### r2-gcp wg1 (r1 向け) 更新

BGP フェイルオーバー (r3 直結断 → r1 経由迂回) に備え、r1 peer に会場プレフィックスも許可する:

```
set interfaces wireguard wg1 address fd00:255:1::2/126

set interfaces wireguard wg1 peer r1 allowed-ips fd00:255:1::1/128
set interfaces wireguard wg1 peer r1 allowed-ips 192.168.10.0/24
set interfaces wireguard wg1 peer r1 allowed-ips 192.168.11.0/24
set interfaces wireguard wg1 peer r1 allowed-ips 192.168.30.0/24
set interfaces wireguard wg1 peer r1 allowed-ips 192.168.40.0/22
```

#### r2-gcp wg2 (r3 向け) 更新

BGP フェイルオーバー (r1 直結断 → r3 経由迂回) に備え、r3 peer に自宅プレフィックスも許可する:

```
set interfaces wireguard wg2 address fd00:255:2::2/126

set interfaces wireguard wg2 peer r3 allowed-ips fd00:255:2::1/128
set interfaces wireguard wg2 peer r3 allowed-ips 192.168.10.0/24
set interfaces wireguard wg2 peer r3 allowed-ips 192.168.11.0/24
set interfaces wireguard wg2 peer r3 allowed-ips 192.168.30.0/24
set interfaces wireguard wg2 peer r3 allowed-ips 192.168.40.0/22
set interfaces wireguard wg2 peer r3 allowed-ips <gcp-prefix>::/64
```

#### r1 wg0 更新

OPTAGE /64 の転送に加え、v6 P2P リンクを追加:

```
set interfaces wireguard wg0 address fd00:255:0::1/126

set interfaces wireguard wg0 peer venue allowed-ips fd00:255:0::2/128
set interfaces wireguard wg0 peer venue allowed-ips <optage-prefix>::/64
```

#### r1 wg1 更新

```
set interfaces wireguard wg1 address fd00:255:1::1/126

set interfaces wireguard wg1 peer r2-gcp allowed-ips fd00:255:1::2/128
set interfaces wireguard wg1 peer r2-gcp allowed-ips fd00:255:2::/126
```

※ r1 wg1 peer r2-gcp の allowed-ips には goog.json の IPv4 プレフィックス (96 本) も追加が必要。追加しないと WG の crypto routing で Google 宛パケットがドロップされる。goog.json 自動更新スクリプトと連動して allowed-ips も更新する。

### 7. r3 設定 (会場 VyOS)

#### インターフェースアドレス (GCP /64)

各 VLAN にGCP /64 のアドレスを付与する。unbound (DNS) の listen-address および NDP 解決に必要。

```
set interfaces ethernet eth2 vif 30 address <gcp-prefix>::1/64
set interfaces ethernet eth2 vif 40 address <gcp-prefix>::2/64
```

#### デュアルプレフィックス RA

VyOS の `autonomous-flag` はデフォルト true のため明示指定不要。

```
# === RA: OPTAGE /64 (既存) ===
set service router-advert interface eth2.30 prefix <optage-prefix>::/64 preferred-lifetime 14400
set service router-advert interface eth2.30 prefix <optage-prefix>::/64 valid-lifetime 86400

# === RA: GCP /64 (新規) ===
set service router-advert interface eth2.30 prefix <gcp-prefix>::/64 preferred-lifetime 1800
set service router-advert interface eth2.30 prefix <gcp-prefix>::/64 valid-lifetime 14400

# 共通フラグ (M flag なし — SLAAC のみでアドレス配布)
# managed-flag は無効: iOS/Android が DHCPv6 非対応のため SLAAC に統一
# other-config-flag は有効: RDNSS 非対応クライアントの保険
set service router-advert interface eth2.30 other-config-flag true
set service router-advert interface eth2.30 name-server <optage-prefix>::1

# VLAN 40 も同様
set service router-advert interface eth2.40 prefix <optage-prefix>::/64 preferred-lifetime 14400
set service router-advert interface eth2.40 prefix <optage-prefix>::/64 valid-lifetime 86400

set service router-advert interface eth2.40 prefix <gcp-prefix>::/64 preferred-lifetime 1800
set service router-advert interface eth2.40 prefix <gcp-prefix>::/64 valid-lifetime 14400

set service router-advert interface eth2.40 other-config-flag true
set service router-advert interface eth2.40 name-server <optage-prefix>::2
```

#### DNS (unbound) IPv6 対応

unbound が IPv6 アドレスでも listen するようにする。OPTAGE / GCP 両方のクライアントが名前解決可能になる。

```
# listen-address (v6 追加)
set service dns forwarding listen-address <optage-prefix>::1
set service dns forwarding listen-address <optage-prefix>::2
set service dns forwarding listen-address <gcp-prefix>::1
set service dns forwarding listen-address <gcp-prefix>::2

# allow-from (v6 追加)
set service dns forwarding allow-from <optage-prefix>::/64
set service dns forwarding allow-from <gcp-prefix>::/64
```

#### ~~DHCPv6~~ (廃止)

DHCPv6 によるアドレス配布は廃止。理由:

- iOS/Android が DHCPv6 IA_NA (アドレス割当) 非対応 → SLAAC 必須
- RFC 6724 によりソースアドレス選択は OS 依存 → DHCPv6 アドレスが PBR に使われる保証なし
- 法執行機関対応の MAC↔IPv6 追跡は NDP テーブル dump でカバー済み
- kea が VIF の `interface` 指定に VyOS CLI で対応しておらず運用が複雑

アドレス配布は SLAAC (A flag) に統一し、DNS は RDNSS + O flag で配布する。

#### Source-based PBR (IPv6)

GCP /64 を src とするパケットを wg1 (r2-gcp) 経由に強制する。

`policy local-route6` は `ip -6 rule` を生成し、転送パケットにも適用される。
VyOS の `policy route6` はインターフェース適用 (VIF) に対応していないため、`local-route6` を使用する。

```
# === PBR: GCP /64 src → r2-gcp ===

# ip -6 rule: src が GCP /64 なら table 100 を参照
set policy local-route6 rule 10 source address <gcp-prefix>::/64
set policy local-route6 rule 10 set table 100

# テーブル 100: デフォルトルートを r2-gcp (wg1) に向ける
set protocols static table 100 route6 ::/0 next-hop fd00:255:2::2
```

OPTAGE /64 src のパケットはデフォルトルート (wg0 → r1) を使用するため、追加設定不要。

#### ndppd (NDP Proxy) 更新

既存の OPTAGE /64 に加え、GCP /64 の NDP proxy を追加。

```
# /etc/ndppd.conf
proxy wg0 {
    rule <optage-prefix>::/64 {
        iface eth2.30
        iface eth2.40
    }
}

proxy wg1 {
    rule <gcp-prefix>::/64 {
        iface eth2.30
        iface eth2.40
    }
}
```

ndppd の systemd unit は `/run/ndppd/ndppd.conf` を参照するため (`ConditionPathExists`)、
`/etc/ndppd.conf` をマスターとし、ブートスクリプトでコピーする:

```bash
# /config/scripts/vyos-postconfig-bootup.script に追記
mkdir -p /run/ndppd
cp /etc/ndppd.conf /run/ndppd/ndppd.conf
systemctl start ndppd || true
```

### 8. r2-gcp 設定 (GCE VyOS)

#### BGP import フィルタ (DENY-DEFAULT)

r1-home が r3-venue に `default-originate` で `0.0.0.0/0` を広告しており、r3 が eBGP の経路再広告でこの default を r2-gcp にも転送する。r2-gcp が BGP default (AD20) を受け入れると GCP の static default (`0.0.0.0/0 via 10.174.0.1, eth0`, AD210) が負け、r2 の全アウトバウンドトラフィックが wg2 → r3 に吸い込まれる。

r2-gcp は GCP VPC に直接インターネット接続を持つため、**BGP から default route を受け取る必要がない**。全 neighbor の import で 0.0.0.0/0 を拒否する:

```
# === Default route import フィルタ ===
set policy prefix-list DENY-DEFAULT rule 10 action deny
set policy prefix-list DENY-DEFAULT rule 10 prefix 0.0.0.0/0

set policy prefix-list DENY-DEFAULT rule 20 action permit
set policy prefix-list DENY-DEFAULT rule 20 prefix 0.0.0.0/0 le 32

set protocols bgp neighbor 10.255.1.1 address-family ipv4-unicast prefix-list import DENY-DEFAULT
set protocols bgp neighbor 10.255.2.1 address-family ipv4-unicast prefix-list import DENY-DEFAULT
```

#### BGP import フィルタ (DENY-DEFAULT-V6)

IPv4 の DENY-DEFAULT と同じ理由で、IPv6 の `::/0` も BGP で受け取らないようにする。r1-home が `default-originate` で `::/0` を広告しており、r2-gcp が BGP default (AD20) を受け入れると GCE の static default (`::/0 via fe80::4001:aff:feae:1, eth0`, AD1) が負け、r2 の全 v6 アウトバウンドが wg 経由に吸い込まれる。

```
# === Default route import フィルタ (IPv6) ===
set policy prefix-list6 DENY-DEFAULT-V6 rule 10 action deny
set policy prefix-list6 DENY-DEFAULT-V6 rule 10 prefix ::/0

set policy prefix-list6 DENY-DEFAULT-V6 rule 20 action permit
set policy prefix-list6 DENY-DEFAULT-V6 rule 20 prefix ::/0
set policy prefix-list6 DENY-DEFAULT-V6 rule 20 le 128

set protocols bgp neighbor 10.255.1.1 address-family ipv6-unicast prefix-list import DENY-DEFAULT-V6
set protocols bgp neighbor 10.255.2.1 address-family ipv6-unicast prefix-list import DENY-DEFAULT-V6
```

#### sshd privilege separation ディレクトリ (起動時修正)

VyOS は `ssh.service` (systemd) を disabled にし、独自に sshd を直接起動する。しかし、systemd の `ExecStartPre` で作成される `/run/sshd` ディレクトリが省略されるため、**VM 再起動後に SSH 接続の子プロセスが `Missing privilege separation directory: /run/sshd` で即死する**。親プロセスは Listen 状態で正常に見えるが、全ての新規接続が `Connection reset` になる。

`/config/scripts/vyos-postconfig-bootup.script` に以下を追記して対策する:

```bash
mkdir -p /run/sshd
```

#### IPv6 ルーティング

GCP /64 を WireGuard 経由で r3 に転送する。また、GCE が割り当てた /96 を eth0 に設定し、GCE の v6 ゲートウェイ (link-local) 経由のデフォルトルートを追加する。

```
# GCE 割り当て /96 を eth0 に設定 (NAT66 の src アドレスとして必要)
set interfaces ethernet eth0 address 2600:1900:41d0:9d::/96

# IPv6 デフォルトルート (GCE v6 ゲートウェイ経由)
set protocols static route6 ::/0 next-hop fe80::4001:aff:feae:1 interface eth0

# GCP /64 を r3 へ転送
set protocols static route6 <gcp-prefix>::/64 next-hop fd00:255:2::1

# IPv6 フォワーディング有効化
set system option ip-forwarding
```

#### NAT66 (IPv6 source NAT)

会場デバイスの GCP /64 src アドレスを r2-gcp の /96 アドレスに変換する。GCP データプレーンが /96 外のアドレスを drop するため必須。

```
# v6: 会場 GCP /64 src → r2-gcp /96 アドレスに SNAT
set nat66 source rule 10 outbound-interface name eth0
set nat66 source rule 10 source prefix <gcp-prefix>::/64
set nat66 source rule 10 translation address masquerade
set nat66 source rule 10 description 'NAT66 venue GCP prefix to r2-gcp /96'
```

戻りパケットは r2-gcp の /96 アドレス宛で到着し、conntrack により自動的に un-NAT される。

#### v4 SNAT (Google IP レンジ向け)

v4 の Google 向けトラフィックは r2-gcp で SNAT する (会場 src → GCE 内部 IP)。

```
# v4: 会場サブネット → GCE 内部 IP に SNAT
set nat source rule 10 outbound-interface name eth0
set nat source rule 10 source address 192.168.0.0/16
set nat source rule 10 translation address masquerade
set nat source rule 10 description 'SNAT venue to GCE for Google'
```

#### v4 BGP: Google IP レンジ広告 (goog.json)

Google 公式が公開している IP レンジリストのうち **`goog.json`** を採用する。

| リスト | 件数 (v4/v6) | 内容 |
|--------|------------|------|
| `cloud.json` | 1,074 / 66 | GCP のリージョン別細粒度 prefix (Google Cloud のみ) |
| **`goog.json`** | **94 / 15** | **Google 全体の集約済み prefix (cloud.json のスーパーセット)** |

`goog.json` は `cloud.json` を内包し、かつ Gmail / YouTube / Search / Workspace 等の Google API 全般を含む。BwAI は単一リージョン (asia-northeast2) 前提でリージョン粒度の制御は不要であり、Google backbone の恩恵を Google サービス全般に広げられるため `goog.json` を選択する。両方広告は longest-match で意味が出ず BGP テーブルを冗長に肥大化させるだけなので行わない。

##### BGP 広告の仕組み (重要)

r2-gcp には既に default route (`0.0.0.0/0 via 10.174.0.1, eth0` = VPC GW) があり、traceroute レベルでは Google backbone に到達できている。しかし **BGP は RIB に存在する prefix しか広告しない** ため、`goog.json` の個別 prefix を RIB に載せる必要がある。

そこで goog.json の各 prefix を **static route として next-hop = VPC GW (`10.174.0.1`)** で作成する。これは転送経路を変えるためではなく、**BGP 広告の材料として RIB に具体 prefix を載せる**ためだけの static である。実際のパケットは default と同じ経路で Google backbone に流れる。

- next-hop に `Null0` (blackhole) を使ってはならない。RIB には載るが FIB で drop され、実トラフィックが全損する。
- next-hop は必ず VPC GW = `10.174.0.1` を指定する。

##### 設定

```
# === Static route (BGP に載せるためだけの経路、next-hop は VPC GW) ===
# ※ goog.json から自動生成、cron で定期更新
set protocols static route 8.8.4.0/24 next-hop 10.174.0.1
set protocols static route 8.8.8.0/24 next-hop 10.174.0.1
set protocols static route 34.64.0.0/10 next-hop 10.174.0.1
set protocols static route 142.250.0.0/15 next-hop 10.174.0.1
# ... (goog.json から自動生成、v4 94 本)

# === Prefix-list (広告対象の定義) ===
set policy prefix-list GOOG rule 10 prefix 8.8.4.0/24
set policy prefix-list GOOG rule 20 prefix 8.8.8.0/24
set policy prefix-list GOOG rule 30 prefix 34.64.0.0/10
set policy prefix-list GOOG rule 40 prefix 142.250.0.0/15
# ... (goog.json から自動生成)

# === Route-map (prefix-list GOOG に一致する static のみ広告) ===
set policy route-map GOOG-OUT rule 10 action permit
set policy route-map GOOG-OUT rule 10 match ip address prefix-list GOOG

# === BGP: static を redistribute (route-map でフィルタ必須) ===
set protocols bgp address-family ipv4-unicast redistribute static route-map GOOG-OUT
```

`redistribute static` に `route-map` を必ず付ける。付け忘れると wg 管理用等の既存 static まで r3/r1 に漏れる。

#### r1 escape route (重要)

r2-gcp の外部 IP (`34.97.197.104`) は `34.64.0.0/10` (goog.json) に含まれる。goog.json が BGP で r1 に広告されると、r1 は r2-gcp の WG endpoint 宛の外側パケットを wg1 自身に送ろうとし、**ルーティングループが発生する**。

r1 に r2-gcp endpoint の escape route を設定し、WG 外側パケットが必ず pppoe0 経由で出るようにする:

```
# r1: r2-gcp endpoint の escape route
set protocols static route 34.97.197.104/32 interface pppoe0
```

r2-gcp の外部 IP が変更された場合（VM 再作成等）、この escape route も更新が必要。

#### GCE GW host route (重要)

BGP default (AD=20, via wg1) が GCE の static default (AD=210, via eth0) に勝つと、VyOS static route の `next-hop 10.174.0.1` が wg1 経由に再帰解決され、goog.json の全 96 本の static route が wg1 にループする。

GCE GW (10.174.0.1) への /32 host route を `dev eth0` で固定し、全 next-hop の再帰解決を防止する:

```
# GCE GW host route (VyOS CLI では onlink 非対応のため kernel 直叩き)
ip route add 10.174.0.1/32 dev eth0
```

※ VyOS の `protocols static route` は `onlink` フラグ非対応。`/config/scripts/wg-r1-tracker.sh` で起動時・毎分に設定する。

#### r2 escape route (r1 WAN IP 追従)

r1 の WAN IP (PPPoE, 動的) への escape route も同様に必要。r1 の DDNS (`tukushityann.net`) を解決し、`/32 dev eth0` で固定する。`/config/scripts/wg-r1-tracker.sh` (task-scheduler 毎分) で自動追従。

#### policy local-route (r2 自身のトラフィック分離)

r2 が BGP default を受け入れると、r2 自身の通信 (SSH, API, DNS 等) も wg1 経由になる。`policy local-route` で r2 自身のトラフィック (src=10.174.0.7) を GCE GW に固定する:

```
set policy local-route rule 10 set table 200
set policy local-route rule 10 source address 10.174.0.7
set protocols static table 200 route 0.0.0.0/0 next-hop 10.174.0.1
```

※ table 200 の default route も `ip route replace default via 10.174.0.1 dev eth0 table 200` で kernel 直叩きが必要（再帰解決防止）。

#### v4 SNAT 追加 (WG トンネルアドレス)

r1/r3 の WG トンネルアドレス (10.255.x.x) から r2 経由で Google に出るトラフィック用:

```
set nat source rule 20 outbound-interface name eth0
set nat source rule 20 source address 10.255.0.0/16
set nat source rule 20 translation address masquerade
set nat source rule 20 description 'SNAT WG tunnel addresses for Google transit'
```

#### Google IP レンジ自動更新スクリプト

```bash
#!/bin/bash
# /config/scripts/update-google-prefixes.sh
# goog.json を取得し VyOS の static route と prefix-list を更新

set -euo pipefail

NEXTHOP="10.174.0.1"
URL="https://www.gstatic.com/ipranges/goog.json"
TMP=$(mktemp)

curl -sfL "$URL" -o "$TMP"

# v4 prefix を抽出
PREFIXES=$(jq -r '.prefixes[] | select(.ipv4Prefix) | .ipv4Prefix' "$TMP" | sort -u)

# vtysh で prefix-list を置き換え
vtysh -c "conf t" -c "no ip prefix-list GOOG"
RULE_NUM=10
for prefix in $PREFIXES; do
    vtysh -c "conf t" -c "ip prefix-list GOOG seq $RULE_NUM permit $prefix"
    RULE_NUM=$((RULE_NUM + 10))
done

# static route の同期は configd 経由で反映 (既存 static を洗い替え)
#   ※ 詳細実装は scripts/update-google-prefixes.sh を参照

rm -f "$TMP"
```

```
# cron: 日次で更新
set system task-scheduler task update-google-prefixes interval 24h
set system task-scheduler task update-google-prefixes executable path /config/scripts/update-google-prefixes.sh
```

#### IPv6 の扱い (BGP 広告の対象外)

`goog.json` には IPv6 prefix も 15 本含まれるが、**v6 は BGP 広告の対象としない**。v6 の振り分けは v4 とは異なる方式を採用しているためである。

| 項目 | v4 | v6 |
|------|----|----|
| 振り分け方式 | **宛先ベース** (dst で経路選択) | **送信元ベース** (src prefix で経路選択) |
| 制御点 | r3 の BGP 経路表 (goog.json を広告) | r3 の source-based PBR (セクション 4, 7 参照) |
| 前提 | 単一 GUA | デュアルプレフィックス RA (OPTAGE /64 + GCP /64) |
| 経路選択 | longest-match で BGP 経路が勝つ | クライアントの source address selection (RFC 6724) |

v6 はセクション 4「デュアルプレフィックス RA 設計」で述べた通り、会場端末に OPTAGE /64 と GCP /64 の 2 つの GUA を配布し、端末がどちらを src に選んだかによって r3 の PBR が出口を決める設計である。したがって **goog.json v6 prefix を BGP で広告する必要はなく、広告するとむしろ経路非対称が発生するリスクがある**。

##### 経路非対称の発生メカニズム

デュアル RA 環境で v6 側にも BGP (dst ベース) を追加すると、**src address と出口経路の決定ロジックが独立**するため、組み合わせによっては送信と戻りが別経路を通る:

```
[問題シナリオ] 端末が OPTAGE /64 を src に選び、dst が goog.json 該当 (例: YouTube)

送信 (r3): dst = goog 該当 → BGP longest-match で wg1 (r2-gcp) 経由
  → r2-gcp → Google backbone
    → src = OPTAGE /64 のまま Google に届く
      ↓
戻り: dst = OPTAGE /64 宛
  → Google は OPTAGE prefix を r2-gcp 経由と認識していない
    → 外部 Internet → OPTAGE → r1 → wg0 → r3 → 端末
      ↓
結果: 送信は wg1、戻りは wg0 を通る非対称経路
```

非対称経路が引き起こす具体的問題:

| 問題 | 影響 |
|------|------|
| ステートフル FW / conntrack の破綻 | r2-gcp は送信のみ、r1 は戻りのみを見るため、どちらも状態を完結して持てず戻りパケットが drop されうる |
| NAT66 state の喪失 | r2-gcp で NAT66 した場合、戻りが別経路だと un-NAT できず通信破綻 |
| トラブルシュート困難 | 片側のログだけ見ても通信の全体像が追えない |
| MTU/MSS の不整合 | wg0 (1400) と wg1 (1400) は同値だが、経路上の PMTUD が片側でしか通らない |

##### 非対称を避けるための設計選択

この問題を BGP 広告で解決するには、**r2-gcp で v6 全トラフィックに無条件 NAT66 をかけて src を r2-gcp /96 に強制変換する**か、**OPTAGE /64 の RA を停止してシングル GUA 化する**かのいずれかが必要になる。いずれも既存の「デュアル RA + src ベース PBR」の設計思想を壊し、r1 障害時の OPTAGE フォールバック経路や E2E ネイティブ v6 (OPTAGE 側) といった利点を失う。

そのため v6 は **src ベース PBR のみ** とし、BGP 広告は v4 専用とする。v6 で確実に Google backbone 経由にしたいクライアントは、GCP /64 を src に選ぶ (OS 側の設定、または明示的 bind) ことで実現する。preferred-lifetime バイアス (セクション 4) により、特に指定がない一般 Internet 通信は OPTAGE が優先される。

### 9. トラフィックフロー

#### IPv6

```
[GCP prefix src のトラフィック]
会場デバイス (<gcp-prefix>::xxxx)
  → r3 eth2.30/40
    → PBR: src = GCP /64 → table 100
      → wg1 → r2-gcp (fd00:255:2::2)
        → NAT66: src → r2-gcp /96 addr
          → eth0 → Google backbone
            → GCP サービス (VPC 内部, 無課金)
            → Internet (GCE egress, 課金)

[戻り]
Internet / GCP → Google backbone
  → dst = r2-gcp /96 addr → VM に到達 ✓
    → conntrack un-NAT66: dst → 会場デバイスの SLAAC addr
      → wg1 → r3
        → eth2.30/40 → 会場デバイス

[OPTAGE prefix src のトラフィック (従来通り)]
会場デバイス (<optage-prefix>::xxxx)
  → r3 eth2.30/40
    → デフォルトルート → wg0 → r1
      → pppoe0 → OPTAGE → Internet (NAT なし, E2E)
```

#### IPv4

```
[Google 宛 (goog.json IP レンジ: GCP + Gmail/YouTube/Search 等)]
会場デバイス (192.168.x.x)
  → r3: BGP で学習した GOOG prefix (longest-match) → wg1
    → r2-gcp: SNAT (192.168.x.x → 10.174.0.x)
      → VPC GW (10.174.0.1) → Google backbone → GCP / Google サービス

[その他 (従来通り)]
会場デバイス (192.168.x.x)
  → r3: デフォルトルート → wg0
    → r1 → OPTAGE → Internet
```

### 10. r1 障害時の動作

| 障害 | OPTAGE /64 通信 | GCP /64 通信 | v4 GCP 向け |
|------|----------------|-------------|-------------|
| r1 正常 | wg0 → r1 ✓ | wg1 → r2-gcp ✓ | wg1 → r2-gcp ✓ |
| r1 WG 断 | **断** (BGP フォールバックで r2-gcp 経由に切替) | **継続** ✓ | **継続** ✓ |
| r1 完全断 | **断** (OPTAGE 回線自体が断) | **継続** ✓ | **継続** ✓ |
| r2-gcp 断 | **継続** ✓ | **断** | v4 はデフォルト経由で継続 ✓ |

**r1 断でもハンズオン (GCP 向け) は GCP /64 経由で継続可能。** これがデュアルプレフィックス方式の最大のメリット。

### 11. コスト試算

前回実績: Out 231GB / In 190GB / Sum 421GB / Ave 117Mbps

#### GCE egress (IPv6 経由の一般 Internet)

| シナリオ | GCP prefix 利用率 | egress 量 | コスト ($0.12/GB) |
|---------|------------------|-----------|-------------------|
| 最悪 (v6 全て GCP src) | ~50% | ~210 GB | ~$25 |
| 現実的 (preferred-lifetime 誘導あり) | ~20–30% | ~85–125 GB | ~$10–15 |
| GCP 宛のみ | ~5–10% | ~20–40 GB | ~$2.5–5 |

#### インスタンスコスト

| タイプ | 月額 | 備考 |
|--------|------|------|
| e2-micro (現行) | ~$7 | 無料枠対象、WG+BGP で CPU 余裕あり |
| e2-small (推奨) | ~$14 | イベント期間のみスケールアップ |

#### 総コスト (イベント期間)

**$15–40 程度。** イベント規模に対して十分許容範囲。

### 12. 監視項目 (追加)

| 項目 | 方式 | 目的 |
|------|------|------|
| GCP /64 RA 到達確認 | r2-gcp → <gcp-prefix> 疎通チェック | RA 広告が正常か |
| PBR 動作確認 | r3 NetFlow で src prefix 別のトラフィック量 | 振り分けが想定通りか |
| GCE egress 量 | GCP Console / Cloud Monitoring | コスト監視 |
| wg1 スループット | r2-gcp iperf3 定期計測 | GCP 経路の品質 |

### 13. GCP 利用規約の確認事項

#### 関連条項: Service Specific Terms Section 2

> Customer does not use or resell the Services to **provide telecommunications connectivity**, including for **virtual private network services**, **network transport**, or **voice or data transmission**.

本設計では不特定多数のイベント参加者 (目標 200 名以上) のトラフィックを GCE インスタンス経由でルーティングするため、この条項への該当性を事前に確認する必要がある。

#### 該当性の分析

| 条項のキーワード | 本設計の状況 | 該当リスク |
|----------------|------------|-----------|
| **resell** (再販) | 無料コミュニティイベント、参加者への課金なし | 低 |
| **provide VPN services** | WireGuard は自前インフラの内部構成であり、参加者に VPN サービスを提供しているわけではない | 低 |
| **provide network transport** | 参加者のトラフィックを GCE 経由でルーティング。"provide" に読める可能性あり | 中 |
| **data transmission** | GCE が NAT66/SNAT ゲートウェイとしてデータを中継 | 中 |

#### セーフ寄りの根拠

- 条項の趣旨は GCP 上で **ISP / VPN プロバイダ / 通信キャリア事業を構築すること**の禁止
- 本設計は非営利コミュニティイベントの内部インフラであり、通信サービスの商用提供ではない
- Google 自身が GCE を NAT/VPN ゲートウェイとして使う構成を公式ドキュメントで案内している
- Cloud NAT (同等機能の有料プロダクト) を Google 自ら提供しており、GCE でのトラフィック中継は想定された利用形態

#### リスク寄りの懸念

- 不特定多数 (200 名+) の参加者トラフィックを GCE 経由でルーティングする規模
- 前回実績 421GB のうち一定割合が GCE を経由する
- "provide" の対象が社内ユーザーではなくイベント参加者 (End Users)

#### 対応: Google への事前確認 (必須)

本設計の実装前に、Google 側の担当者に利用規約への該当性を確認する。
Google DevRel Central からカメラクルー・ゲストが来場する関係性があり、GDG 活動として GCP サービスのプロモーションに寄与する文脈のため、承認される可能性は高いと思われる。

**確認のタイミング**: GCP インフラ構築開始前 (設計フェーズ中)

**Google からの回答が NG の場合のフォールバック:**

GCP トラフィック最適化 (本設計書セクション 1–12) を無効化し、r2-gcp は既存の役割 (BGP フォールバック経路 + ログ転送) のみに留める。v4/v6 ともに全トラフィックを r1 (OPTAGE) 経由とする従来構成を維持。

---

## その他の GCP 連携強化候補

以下は追加で検討中の候補。優先度に応じて個別に設計を進める。

### 1. BigQuery ストリーミング (ログ分析基盤)

**概要**: NetFlow, DNS クエリログ, DHCP リースログを BigQuery にストリーミングし、SQL ベースのリアルタイム分析基盤を構築する。

**現状の課題**:
- nfcapd のフラットファイル + nfdump CLI でしかログ検索できない
- GCS アーカイブはバックアップであり分析には使えない
- 法執行機関対応時もファイルを手動で漁る必要がある

**実現内容**:
- NetFlow, DNS クエリ, DHCP リースを BigQuery テーブルに投入
- SQL 一発で「今のトップトーカー」「特定デバイスの全通信履歴」を取得可能
- Grafana の BigQuery データソースでダッシュボード化
- 法執行対応時の照会クエリも SQL で完結

**データフロー**:
```
r3 (VyOS) → local-srv (nfcapd / rsyslog)
               ├── GCS (アーカイブ、既存)
               └── BigQuery (分析、新規)
                    ├── netflow テーブル
                    ├── dns_query テーブル
                    └── dhcp_lease テーブル
```

**投入方式の選択肢**:

| 方式 | メリット | デメリット |
|------|---------|-----------|
| local-srv から bq load (バッチ) | シンプル、既存パイプライン活用 | リアルタイム性なし (5〜15 分遅延) |
| Pub/Sub → BigQuery Subscription (ストリーミング) | リアルタイム | 構成が増える |
| Cloud Logging → Log Router → BigQuery | GCE rsyslog をそのまま活用 | Cloud Logging の ingestion 課金 |

**コスト概算** (e2-micro + 無料枠ベース):
- BigQuery: 最初の 10 GB/月ストレージ無料、1 TB/月クエリ無料
- イベント期間 (数日) のログ量であれば無料枠内に収まる見込み

**優先度**: 高 — ログ活用の質が根本的に変わる。法執行対応にも直結。

---

### 2. Cloud Monitoring 外部監視 + アラート

**概要**: GCP Cloud Monitoring から会場ネットワークの死活・品質を外部監視し、障害時に自動アラートを発報する。

**現状の課題**:
- Grafana は会場内部からの監視のみ
- WireGuard トンネル断やルーター障害を外部から検知する手段がない
- 障害に気づくのが手動 (NOC メンバーがダッシュボードを見ている時のみ)

**実現内容**:
- **Uptime Check**: r2-gcp 経由で r3 の死活監視 (ICMP / TCP)
- **カスタムメトリクス**: BGP セッション状態、WireGuard ハンドシェイク経過時間を r2-gcp から push
- **アラートポリシー**: トンネルダウン、BGP セッションダウン → Slack / PagerDuty 通知
- **SLI/SLO**: トンネル可用性を定量的にトラッキング

**監視項目**:

| 項目 | 方式 | アラート条件 |
|------|------|-------------|
| r3 死活 | r2-gcp → r3 ICMP (10.255.2.1) | 3 回連続失敗 |
| WireGuard r1↔r3 | r2-gcp から BGP 経路の有無で判定 | r1-r3 直接経路消失 |
| WireGuard r2↔r3 | r2-gcp wg1 ハンドシェイク経過時間 | 3 分超過 |
| BGP セッション | r2-gcp の BGP neighbor state | Established 以外 |

**コスト**: Uptime Check 無料枠あり (月 100 万回)。カスタムメトリクスも少量なら無料枠内。

**優先度**: 高 — 運用信頼性の向上。Google DevRel の前でのダウンを防ぐ。

---

### 3. リアルタイムイベントダッシュボード

**概要**: 会場スクリーンに映せるリアルタイムネットワーク可視化ダッシュボードを構築する。

**現状の課題**:
- 既存 Grafana はインフラ監視用で、来場者やカメラ向けの見栄えではない
- イベントの「技術力」を視覚的にアピールする手段がない

**実現内容**:
- 接続デバイス数の推移 (リアルタイム)
- トラフィック量のライブグラフ (Mbps)
- DNS クエリのトップドメイン (ランキング or ワードクラウド)
- BGP 経路状態のビジュアライズ (3 拠点トポロジ)
- WireGuard トンネルの遅延・スループット

**実装方式**:
- BigQuery (候補 1) があれば、Grafana の BigQuery データソースで追加ダッシュボードを作成
- GCE 上の既存 Grafana (外部公開済み) をそのまま利用可能
- Looker Studio も選択肢 (Google プロダクトとしてのデモ価値)

**前提**: 候補 1 (BigQuery) の導入が前提。BigQuery なしの場合は既存 Prometheus メトリクスのみで構成。

**優先度**: 中 — カメラ映えする。BigQuery があれば追加工数は小さい。

---

### 4. GCE ネットワーク品質監視 (smokeping / iperf3)

**概要**: r2-gcp から会場・自宅への常時パフォーマンス計測を行い、トンネル品質を可視化する。

**現状の課題**:
- トンネルの遅延・ジッタ・パケットロスを定量的に把握する手段がない
- 品質劣化に事後的にしか気づけない

**実現内容**:
- **smokeping**: r2-gcp → r3, r2-gcp → r1 への ICMP 遅延・ジッタ・パケロスを常時計測
- **iperf3 定期測定**: 5〜15 分間隔でスループット計測
- Grafana ダッシュボードに品質メトリクスを統合

**構成**:
```
r2-gcp (GCE e2-micro)
  ├── smokeping → r3 (10.255.2.1), r1 (10.255.1.1)
  ├── iperf3 client → r3 iperf3 server (定期)
  └── メトリクス → Prometheus → Grafana
```

**コスト**: r2-gcp (e2-micro) に追加インストールするだけ。追加コストなし。

**優先度**: 中 — r2-gcp に載せるだけで効果大。工数も小さい。

---

### 5. Pub/Sub → Cloud Functions リアルタイムパイプライン

**概要**: ログを Pub/Sub 経由で Cloud Functions に流し、リアルタイムのイベント駆動処理を実現する。

**現状の課題**:
- ログ処理がバッチ (rsync 15 分間隔) で、リアルタイム性がない
- 異常検知やアラートが手動

**実現内容**:
- rsyslog → Pub/Sub トピックにログを publish
- Cloud Functions (サブスクライバー) でリアルタイム処理:
  - 異常トラフィックパターン検知 (特定ポートへの大量接続等)
  - DHCP プール枯渇アラート (残りアドレス数監視)
  - Slack/Discord への自動通知

**データフロー**:
```
local-srv (rsyslog)
  → Pub/Sub トピック
    → Cloud Functions (異常検知)
      → Slack / Cloud Monitoring アラート
    → BigQuery Subscription (分析)
```

**コスト**: Cloud Functions 無料枠 (月 200 万回呼び出し)、Pub/Sub 無料枠 (月 10 GB) で収まる見込み。

**優先度**: 低 — BigQuery のスケジュールクエリや Cloud Monitoring で代替可能な部分が多い。

---

### 6. Gemini API 自然言語ログクエリ

**概要**: Gemini API を使って「過去 1 時間のトップトーカーは？」のような自然言語でログを検索できるインターフェースを構築する。

**現状の課題**:
- ログ検索には nfdump コマンドや SQL の知識が必要
- NOC メンバー全員がクエリを書けるわけではない

**実現内容**:
- 自然言語 → Gemini が BigQuery SQL を生成 → 実行 → 結果返却
- Slack bot や Web UI から利用
- 例: 「14:30 に example.com にアクセスしたデバイスは？」→ DNS + DHCP を cross join した結果を返す

**前提**: 候補 1 (BigQuery) の導入が前提。

**デモ価値**: Google DevRel の場で Gemini + BigQuery の組み合わせを実運用で見せられるのはインパクト大。ただし実用性に対して工数が大きい。

**コスト**: Gemini API (Vertex AI) の従量課金。イベント期間中の利用量であれば軽微。

**優先度**: 低 — デモとしては面白いが、実運用での必要性は薄い。

---

## 優先度サマリ

| 優先度 | 候補 | 主な価値 | 前提 |
|--------|------|---------|------|
| **高** | 1. BigQuery ストリーミング | ログ分析の質が根本的に向上 | — |
| **高** | 2. Cloud Monitoring + アラート | 外部監視で運用信頼性向上 | — |
| **中** | 3. リアルタイムダッシュボード | カメラ映え、イベント価値向上 | 候補 1 |
| **中** | 4. GCE 品質監視 (smokeping) | トンネル品質の定量化 | — |
| **低** | 5. Pub/Sub パイプライン | リアルタイムイベント駆動 | 候補 1 |
| **低** | 6. Gemini 自然言語クエリ | デモインパクト | 候補 1 |
