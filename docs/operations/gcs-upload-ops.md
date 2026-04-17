# GCS 転送運用手順

`local-server` (CT 200) から GCS バケット `gs://bwai-forensic-2026/` への継続アップロードの運用手順。

設計全体は [`../design/logging-compliance.md`](../design/logging-compliance.md) §7 を参照。

## 構成

| 項目 | 値 |
|---|---|
| プロジェクト | `bwai-noc` |
| バケット | `gs://bwai-forensic-2026/` (asia-northeast2 / Standard) |
| Retention | 180 日 (lock はイベント後) |
| Service Account | `forensic-uploader@bwai-noc.iam.gserviceaccount.com` |
| SA ロール | `roles/storage.objectCreator` のみ |
| SA キー | CT 200 `/mnt/data/.gcs-state/sa-key.json` (0400 root:root) |
| アップローダー | `/usr/local/sbin/gcs-forensic-push.sh` (raw REST API + `ifGenerationMatch=0`) |
| タイマー | `gcs-forensic-push.timer` (5 分間隔) |

## 稼働確認

```bash
ssh root@192.168.11.2 "
# timer 状態
systemctl status gcs-forensic-push.timer --no-pager
# 直近実行
systemctl list-timers gcs-forensic-push.timer
# 統計
cat /mnt/data/.gcs-state/last-push.json
# エラー有無
wc -l /mnt/data/.gcs-state/errors.log
tail /mnt/data/.gcs-state/errors.log
# 送信済みファイル数
wc -l /mnt/data/.gcs-state/pushed.list
"
```

期待:
- timer active
- `last-push.json` の `end` が直近 5 分以内
- `errors.log` 0 行
- `pushed.list` 行数が CT 200 の対象ファイル総数とほぼ一致

## 手動再実行

```bash
ssh root@192.168.11.2 /usr/local/sbin/gcs-forensic-push.sh
```

成功時は exit 0、失敗時は exit 1。

## バケット側確認 (ローカルマシンの admin 権限で)

```bash
# オブジェクト数
gcloud storage ls -r gs://bwai-forensic-2026/ --project=bwai-noc | wc -l

# 直近アップロード
gcloud storage ls -l gs://bwai-forensic-2026/** --project=bwai-noc | sort -k2 | tail -10

# 特定パスの存在確認
gcloud storage ls gs://bwai-forensic-2026/syslog-archive/dns/ --project=bwai-noc | head
```

SA (`forensic-uploader`) からは `ls` 不可 (`objectCreator` のみのため)。これは設計通り。

## 障害対応

### Access token が取れない

```bash
# CT 200 で
ssh root@192.168.11.2 "
gcloud auth list
gcloud auth activate-service-account --key-file=/mnt/data/.gcs-state/sa-key.json
gcloud auth print-access-token | head -c 50
"
```

SA キーが破損/失効していたら後述の「SA キーローテ」手順。

### HTTP 403 forbidden

原因候補:
1. SA が削除された / ロール剥奪
2. バケット Retention lock が完了済みで、同名上書きを試みた (ifGenerationMatch=0 で通常は 412 だが…)

```bash
# SA のロール確認
gcloud storage buckets get-iam-policy gs://bwai-forensic-2026 --project=bwai-noc \
  | grep -A1 forensic-uploader
```

### HTTP 412 Precondition Failed (大量発生)

`ifGenerationMatch=0` によりオブジェクト既存で拒否されている。通常は `pushed.list` で事前スキップされるが、状態ファイル消失時に再送試行すると大量発生する。

```bash
# pushed.list を GCS 側の実在オブジェクトから再構築
TOKEN=$(gcloud auth print-access-token)
# ※ SA からは list 不可のため、admin 権限 (ローカル PC) で実行して CT 200 に転送する
gcloud storage ls -r gs://bwai-forensic-2026/** --project=bwai-noc \
  | sed 's|^gs://bwai-forensic-2026/||' > /tmp/pushed-rebuild.list
scp /tmp/pushed-rebuild.list root@192.168.11.2:/mnt/data/.gcs-state/pushed.list
ssh root@192.168.11.2 "chown root:adm /mnt/data/.gcs-state/pushed.list; chmod 0640 /mnt/data/.gcs-state/pushed.list"
```

### ネットワーク疎通問題

CT 200 → `storage.googleapis.com:443` の到達性 (WG 経由ではなく直接 Internet に出る設計)。

```bash
ssh root@192.168.11.2 "
curl -sS -o /dev/null -w '%{http_code}\n' https://storage.googleapis.com/
# DNS 解決
dig storage.googleapis.com +short
"
```

## SA キーローテ (漏洩時・定期更新)

**漏洩時は即座に旧キー失効 → 新キー発行**。

```bash
# 1. 新キー発行
gcloud iam service-accounts keys create /tmp/sa-key-new.json \
  --iam-account=forensic-uploader@bwai-noc.iam.gserviceaccount.com

# 2. CT 200 に転送
scp /tmp/sa-key-new.json root@192.168.11.2:/mnt/data/.gcs-state/sa-key.json
ssh root@192.168.11.2 "
chown root:root /mnt/data/.gcs-state/sa-key.json
chmod 0400 /mnt/data/.gcs-state/sa-key.json
gcloud auth activate-service-account --key-file=/mnt/data/.gcs-state/sa-key.json
"

# 3. ローカルから削除
rm /tmp/sa-key-new.json

# 4. 旧キー失効 (gcloud auth list → key ID を取得後)
gcloud iam service-accounts keys list \
  --iam-account=forensic-uploader@bwai-noc.iam.gserviceaccount.com
gcloud iam service-accounts keys delete <OLD_KEY_ID> \
  --iam-account=forensic-uploader@bwai-noc.iam.gserviceaccount.com

# 5. 動作確認
ssh root@192.168.11.2 /usr/local/sbin/gcs-forensic-push.sh
```

## Retention Policy の Lock (イベント終了後のみ)

**Lock は不可逆**。最終封印・GCS 転送完了検証後に実施する。

```bash
gcloud storage buckets update gs://bwai-forensic-2026 \
  --lock-retention-period --project=bwai-noc
```

lock 後は 180 日間いかなる手段でもオブジェクト削除・上書き不可。GCP プロジェクト削除も拒否される。

## 関連

- [`../design/logging-compliance.md`](../design/logging-compliance.md) §7 — GCS 転送設計
- [`local-server-ops.md`](local-server-ops.md) — local-server 全体運用
- [`log-sealing.md`](log-sealing.md) — 封印・lock 手順
