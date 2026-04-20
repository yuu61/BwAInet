# インシデント記録: GCP DoS 検知 (2026-04-19)

## 概要

GCP プロジェクト `BwAI-NOC (id: bwai-noc)` の VM `r2-gcp` (asia-northeast2-a) について、イベント本番当日に Google Cloud Trust & Safety から「サービス拒否（DoS）攻撃の疑い」として 2 度目の警告通知が届いた。前回 (2026-04-09) と同様、スタッフ端末による Google CDN からの大容量ダウンロードが r2-gcp の GCE egress カウンタを押し上げたことによる誤検知。

| 項目 | 内容 |
|---|---|
| 検知時刻 | 2026-04-18 23:19 – 23:22 PT (= 2026-04-19 15:19 – 15:22 JST) |
| 検知元 IP | 34.97.197.104 (r2-gcp 外部 IP) |
| プロジェクト | BwAI-NOC (id: bwai-noc) |
| 通知元 | Google Cloud Platform / API Trust & Safety |
| 受信日時 | 2026-04-19 15:39 JST |
| 警告内容 | 72 時間以内に対応しない場合、関連リソースを停止する |
| 関連イベント | Build with AI Kwansai 2026 (GDG Greater Kwansai 共催、同日開催) |
| 最終ステータス | 異議申立て送信済、r2-gcp は後日削除予定 |

## 原因

### 加害トラフィック (nfdump 実測)

VLAN 30 (STAFF) のスタッフ端末が Google Edge Cache から HTTP/80 で単一 TCP コネクション 1 本による大容量ダウンロードを実行した。

| 項目 | 値 |
|---|---|
| 発生時刻 (UTC) | 2026-04-19 06:19:07 – 06:22:41 |
| 継続時間 | 3 分 36 秒 + 2.7 秒の追加バースト |
| Src (Google 側) | `34.104.35.123:80` (TCP) |
| Dst (クライアント) | `192.168.30.13:2929` |
| PTR | `123.35.104.34.bc.googleusercontent.com` |
| HTTP Server ヘッダ | `Server: Google-Edge-Cache` |
| 転送量 | 4.3 GB + 66 MB (単一 TCP 1 本) |
| 平均レート | ~160 Mbps |
| ピークレート | ~190 Mbps (2.7 秒バースト) |
| TCP フラグ | 通常の SYN → data → FIN (SYN flood や fan-out なし) |

クライアント端末情報:

- IP: `192.168.30.13` (VLAN 30 STAFF プール)
- MAC: `a8:59:5f:4b:30:61` (Intel Corporate)
- hostname: `2240153s` (学籍番号形式)

### 経路と DoS 発火メカニズム

34.104.0.0/16 は `goog.json` で配布される Google 所有 IPv4 プレフィックスの 1 つ。r2-gcp が goog.json の 96 本の v4 プレフィックスを r3 に BGP 広告しているため、Google 宛トラフィックは r2-gcp 経由で流れる設計になっている。

```
Google Edge Cache (34.104.35.123:80)
      → r2-gcp (34.97.197.104)   ★ GCE egress として 4.3 GB 計上
      → WireGuard (wg0/wg1)
      → r3-venue eth2.30
      → 192.168.30.13 (イベントスタッフ端末)
```

GCE 側から見ると「r2-gcp が 4.3 GB を外向に送出した」ように計上されるが、実際はクライアント発の HTTP ダウンロードの戻り経路を中継しただけ。r2-gcp 自身は新規セッションを開始していない。

### DL 内容 (推定)

DNS クエリログは rec_control 出力のみで hostname 特定不可。ただし以下の状況証拠から Google 配信の SDK・モデル・コンテナ image である可能性が高い:

- 当日は Build with AI Kwansai 2026 (GDG 共催) のハンズオン開催中
- 主題は Gemini / Google AI Studio / Agent tooling
- HTTP/80 + Google Edge Cache + 4.3 GB 規模
- Android SDK / Emulator image, Flutter SDK, Play Store APK, Cloud Storage 公開バケット等が候補

## shaper 状態

`WG-EGRESS-500M` policy の定義は r2-gcp に残存しているが、`interface wg1/wg2 egress` への適用は 2026-04-09 インシデント対応後のマシンタイプアップグレード (e2-micro → e2-standard-2) と同時に解除されていた (想定どおり)。

```
qos:
  interface: { wg1: {}, wg2: {} }       # egress 未適用
  policy:
    shaper:
      WG-EGRESS-500M:
        bandwidth: 500mbit
        default: { bandwidth: 100%, queue-type: fair-queue }
```

## 対応経緯

