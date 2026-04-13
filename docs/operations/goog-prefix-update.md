# Google IP プレフィックス自動更新手順

r2-gcp から Google backbone 経由のトラフィックを最適化するため、`goog.json` の IPv4 プレフィックスを static route + BGP prefix-list として定期更新する。設計は [`../design/gcp-integration.md`](../design/gcp-integration.md)、規約確認は [`../policy/gcp-tos-compliance.md`](../policy/gcp-tos-compliance.md) を参照。

## 更新対象

| リスト | 件数 (v4/v6) | 内容 | BwAI での扱い |
|--------|------------|------|---|
| `cloud.json` | 1,074 / 66 | リージョン別細粒度 | 使用しない |
| **`goog.json`** | **94 / 15** | Google 全体の集約済み prefix | **BGP 広告対象 (v4 のみ)** |

v6 は BGP 広告しない (src-based PBR で振り分けるため、dst-based BGP と競合する)。詳細は [`../investigation/asymmetric-routing-v6.md`](../investigation/asymmetric-routing-v6.md) を参照。

## `update-google-prefixes.sh` (r2-gcp)

**配置先**: `/config/scripts/update-google-prefixes.sh`
**実行間隔**: 1 日ごと (VyOS task-scheduler)

```bash
#!/bin/bash
set -euo pipefail

NEXTHOP="10.174.0.1"  # GCP VPC GW
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
# 詳細実装は scripts/update-google-prefixes.sh を参照

rm -f "$TMP"
```

### task-scheduler 登録

```
set system task-scheduler task update-google-prefixes interval 24h
set system task-scheduler task update-google-prefixes executable path /config/scripts/update-google-prefixes.sh
```

## BGP 広告の仕組み (重要)

r2-gcp には既に default route (`0.0.0.0/0 via 10.174.0.1`) があり Google backbone に到達できるが、**BGP は RIB に存在する prefix しか広告しない**。そこで goog.json の各 prefix を **static route として next-hop=VPC GW** で作成し、BGP 広告の材料として RIB に載せる。

- **next-hop に `Null0` (blackhole) を使ってはならない** — RIB には載るが FIB で drop、実トラフィック全損
- **next-hop は必ず VPC GW = `10.174.0.1`**

### 関連設定 (静的、一度だけ)

```
# Route-map (prefix-list GOOG に一致する static のみ広告)
set policy route-map GOOG-OUT rule 10 action permit
set policy route-map GOOG-OUT rule 10 match ip address prefix-list GOOG

# BGP: static を redistribute (route-map でフィルタ必須)
set protocols bgp address-family ipv4-unicast redistribute static route-map GOOG-OUT
```

`redistribute static` に `route-map` を必ず付ける。付け忘れると wg 管理用等の既存 static まで r3/r1 に漏れる。

## r1 側の allowed-ips 連動更新 (必須)

r1 の wg1 peer r2-gcp の `allowed-ips` にも goog.json v4 プレフィックスを追加する必要がある。追加しないと WG の crypto routing で Google 宛パケットがドロップされる。

```
set interfaces wireguard wg1 peer r2-gcp allowed-ips 8.8.8.0/24
set interfaces wireguard wg1 peer r2-gcp allowed-ips 34.64.0.0/10
# ... (goog.json v4 全 94 本)
```

goog.json 更新時には r1 の allowed-ips も連動して更新する必要がある。

## r1 escape route (ルーティングループ防止)

r2-gcp の外部 IP (`34.97.197.104`) は `34.64.0.0/10` (goog.json) に含まれる。goog.json が BGP で r1 に広告されると、r1 は r2-gcp WG endpoint 宛の外側パケットを wg1 自身に送ろうとし、**ルーティングループ**が発生する。

r1 で以下を設定する。r2-gcp の外部 IP が変更された場合 (VM 再作成等) は更新が必要。

```
set protocols static route 34.97.197.104/32 interface pppoe0
```

## 関連

- [`../design/gcp-integration.md`](../design/gcp-integration.md) — GCP トラフィック最適化設計
- [`../design/venue-vyos.md`](../design/venue-vyos.md) — r3 BGP 経路優先度
- [`../design/home-vyos.md`](../design/home-vyos.md) — r1 BGP と escape route
- [`../investigation/asymmetric-routing-v6.md`](../investigation/asymmetric-routing-v6.md) — v6 BGP を広告しない理由
- [`../policy/gcp-tos-compliance.md`](../policy/gcp-tos-compliance.md) — GCP 利用規約該当性
