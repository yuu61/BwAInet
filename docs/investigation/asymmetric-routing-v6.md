# IPv6 で goog.json を BGP 広告しない理由 (経路非対称の回避)

IPv4 の Google 宛トラフィックは `goog.json` を r2-gcp が BGP 広告して dst ベースで最適化するが、**IPv6 では BGP 広告しない**。理由は経路非対称 (asymmetric routing) が発生し、conntrack/NAT66 の state 管理が破綻するため。

## v4 と v6 の振り分け方式の差

| 項目 | v4 | v6 |
|------|----|----|
| 振り分け方式 | **宛先ベース** (dst で経路選択) | **送信元ベース** (src prefix で経路選択) |
| 制御点 | r3 の BGP 経路表 (goog.json を広告) | r3 の source-based PBR |
| 前提 | 単一 GUA | デュアルプレフィックス RA (OPTAGE /64 + GCP /64) |
| 経路選択 | longest-match で BGP 経路が勝つ | クライアントの source address selection (RFC 6724) |

v6 はデュアル RA で会場端末に OPTAGE /64 と GCP /64 の 2 つの GUA を配布し、端末がどちらを src に選んだかによって r3 の PBR が出口を決める設計。したがって goog.json の v6 prefix を BGP で広告する必要はなく、**広告するとむしろ経路非対称が発生するリスクがある**。

## 経路非対称の発生メカニズム

デュアル RA 環境で v6 側にも BGP (dst ベース) を追加すると、src address と出口経路の決定ロジックが独立するため、組み合わせによっては送信と戻りが別経路を通る。

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

## 非対称経路が引き起こす問題

| 問題 | 影響 |
|------|------|
| ステートフル FW / conntrack の破綻 | r2-gcp は送信のみ、r1 は戻りのみを見るため、どちらも状態を完結して持てず戻りパケットが drop されうる |
| NAT66 state の喪失 | r2-gcp で NAT66 した場合、戻りが別経路だと un-NAT できず通信破綻 |
| トラブルシュート困難 | 片側のログだけ見ても通信の全体像が追えない |
| MTU/MSS の不整合 | wg0 (1400) と wg1 (1400) は同値だが、経路上の PMTUD が片側でしか通らない |

## 非対称を避けるための設計選択肢 (採用しない)

この問題を BGP 広告で解決するには以下のいずれかが必要になる。

1. **r2-gcp で v6 全トラフィックに無条件 NAT66 をかけて src を r2-gcp /96 に強制変換する**
2. **OPTAGE /64 の RA を停止してシングル GUA 化する**

いずれも「デュアル RA + src ベース PBR」の設計思想を壊し、r1 障害時の OPTAGE フォールバック経路や E2E ネイティブ v6 (OPTAGE 側) といった利点を失う。

## 結論

**v6 は src ベース PBR のみ、BGP 広告は v4 専用**。v6 で確実に Google backbone 経由にしたいクライアントは、GCP /64 を src に選ぶ (OS 側の設定、または明示的 bind) ことで実現する。preferred-lifetime バイアスにより、特に指定がない一般 Internet 通信は OPTAGE が優先される。

## 関連

- [`../design/gcp-integration.md`](../design/gcp-integration.md) — GCP 連携強化設計
- [`../design/venue-vyos.md`](../design/venue-vyos.md) — r3 のデュアル RA と PBR
- [`../operations/goog-prefix-update.md`](../operations/goog-prefix-update.md) — goog.json 更新運用
- [`gcp-v6-prefix-constraint.md`](gcp-v6-prefix-constraint.md) — NAT66 が必要な理由
