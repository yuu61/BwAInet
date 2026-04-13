# GCP 連携の追加候補 (検討中)

GCP トラフィック最適化 ([`../design/gcp-integration.md`](../design/gcp-integration.md)) に加えて、検討中の GCP 連携強化候補の一覧。優先度に応じて個別に設計を進める。

## 優先度サマリ

| 優先度 | 候補 | 主な価値 | 前提 |
|--------|------|---------|------|
| **高** | 1. BigQuery ストリーミング | ログ分析の質が根本的に向上 | — |
| **高** | 2. Cloud Monitoring + アラート | 外部監視で運用信頼性向上 | — |
| **中** | 3. リアルタイムダッシュボード | カメラ映え、イベント価値向上 | 候補 1 |
| **中** | 4. GCE 品質監視 (smokeping) | トンネル品質の定量化 | — |
| **低** | 5. Pub/Sub パイプライン | リアルタイムイベント駆動 | 候補 1 |
| **低** | 6. Gemini 自然言語クエリ | デモインパクト | 候補 1 |

## 1. BigQuery ストリーミング (ログ分析基盤)

NetFlow, DNS クエリログ, DHCP リースログを BigQuery にストリーミングし、SQL ベースのリアルタイム分析基盤を構築する。

**現状の課題**:
- nfcapd のフラットファイル + nfdump CLI でしかログ検索できない
- GCS アーカイブはバックアップであり分析には使えない
- 法執行機関対応時もファイルを手動で漁る必要がある

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

**コスト**: BigQuery 最初の 10 GB/月ストレージ無料、1 TB/月クエリ無料。イベント期間のログ量であれば無料枠内。

## 2. Cloud Monitoring 外部監視 + アラート

**現状の課題**:
- Grafana は会場内部からの監視のみ
- WireGuard トンネル断やルーター障害を外部から検知する手段がない

**監視項目**:

| 項目 | 方式 | アラート条件 |
|------|------|-------------|
| r3 死活 | r2-gcp → r3 ICMP (10.255.2.1) | 3 回連続失敗 |
| WireGuard r1↔r3 | r2-gcp から BGP 経路の有無で判定 | r1-r3 直接経路消失 |
| WireGuard r2↔r3 | r2-gcp wg1 ハンドシェイク経過時間 | 3 分超過 |
| BGP セッション | r2-gcp の BGP neighbor state | Established 以外 |

**コスト**: Uptime Check 無料枠あり (月 100 万回)。カスタムメトリクスも少量なら無料枠内。

## 3. リアルタイムイベントダッシュボード

会場スクリーンに映せるリアルタイムネットワーク可視化ダッシュボード。

**実現内容**:
- 接続デバイス数の推移 (リアルタイム)
- トラフィック量のライブグラフ (Mbps)
- DNS クエリのトップドメイン (ランキング or ワードクラウド)
- BGP 経路状態のビジュアライズ (3 拠点トポロジ)

**前提**: 候補 1 (BigQuery) 導入が前提。BigQuery なしでは既存 Prometheus メトリクスのみで構成。

## 4. GCE ネットワーク品質監視 (smokeping / iperf3)

r2-gcp から会場・自宅への常時パフォーマンス計測。

**構成**:
```
r2-gcp (GCE)
  ├── smokeping → r3 (10.255.2.1), r1 (10.255.1.1)
  ├── iperf3 client → r3 iperf3 server (定期)
  └── メトリクス → Prometheus → Grafana
```

**コスト**: r2-gcp に追加インストールのみ。追加コストなし。

## 5. Pub/Sub → Cloud Functions リアルタイムパイプライン

rsyslog → Pub/Sub → Cloud Functions で、異常トラフィックパターン検知・DHCP プール枯渇アラート・Slack 通知等。

**コスト**: Cloud Functions 無料枠 (月 200 万回)、Pub/Sub 無料枠 (月 10 GB) で収まる見込み。

**評価**: BigQuery のスケジュールクエリや Cloud Monitoring で代替可能な部分が多い。

## 6. Gemini API 自然言語ログクエリ

自然言語 → Gemini が BigQuery SQL を生成 → 実行 → 結果返却。Slack bot や Web UI から利用。

例: 「14:30 に example.com にアクセスしたデバイスは？」→ DNS + DHCP を cross join した結果を返す。

**前提**: 候補 1 (BigQuery) 導入が前提。

**評価**: Google DevRel の場で Gemini + BigQuery の組み合わせを実運用で見せられるのはインパクト大。ただし実用性に対して工数が大きい。

## 関連

- [`../design/gcp-integration.md`](../design/gcp-integration.md) — 確定済み GCP 連携設計
- [`gcp-cost-estimation.md`](gcp-cost-estimation.md) — 現行 GCP 最適化のコスト試算
