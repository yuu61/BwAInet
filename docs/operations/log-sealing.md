# ログ封印・GCS 転送・検証手順

イベント終了後の法執行対応ログの封印、GCS への転送完了確認、WORM ロック、venue Proxmox (借用機) のディスクワイプまでの手順。

- ログ設計: [`../design/logging-compliance.md`](../design/logging-compliance.md)
- ポリシー: [`../policy/logging-policy.md`](../policy/logging-policy.md)
- CT 200 運用: [`local-server-ops.md`](local-server-ops.md)
- GCS 運用: [`gcs-upload-ops.md`](gcs-upload-ops.md)

## 借用機制約と 2 段階封印

venue Proxmox (Minisforum MS-01) は**借用機**。搬送中の物理障害リスクを減らすためイベント中から GCS に継続アップロードし、封印は以下 2 段階で行う。

1. **予備封印 (会場、電源オフ前)**: 搬送中の改ざん検知の基準点
2. **最終封印 (自宅ラボ)**: GCS 転送完了・検証後。照会対応の正式な根拠

**GCS Retention Policy のロックは最終封印・検証完了後に行う** (不可逆のため)。初期化は GCS 転送完了確認が取れるまで行わない。

## 封印スクリプト

- 本体: `/usr/local/sbin/seal-logs.sh` (リポジトリ `scripts/local-server/seal-logs.sh`)
- TSA CA: `/etc/ssl/bwai-seal/{freetsa-cacert.pem,freetsa-tsa.crt}` (FreeTSA.org)
- 出力: `/mnt/data/manifests/<phase>/seal-<epoch>.{json,sha256,tsr}`
- GCS: `gs://bwai-forensic-2026/manifests/<phase>/…` (curl raw REST API + `ifGenerationMatch=0`)

### マニフェスト形式 (JSON)

```json
{
  "phase": "preliminary",
  "sealed_at": "2026-08-11T05:00:00Z",
  "sealed_at_epoch": 1786244400,
  "hostname": "local-server",
  "sealed_by": "root",
  "root": "/mnt/data",
  "summary": {
    "total_files": 469,
    "total_bytes": 104249720,
    "categories": {
      "nfcapd": 173,
      "syslog-archive/all": 127,
      "syslog-archive/conntrack": 19,
      "syslog-archive/dhcp": 56,
      "syslog-archive/dns": 82,
      "syslog-archive/ndp": 12
    }
  },
  "files": [
    {"path": "nfcapd/nfcapd.202608110055", "size": 12345, "sha256": "abc…"},
    …
  ]
}
```

- **除外**: mtime < 1 分のファイル (書き込み中)、`nfcapd.current.*`、`.gcs-state/`、`manifests/` 自身
- `.sha256` はこのマニフェスト JSON 自体のハッシュ (NOC 独立記録用)
- `.tsr` は RFC 3161 TSA の応答 (FreeTSA、JSON バイト列そのものを対象)

### 使い方

```bash
# 会場での予備封印
seal-logs.sh preliminary

# 自宅での最終封印
seal-logs.sh final

# 検証 (sha256 + TSA + 先頭 5 ファイル再計算)
seal-logs.sh verify /mnt/data/manifests/final/seal-<epoch>.json
```

## Phase 1: 予備封印 (会場、電源オフ前)

1. **GCS 転送を最新化**: `last-push.json` の age を確認、必要なら手動実行
   ```bash
   ssh root@192.168.11.2 "cat /mnt/data/.gcs-state/last-push.json"
   ssh root@192.168.11.2 /usr/local/sbin/gcs-forensic-push.sh  # 手動 catch-up
   ```

2. **イベント終了直後、local-server CT 上で封印**
   ```bash
   ssh root@192.168.11.2 /usr/local/sbin/seal-logs.sh preliminary
   ```
   スクリプトは自動的に:
   - 対象ファイルの SHA-256 を計算してマニフェスト JSON 生成
   - マニフェスト自身を FreeTSA に送って TSA 応答を取得
   - マニフェスト + .sha256 + .tsr を GCS に `ifGenerationMatch=0` でアップロード
   - 最後にマニフェストの SHA-256 を標準出力に表示

