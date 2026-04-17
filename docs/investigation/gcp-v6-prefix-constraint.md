# GCP IPv6 プレフィックス制約と NAT66 採用の根拠

GCP 上の r2-gcp を経由して IPv6 トラフィックを中継する際、GCP データプレーンの制約により **NAT66 が必須** となる。回避策を広範に調査した結果、いずれも IPv4 のみ対応で IPv6 では利用できないことを確認した。

## GCP IPv6 プレフィックス階層

| レベル | プレフィックス | 割り当て |
|--------|-------------|---------|
| VPC | /48 | ULA (`fd20::/20`) または GUA (Google リージョナル) |
| サブネット | /64 | VPC の /48 から切り出し |
| **VM** | **/96** | サブネットの /64 から自動割り当て (これ以上は不可) |

## /64 を r3 まで持ってこれない理由

GCP データプレーンは、サブネットの /64 内で **VM の /96 に割り当てられていないアドレス宛のパケットをドロップする**:

> "If the packet's destination isn't associated with a resource or belongs to a stopped VM, the packet is dropped."
> — [GCP VPC Routes ドキュメント](https://docs.cloud.google.com/vpc/docs/routes)

会場デバイスが SLAAC で生成するアドレスは r2-gcp の /96 外であるため、Internet からの戻りパケットが GCP で drop される。

```
サブネット /64: 2600:1901:xxxx:yyyy::/64
  ├── r2-gcp VM:  2600:1901:xxxx:yyyy:0:0:0:4/96  ← GCP がルーティング可能
  └── 会場デバイス: 2600:1901:xxxx:yyyy:<random>/64 ← GCP が drop
```

## 回避策の調査結果

| 回避策 | IPv6 対応 | 備考 |
|--------|:---------:|------|
| カスタム静的ルートで /64 → VM | × | サブネットルートと重複するルートは作成不可 |
| Alias IP ranges で /64 全体を VM に | × | IPv4 のみ対応 |
| NCC Router Appliance + Cloud Router | × | IPv4 only |
| Hybrid Subnet (VM 外アドレスを VPN 転送) | × | IPv4 only (コンセプトは理想的だが v6 非対応) |
| HA VPN + Cloud Router | ○ | IPv6 対応だが、サブネットルーティングの drop は回避不可 |

いずれも E2E ネイティブ v6 での透過中継は不可能と結論。

## NAT66 による解決

r2-gcp で **NAT66 (snat prefix to /96)** を行い、会場デバイスの src アドレスを r2-gcp の /96 アドレス範囲に変換する。

- `snat prefix to` はプレフィックス変換方式で、元アドレスの IID 下位 32bit を保持しつつ上位 96bit を書き換える
- 戻りパケットは r2-gcp の /96 宛となるため、GCP が正しくルーティングする
- IID 下位 32bit 衝突は SLAAC ランダム生成のため会場規模では事実上発生しない (法執行対応では引き続き conntrack ログを記録)

## NAT66 の影響

| 項目 | 影響 |
|------|------|
| Internet から見た src | r2-gcp の /96 アドレス (会場デバイスの実アドレスは見えない) |
| 会場内の通信 | 影響なし (NAT は r2-gcp 通過時のみ) |
| ログ追跡 | r2-gcp の NAT テーブル (conntrack) の参照が必要 |
| デュアル RA の価値 | 維持 — PBR による経路分離、r1 障害時の GCP 経由継続は機能する |

## 関連

- [`../design/gcp-integration.md`](../design/gcp-integration.md) — GCP 連携強化設計
- [`ncc-transit-routing-investigation.md`](ncc-transit-routing-investigation.md) — NCC 経由の調査
- [`asymmetric-routing-v6.md`](asymmetric-routing-v6.md) — v6 BGP を広告しない理由
