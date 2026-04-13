# ログ封印・GCS 転送・検証手順

イベント終了後の法執行対応ログの封印、GCS への転送完了確認、WORM ロック、venue Proxmox (借用機) のディスクワイプまでの手順。ログ設計は [`../design/logging-compliance.md`](../design/logging-compliance.md)、ポリシーは [`../policy/logging-policy.md`](../policy/logging-policy.md) を参照。

## 借用機制約と 2 段階封印

venue Proxmox (Minisforum MS-01) は**借用機**。搬送中の物理障害リスクを減らすためイベント中から GCS に継続アップロードし、封印は以下 2 段階で行う。

1. **予備封印 (会場、電源オフ前)**: 搬送中の改ざん検知の基準点
2. **最終封印 (自宅ラボ)**: GCS 転送完了・検証後。照会対応の正式な根拠

**GCS Retention Policy のロックは最終封印・検証完了後に行う** (不可逆のため)。初期化は GCS 転送完了確認が取れるまで行わない。

## 封印スクリプト (`seal-logs.sh`)

local-server CT 上で実行。引数で preliminary / final を切替。

```bash
#!/bin/bash
SEAL_PHASE="${1:-preliminary}"
SEAL_DATE=$(date -u +"%Y%m%dT%H%M%SZ")
SEAL_FILE="/var/log/log-seal-${SEAL_PHASE}-${SEAL_DATE}.txt"

echo "=== BwAI Network Log Seal ===" > "$SEAL_FILE"
echo "Phase: ${SEAL_PHASE}" >> "$SEAL_FILE"
echo "Sealed at: ${SEAL_DATE}" >> "$SEAL_FILE"
echo "Sealed by: $(whoami)@$(hostname)" >> "$SEAL_FILE"
echo "" >> "$SEAL_FILE"

echo "--- NetFlow (nfcapd) ---" >> "$SEAL_FILE"
find /var/log/nfcapd -type f -name "nfcapd.*" | sort | while read -r f; do
    sha256sum "$f" >> "$SEAL_FILE"
done

echo "--- DNS query log ---" >> "$SEAL_FILE"
sha256sum /var/log/syslog-archive/dns/* 2>/dev/null >> "$SEAL_FILE"

echo "--- DHCP forensic log ---" >> "$SEAL_FILE"
find /var/log/kea -type f -name "kea-legal*" | sort | while read -r f; do
    sha256sum "$f" >> "$SEAL_FILE"
done

echo "--- Conntrack NAT log ---" >> "$SEAL_FILE"
sha256sum /var/log/syslog-archive/conntrack/* 2>/dev/null >> "$SEAL_FILE"

echo "--- NDP dump ---" >> "$SEAL_FILE"
sha256sum /var/log/syslog-archive/ndp/* 2>/dev/null >> "$SEAL_FILE"

echo "" >> "$SEAL_FILE"
echo "--- Seal file hash ---" >> "$SEAL_FILE"
sha256sum "$SEAL_FILE"
```

## Phase 1: 予備封印 (会場、電源オフ前)

1. イベント終了直後、local-server CT 上で実行
   ```bash
   bash seal-logs.sh preliminary
   ```
2. 予備封印ファイルの SHA-256 ハッシュを取得
3. NOC メンバー **2 名以上**が独立保存 (Google Chat 投稿、端末テキスト保存、写真撮影)
4. RFC 3161 タイムスタンプ取得 (下記参照)
5. 予備封印ファイル + TSA 応答を GCS にアップロード
   ```bash
   gcloud storage cp /var/log/log-seal-preliminary-*.txt gs://bwai-forensic-2026/seal/preliminary/
   gcloud storage cp seal.tsr gs://bwai-forensic-2026/seal/preliminary/
   ```
6. 最終 GCS rsync を実行し、差分ゼロを確認
7. venue Proxmox を電源オフ

## Phase 2: 最終封印 (自宅ラボ)

1. 自宅ラボで venue Proxmox を起動し local-server CT を開始
2. 予備封印ファイルのハッシュを再計算し、搬送前の記録と一致することを確認 (搬送中改ざん検知)
3. GCS 側のオブジェクト数・サイズを確認し、欠損があれば追加アップロード
4. 最終封印スクリプト実行
   ```bash
   bash seal-logs.sh final
   ```
5. ハッシュ取得、NOC メンバー 2 名以上で独立保存
6. RFC 3161 タイムスタンプ取得、GCS にアップロード
7. **GCS 転送完了の検証** (初期化前の最終ゲート)
   ```bash
   LOCAL_COUNT=$(find /var/log/nfcapd /var/log/syslog-archive /var/log/kea -type f | wc -l)
   GCS_COUNT=$(gcloud storage ls -r gs://bwai-forensic-2026/live/ | wc -l)
   echo "Local: ${LOCAL_COUNT}, GCS: ${GCS_COUNT}"

   gcloud storage cp gs://bwai-forensic-2026/live/nfcapd/nfcapd.YYYYMMDDHHMMSS /tmp/
   sha256sum /tmp/nfcapd.YYYYMMDDHHMMSS
   sha256sum /var/log/nfcapd/nfcapd.YYYYMMDDHHMMSS
   ```
8. **GCS Retention Policy をロック** (不可逆)
   ```bash
   gcloud storage buckets update gs://bwai-forensic-2026 \
       --retention-period=15552000 --lock-retention-period
   ```