3. **NOC メンバー 2 名以上で独立保存**
   - 標準出力に表示された sha256 を各自記録 (Google Chat、紙メモ、写真、ICカード、複数媒体)
   - 後日の改ざん検知の唯一の基準点となる

4. **継続 rsync の最終実行を確認**
   ```bash
   ssh root@192.168.11.2 "
     /usr/local/sbin/gcs-forensic-push.sh
     cat /mnt/data/.gcs-state/last-push.json
   "
   # pushed=0 かつ errors=0 になるまで繰り返す (全ファイル転送完了)
   ```

5. **venue Proxmox を電源オフ**
   ```bash
   ssh root@192.168.11.2 sync
   ssh proxmox "pct shutdown 200; pct shutdown 201; qm shutdown 100"
   ssh proxmox shutdown -h now
   ```

## Phase 2: 最終封印 (自宅ラボ)

1. **自宅ラボで venue Proxmox を起動し CT 200 を始動**

2. **予備封印マニフェストの SHA-256 を再計算**し、Phase 1 で NOC 記録したハッシュと一致することを確認 (搬送中改ざん検知)
   ```bash
   ssh root@192.168.11.2 "sha256sum /mnt/data/manifests/preliminary/seal-*.json"
   # NOC が記録したハッシュと突合せ
   ```

3. **GCS 側のオブジェクト数・サイズを確認** (admin 権限で、ローカル PC から)
   ```bash
   LOCAL=$(ssh root@192.168.11.2 "find /mnt/data/nfcapd /mnt/data/syslog-archive -type f | wc -l")
   GCS=$(gcloud storage ls -r gs://bwai-forensic-2026/syslog-archive/ gs://bwai-forensic-2026/nfcapd/ --project=bwai-noc | wc -l)
   echo "local=$LOCAL gcs=$GCS"
   # 欠損があれば手動 catch-up
   ssh root@192.168.11.2 /usr/local/sbin/gcs-forensic-push.sh
   ```

4. **最終封印スクリプト実行**
   ```bash
   ssh root@192.168.11.2 /usr/local/sbin/seal-logs.sh final
   ```
   最終マニフェストの sha256 も NOC メンバー 2 名以上で独立保存。

5. **GCS 転送完了の検証** (初期化前の最終ゲート)
   ```bash
   # ローカルの封印対象ファイル数
   ssh root@192.168.11.2 "
     python3 -c '
     import json; m = json.load(open(sorted(__import__(\"glob\").glob(\"/mnt/data/manifests/final/seal-*.json\"))[-1]))
     print(f\"files={m[\\\"summary\\\"][\\\"total_files\\\"]} bytes={m[\\\"summary\\\"][\\\"total_bytes\\\"]}\")
     '
   "
   # GCS 側
   gcloud storage du gs://bwai-forensic-2026/ --project=bwai-noc
   ```

6. **GCS Retention Policy をロック** (不可逆)
   ```bash
   gcloud storage buckets update gs://bwai-forensic-2026 \
     --lock-retention-period --project=bwai-noc
   ```
   lock 後は 180 日間すべての削除・上書き不可。

7. **venue Proxmox (MS-01) のディスクをワイプ** (GCS 転送完了 + lock 完了後のみ)
   ```bash
   ssh proxmox "
     nvme format /dev/nvme0n1 --namespace-id=1 --ses=1
     nvme format /dev/nvme1n1 --namespace-id=1 --ses=1
   "
   ```

8. 借用元へ返送

## RFC 3161 TSA (FreeTSA.org)

