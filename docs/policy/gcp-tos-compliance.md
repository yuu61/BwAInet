# GCP 利用規約への該当性分析

GCP トラフィック最適化設計 ([`../design/gcp-integration.md`](../design/gcp-integration.md)) では r2-gcp (GCE) を介してイベント参加者のトラフィックを中継するため、GCP の Service Specific Terms への該当性を事前確認する必要がある。

## 関連条項: Service Specific Terms Section 2

> Customer does not use or resell the Services to **provide telecommunications connectivity**, including for **virtual private network services**, **network transport**, or **voice or data transmission**.

本設計では不特定多数のイベント参加者 (目標 200 名以上) のトラフィックを GCE インスタンス経由でルーティングするため、この条項への該当性を事前に確認する必要がある。

## 該当性の分析

| 条項のキーワード | 本設計の状況 | 該当リスク |
|----------------|------------|-----------|
| **resell** (再販) | 無料コミュニティイベント、参加者への課金なし | 低 |
| **provide VPN services** | WireGuard は自前インフラの内部構成であり、参加者に VPN サービスを提供しているわけではない | 低 |
| **provide network transport** | 参加者のトラフィックを GCE 経由でルーティング。"provide" に読める可能性あり | 中 |
| **data transmission** | GCE が NAT66/SNAT ゲートウェイとしてデータを中継 | 中 |

## セーフ寄りの根拠

- 条項の趣旨は GCP 上で **ISP / VPN プロバイダ / 通信キャリア事業を構築すること**の禁止
- 本設計は非営利コミュニティイベントの内部インフラであり、通信サービスの商用提供ではない
- Google 自身が GCE を NAT/VPN ゲートウェイとして使う構成を公式ドキュメントで案内している
- Cloud NAT (同等機能の有料プロダクト) を Google 自ら提供しており、GCE でのトラフィック中継は想定された利用形態

## リスク寄りの懸念

- 不特定多数 (200 名+) の参加者トラフィックを GCE 経由でルーティングする規模
- 前回実績 421GB のうち一定割合が GCE を経由する
- "provide" の対象が社内ユーザーではなくイベント参加者 (End Users)

## 対応: Google への事前確認 (必須)

本設計の実装前に、Google 側の担当者に利用規約への該当性を確認する。Google DevRel Central からカメラクルー・ゲストが来場する関係性があり、GDG 活動として GCP サービスのプロモーションに寄与する文脈のため、承認される可能性は高いと思われる。

**確認のタイミング**: GCP インフラ構築開始前 (設計フェーズ中)

## NG 時のフォールバック

Google からの回答が NG の場合:

- GCP トラフィック最適化 ([`../design/gcp-integration.md`](../design/gcp-integration.md) §1–12) を無効化
- r2-gcp は既存の役割 (BGP フォールバック経路 + ログ転送) のみに留める
- v4/v6 ともに全トラフィックを r1 (OPTAGE) 経由とする従来構成を維持

## 関連

- [`../design/gcp-integration.md`](../design/gcp-integration.md) — GCP 連携強化設計
- [`../investigation/gcp-cost-estimation.md`](../investigation/gcp-cost-estimation.md) — コスト試算
- [`logging-policy.md`](logging-policy.md) — ログ保存ポリシー
