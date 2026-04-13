# GCP トラフィック最適化のコスト試算

r2-gcp (GCE 大阪) 経由の IPv6/IPv4 最適化における GCE egress 料金と VM インスタンスコストの試算。前提は [`../design/gcp-integration.md`](../design/gcp-integration.md) を参照。

## 前回実績

| 項目 | 値 |
|------|-----|
| Out | 231 GB |
| In | 190 GB |
| Sum | 421 GB |
| Average | 117 Mbps |

## GCE egress (IPv6 経由の一般 Internet)

| シナリオ | GCP prefix 利用率 | egress 量 | コスト ($0.12/GB) |
|---------|------------------|-----------|-------------------|
| 最悪 (v6 全て GCP src) | ~50% | ~210 GB | ~$25 |
| 現実的 (preferred-lifetime 誘導あり) | ~20–30% | ~85–125 GB | ~$10–15 |
| GCP 宛のみ | ~5–10% | ~20–40 GB | ~$2.5–5 |

preferred-lifetime を短く設定すると RFC 6724 で OS が OPTAGE を優先するため、GCP /64 src の選択率が下がり egress も下がる。

## インスタンスコスト

| タイプ | 月額 | 備考 |
|--------|------|------|
| e2-micro (現行) | ~$7 | 無料枠対象、WG+BGP で CPU 余裕あり |
| **e2-small (推奨)** | **~$14** | イベント期間のみスケールアップ |

NAT66 + ルーティング負荷を考慮すると、イベント期間中は e2-small に引き上げが推奨。

## 総コスト (イベント期間)

**$15–40 程度**。イベント規模 (200 名) に対して十分許容範囲。

## 関連

- [`../design/gcp-integration.md`](../design/gcp-integration.md) — GCP トラフィック最適化設計
- [`gcp-future-enhancements.md`](gcp-future-enhancements.md) — BigQuery 等の追加コスト