9. **venue Proxmox (MS-01) のディスクをワイプ** — 転送完了確認・WORM ロック完了後にのみ実施
10. 借用元へ返送

## RFC 3161 タイムスタンプ (FreeTSA.org)

```bash
# 事前に FreeTSA の CA 証明書を取得
wget https://freetsa.org/files/cacert.pem -O freetsa-cacert.pem
wget https://freetsa.org/files/tsa.crt -O freetsa-tsa.crt

# タイムスタンプ要求生成
openssl ts -query -data /var/log/log-seal-${SEAL_DATE}.txt \
    -no_nonce -sha256 -cert -out seal.tsq

# TSA に要求
curl -s -H "Content-Type: application/timestamp-query" \
    --data-binary @seal.tsq \
    https://freetsa.org/tsr -o seal.tsr

# 検証
openssl ts -verify -data /var/log/log-seal-${SEAL_DATE}.txt \
    -in seal.tsr \
    -CAfile freetsa-cacert.pem \
    -untrusted freetsa-tsa.crt
```

## GCS 継続アップロード (イベント期間中)

`/etc/cron.d/gcs-sync`:

```bash
*/5  * * * * root gcloud storage rsync -r /var/log/nfcapd/         gs://bwai-forensic-2026/live/nfcapd/    >> /var/log/gcs-sync.log 2>&1
*/5  * * * * root gcloud storage rsync -r /var/log/syslog-archive/ gs://bwai-forensic-2026/live/syslog/    >> /var/log/gcs-sync.log 2>&1
*/15 * * * * root gcloud storage rsync -r /var/log/kea/            gs://bwai-forensic-2026/live/kea-legal/ >> /var/log/gcs-sync.log 2>&1
```

### アップロード失敗検知

Zabbix agent (zabbix-grafana CT 上) で `/var/log/gcs-sync.log` を監視し、`ERROR`/`FAILED` 検知でアラート発報。

- **Item**: `log[/var/log/gcs-sync.log,"ERROR|FAILED",,,,]` (log 型、active agent)
- **Trigger**: `{local-server:log[...].logseverity()} >= 4` → Warning
- **Action**: Google Chat webhook で NOC に通知

## GCS バケット構造

```
gs://bwai-forensic-2026/
  live/                    ← イベント中の継続アップロード
    nfcapd/
    syslog/
    kea-legal/
  seal/                    ← 封印ファイル + TSA 応答
    preliminary/           ← 会場での予備封印
    final/                 ← 自宅ラボでの最終封印
```

## GCS サービスアカウント (objectCreator のみ)

```bash
gcloud iam service-accounts create sa-forensic-writer \
    --display-name="Forensic Log Writer"

gcloud storage buckets add-iam-policy-binding gs://bwai-forensic-2026 \
    --member="serviceAccount:sa-forensic-writer@<project>.iam.gserviceaccount.com" \
    --role="roles/storage.objectCreator"

gcloud iam service-accounts keys create /etc/gcs-sa-key.json \
    --iam-account=sa-forensic-writer@<project>.iam.gserviceaccount.com

# local-server CT 内で
gcloud auth activate-service-account --key-file=/etc/gcs-sa-key.json
```

`objectCreator` 限定のため、SA キーが漏洩しても既存オブジェクトの削除・上書きは不可能。

## GCS Retention Policy の準備 (イベント前)

```bash
gcloud storage buckets create gs://bwai-forensic-2026 \
    --location=asia-northeast1

# 保持期間 180 日を設定 (ロックはまだ)
gcloud storage buckets update gs://bwai-forensic-2026 \
    --retention-period=15552000
```

ロックは Phase 2 の検証完了後のみ。

## 照会時の検証手順

```bash
# 1. 最終封印ファイルを GCS から取得し、NOC 保存ハッシュと照合
gcloud storage cp gs://bwai-forensic-2026/seal/final/log-seal-final-*.txt /tmp/
sha256sum /tmp/log-seal-final-*.txt

# 2. 個別ログファイルを封印記録と照合
gcloud storage cp gs://bwai-forensic-2026/live/nfcapd/nfcapd.202608101430 /tmp/
sha256sum /tmp/nfcapd.202608101430 | diff - <(grep "nfcapd.202608101430" /tmp/log-seal-final-*.txt)

# 3. TSA タイムスタンプ検証
gcloud storage cp gs://bwai-forensic-2026/seal/final/seal.tsr /tmp/
openssl ts -verify -data /tmp/log-seal-final-*.txt -in /tmp/seal.tsr \
    -CAfile freetsa-cacert.pem -untrusted freetsa-tsa.crt

# 4. Retention Policy の保持状態確認
gcloud storage objects describe gs://bwai-forensic-2026/seal/final/log-seal-final-*.txt \
    --format="value(retentionExpirationTime)"
```

## 関連

- [`../design/logging-compliance.md`](../design/logging-compliance.md) — ログ相関モデル
- [`../policy/logging-policy.md`](../policy/logging-policy.md) — 記録・保持ポリシー
- [`log-query-cookbook.md`](log-query-cookbook.md) — 照会対応クエリ例
- [`../design/venue-proxmox.md`](../design/venue-proxmox.md) — local-server CT 構成