CT 200 でのセットアップ (事前準備期間の Day -5 で実施済み):
```bash
install -d -m 0755 /etc/ssl/bwai-seal
curl -sS -o /etc/ssl/bwai-seal/freetsa-cacert.pem https://freetsa.org/files/cacert.pem
curl -sS -o /etc/ssl/bwai-seal/freetsa-tsa.crt   https://freetsa.org/files/tsa.crt
```

スクリプトが自動的に:
- `openssl ts -query -data $MANIFEST -no_nonce -sha256 -cert -out seal.tsq`
- `curl -X POST https://freetsa.org/tsr -H 'Content-Type: application/timestamp-query' --data-binary @seal.tsq -o seal.tsr`
- `openssl ts -verify -data $MANIFEST -in seal.tsr -CAfile ... -untrusted ...`

FreeTSA が応答しない場合は警告ログを残してマニフェストの sha256 + GCS アップロードのみ完遂する (TSA は補強要素、マニフェストの NOC 記録が一次証拠)。

## GCS バケット構造 (最終形)

```
gs://bwai-forensic-2026/
  nfcapd/                            ← NetFlow 5 分ローテファイル
  syslog-archive/
    dns/<hostname>-YYYY-MM-DDTHHZ.log
    dhcp/<hostname>-YYYY-MM-DDTHHZ.log
    conntrack/<hostname>-YYYY-MM-DDTHHZ.log
    ndp/<hostname>-YYYY-MM-DDTHHZ.log
    all/<hostname>-YYYY-MM-DDTHHZ.log    (保険、法執行対応の主系)
  manifests/
    preliminary/seal-<epoch>.{json,sha256,tsr}   会場での予備封印
    final/seal-<epoch>.{json,sha256,tsr}         自宅ラボでの最終封印
```

## 照会時の検証手順

法執行機関から照会があった場合:

```bash
# 1. 最終封印マニフェストを GCS から取得
gcloud storage cp gs://bwai-forensic-2026/manifests/final/seal-*.json /tmp/
gcloud storage cp gs://bwai-forensic-2026/manifests/final/seal-*.sha256 /tmp/
gcloud storage cp gs://bwai-forensic-2026/manifests/final/seal-*.tsr /tmp/

# 2. マニフェスト改ざん検知
sha256sum /tmp/seal-*.json
# NOC 独立記録ハッシュと一致することを確認

# 3. TSA タイムスタンプ検証
openssl ts -verify -data /tmp/seal-*.json -in /tmp/seal-*.tsr \
  -CAfile /etc/ssl/bwai-seal/freetsa-cacert.pem \
  -untrusted /etc/ssl/bwai-seal/freetsa-tsa.crt

# 4. 特定ファイルの完全性検証
# 例: 2026-08-10 14:00 UTC の DNS クエリログ
gcloud storage cp gs://bwai-forensic-2026/syslog-archive/dns/r3-vyos-2026-08-10T14Z.log /tmp/
sha256sum /tmp/r3-vyos-2026-08-10T14Z.log
# マニフェスト内の該当エントリの sha256 と比較
python3 -c "
import json
m = json.load(open('/tmp/seal-<epoch>.json'))
for e in m['files']:
  if 'r3-vyos-2026-08-10T14Z' in e['path']:
    print(e)
"

# 5. Retention Policy 保持状態確認
gcloud storage objects describe gs://bwai-forensic-2026/manifests/final/seal-*.json \
  --format="value(retentionExpirationTime)" --project=bwai-noc
```

## 関連

- [`../design/logging-compliance.md`](../design/logging-compliance.md) — ログ相関モデル、保存設計
- [`../policy/logging-policy.md`](../policy/logging-policy.md) — 記録・保持ポリシー
- [`log-query-cookbook.md`](log-query-cookbook.md) — 照会対応クエリ例
- [`gcs-upload-ops.md`](gcs-upload-ops.md) — GCS 転送運用
- [`local-server-ops.md`](local-server-ops.md) — CT 200 運用
- [`../design/venue-proxmox.md`](../design/venue-proxmox.md) — CT 200 構成
