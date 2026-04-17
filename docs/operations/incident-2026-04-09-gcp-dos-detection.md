# インシデント記録: GCP DoS 検知 (2026-04-09)

## 概要

GCP プロジェクト `BwAI-NOC (id: bwai-noc)` の VM `r2-gcp` (asia-northeast2-a) について、Google Cloud Trust & Safety から「サービス拒否（DoS）攻撃の疑い」として警告通知が届いた。

| 項目 | 内容 |
|---|---|
| 検知時刻 | 2026-04-09 06:52 PT (= 2026-04-09 22:52 JST) |
| 検知元 IP | 34.97.197.104 (r2-gcp 外部 IP) |
| プロジェクト | BwAI-NOC (id: bwai-noc) |
| 通知元 | Google Cloud Platform / API Trust & Safety |
| 受信日時 | 2026-04-10 |
| 警告内容 | 72 時間以内に対応しない場合、関連リソースを停止する |
| Appeal Ticket | M63NU6H33XEMJYWR7H7JT5NDIM |
| 最終ステータス | 復旧済み (2026-04-11 04:18 メール受領) |

## 原因

私が r2-gcp 経由で複数のスピードテストを手動実行したことにより、GCE の egress バーストが発生し、自動 DoS 検知に引っかかった。

実行したスピードテスト:
- Cloudflare Speed Test (https://speed.cloudflare.com/)
- Fast.com (https://fast.com/)
- Speedtest by Ookla (https://www.speedtest.net/)
- Measurement Lab (Google 検索 "internet speed test" の結果)

### 過小評価していた前提

事前の lab 検証では、PC → r3.eth0 → r3.USB-NIC → r1.eth3 → r1.eth1 → PC の経路で iperf3 を流したところ、r3 のアップリンクが USB NIC である影響で:
- ダウンロード方向: ~900 Mbps
- アップロード方向: ~200 Mbps

と非対称になっており、系全体は 200 Mbps 程度に律速されると想定していた。そのため r2-gcp 経由のスピードテストでも同程度に収まると油断していた。

### 実際に起きたこと

スピードテストのダウンロードでは、リモートサーバーが GCE のフル帯域で r2-gcp にデータを送り込み、r2-gcp は WireGuard 経由で下流に転送しようとした。下流の USB NIC で吸収しきれずにドロップされていたが、**r2-gcp 自身の egress カウンタは送出を試みた量を全てカウント**するため、GCP 側のメトリクス上は ~2 Gbps のスパイクとして記録された。

### Cloud Monitoring で確認したスパイク (UTC)

| 時刻 (JST) | egress | CPU |
|---|---|---|
| 22:52 | 1,903 MB/min (~2 Gbps) | 38% |
| 22:53 | — | 97% |
| 23:04 | 1,034 MB/min (~1.4 Gbps) | 111% |
| 23:05 | 1,211 MB/min (~1.6 Gbps) | 114% |

CPU は e2-micro のバーストクレジットを使い切り 100% 超に達していた。

## 対応経緯

| 日時 (JST) | 出来事 |
|---|---|
| 2026-04-09 22:52 | スピードテスト実行によるバースト発生 |
| 2026-04-10 | GCP から警告メール受信 |
| 2026-04-10 | 異議申立て (1回目) を送信 |
| 2026-04-11 03:08 | GCP から追加情報要求のメール受信 |
| 2026-04-11 (送信) | 詳細な原因と是正措置を返信 |
| 2026-04-11 04:18 | プロジェクト復旧通知受信 |
| 2026-04-11 | r2-gcp に egress shaper (500 Mbps) を投入 |

## 是正措置

### 1. 即時対応 (実施済)

r2-gcp の VyOS に QoS shaper を投入し、WireGuard インターフェースの egress を 500 Mbps にキャップした。

```
set qos policy shaper WG-EGRESS-500M bandwidth '500mbit'
set qos policy shaper WG-EGRESS-500M default bandwidth '100%'
set qos policy shaper WG-EGRESS-500M default queue-type 'fair-queue'
set qos interface wg1 egress 'WG-EGRESS-500M'
set qos interface wg2 egress 'WG-EGRESS-500M'
```

注: VyOS 2026.03 (circinus) では `traffic-policy` ではなく `qos policy` 構文を使う。

### 2. 当日対応 (本番イベント当日に実施予定)

イベント本番では会場 200 名規模の通常トラフィックを捌く必要があるため、以下を実施する:

1. **インスタンスタイプ変更**: e2-micro → e2-standard-2 以上 (CPU バースト枠とネットワーク帯域確保のため)
2. **QoS shaper 解除**: 500 Mbps の egress 制限を撤去
3. **Cloud Monitoring アラート設定**: 持続的な高 egress を自前で検知

#### 当日作業手順

```bash
# 1. インスタンス停止
gcloud compute instances stop r2-gcp --zone=asia-northeast2-a --project=bwai-noc

# 2. マシンタイプ変更
gcloud compute instances set-machine-type r2-gcp \
  --machine-type=e2-standard-2 \
  --zone=asia-northeast2-a \
  --project=bwai-noc

# 3. 起動
gcloud compute instances start r2-gcp --zone=asia-northeast2-a --project=bwai-noc

# 4. shaper 解除 (VyOS API)
curl -s -k -X POST https://10.255.1.2/configure \
  -H "Content-Type: application/json" \
  -d '{
    "key": "BwAI",
    "op": "set",
    "commands": [
      {"op": "delete", "path": ["qos", "interface", "wg1", "egress"]},
      {"op": "delete", "path": ["qos", "interface", "wg2", "egress"]}
    ]
  }'

# 5. 設定保存
curl -s -k -X POST https://10.255.1.2/config-file \
  -H "Content-Type: application/json" \
  -d '{"key": "BwAI", "op": "save"}'
```

shaper 定義 (`qos policy shaper WG-EGRESS-500M`) 自体は残しておけば、本番後すぐに再適用可能。

## 教訓

- **r2-gcp 経由でのスピードテストは禁止**。throughput 計測は GCE を経由しない lab 経路でのみ行う
- GCE の egress カウンタは「送出した量」を計上するため、下流が受け取れない量でもメトリクスに反映される
- e2-micro は WireGuard + パケット forwarding のワークロードに対しては CPU・帯域とも不足
- GCP の自動 DoS 検知は短時間 (1〜2 分) のバーストでもトリガーされる
- イベント期間中は Cloud Monitoring のアラートを必ず設定し、自前で異常を検知できるようにする

## 関連ドキュメント

- [GCP 連携設計](../design/gcp-integration.md)
- [自宅 VyOS 設計](../design/home-vyos.md)
- [会場 VyOS 設計](../design/venue-vyos.md)