| 日時 (JST) | 出来事 |
|---|---|
| 2026-04-19 11:30 | Build with AI Kwansai 2026 開演 |
| 2026-04-19 15:19 | 192.168.30.13 が 34.104.35.123 から HTTP DL 開始 (4.3 GB) |
| 2026-04-19 15:22 | DL 完了 |
| 2026-04-19 15:39 | GCP から警告メール受信 |
| 2026-04-19 19:00 | イベント終了 |
| 2026-04-19 | 調査 (nfdump, VyOS API, MAC OUI, HTTP HEAD) → 原因特定 |
| 2026-04-19 | 異議申立て送信 (ticket: TBD) |

## 異議申立ての骨子

送信済みの英文申立ての要旨:

1. **イベント文脈**: Google 公式 GDG コミュニティの Build with AI シリーズ、同日開催
2. **ネットワーク設計**: r1-home (default) と r2-gcp (goog.json の 96 本を広告) の 2 ゲートウェイ分離。Google 宛のみ r2-gcp 経由で shortest path
3. **今回の挙動**: 34.104.35.123 が 34.104.0.0/16 に該当するため r2-gcp 経由が選択された。クライアント発の inbound CDN DL の戻り経路を中継したに過ぎない
4. **NetFlow 証跡**: 単一 TCP 1 本、SYN flood・fan-out なし、DoS パターンではない
5. **前回チケット**: M63NU6H33XEMJYWR7H7JT5NDIM を引用し同型の false positive であることを説明
6. **今後の措置**: イベント終了により r2-gcp は削除予定。GCS forensic bucket (180 日保持) はプロジェクトに残すので project-level suspension は避けてほしい旨を明記

## 教訓

### 主要な反証: マシンタイプアップグレードは DoS 検知対策ではない

2026-04-09 是正計画では、本番当日に「e2-micro → e2-standard-2 にアップグレードして shaper を解除」する手順を組んでいた。その前提は **「マシンタイプ up で egress 上限 (2 Gbps → 10 Gbps) が上がるなら、GCP の DoS 検知しきい値も連動するはず」** という仮説。

仮説の合理性:

- GCP の他の制限値 (IOPS, 接続数, メモリ, CPU) は大半がマシンタイプ比例
- egress 帯域上限も vCPU 数比例
- 「Google が許容した帯域を使っただけで DoS 扱い」は論理矛盾のはず

今回の反証:

| 指標 | 04-09 事案 | 04-19 事案 |
|---|---|---|
| peak | ~2 Gbps | **190 Mbps** |
| マシンタイプ | e2-micro (2 Gbps cap) | e2-standard-2 (10 Gbps cap) |
| capacity 比 | ~100% | **~1.9%** |
| 検知 | 発火 | **発火** |

capacity 比が 1/50 になっても発火した以上、**Trust & Safety の判定はマシンタイプに連動していない**ことが経験的に確定した。おそらく以下のいずれかで動いている:

- 絶対 egress 量 (bytes/min 固定しきい値)
- プロジェクト既往歴による感度上昇 (一度 flag されたプロジェクトは bar が下がる)

### 修正された設計原則

- **shaper はパフォーマンス調整ではなく「コンプライアンス境界」として扱う**。マシンタイプ up で外してはいけない
- **GCP DoS 検知しきい値は非公開・可変・既往歴依存**。検知してほしい数字より十分低い位置で自主規制する
- **マシンタイプ up と shaper 解除は独立判断**。A (CPU 性能) のために B (egress 制限) を外す理由は無い

### 今回採用しなかった対策 (本番後のため)

通常なら以下を実施すべきだが、イベントが終了し r2-gcp を削除するため不要:

- shaper 再投入 (1–2 Gbps で再適用)
- Cloud Monitoring アラート (instance/network/sent_bytes を分単位で監視)
- goog.json BGP 広告範囲の縮小 (CDN 系プレフィックスを除外して直接経路に寄せる)

### 運用ドキュメント化できた知見

- `34.104.0.0/16` は Google Cloud Edge Cache (汎用 CDN front-end) に使われる。`googleusercontent.com` の PTR だけでは customer VM と誤認しやすいが、HTTP レスポンスの `Server:` ヘッダで判別可能
- nfdump + NetFlow v9 アーカイブは 3–4 分の sub-burst 特定にも実用的。異議申立ての証跡として有効
- DNS は rec_control 出力のみ保存しているため、client の名前解決歴を事後再現する手段が無い。必要なら query logging を有効化する選択肢がある (プライバシー / ボリュームとのトレードオフ)

## 関連ドキュメント

- [インシデント記録: GCP DoS 検知 (2026-04-09)](./incident-2026-04-09-gcp-dos-detection.md) — 前回事案、同型の false positive
- [GCP 連携設計](../design/gcp-integration.md)
- [会場 VyOS 設計](../design/venue-vyos.md)
- [ログ保存ポリシー](../policy/logging-policy.md) — GCS forensic bucket の 180 日保持規定
