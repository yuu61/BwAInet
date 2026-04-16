#!/bin/bash
# BwAI forensic log → GCS uploader (raw REST API, objectCreator only)
# 5 min timer で起動、mtime > 10 min の確定済みファイルのみ送る
set -euo pipefail

BUCKET=bwai-forensic-2026
LOCAL_ROOT=/mnt/data
STATE_DIR=/mnt/data/.gcs-state
PUSHED_LIST=$STATE_DIR/pushed.list
STATE_JSON=$STATE_DIR/last-push.json
LOG_ERR=$STATE_DIR/errors.log

touch $PUSHED_LIST
touch $LOG_ERR

# Access token 取得 (gcloud キャッシュ 1h)
TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
if [ -z "$TOKEN" ]; then
  echo "$(date -u +%FT%TZ) ERROR no_access_token" >> $LOG_ERR
  exit 1
fi

pushed=0
skipped=0
errors=0
start=$(date -u +%FT%TZ)

while IFS= read -r -d '' file; do
  obj=${file#$LOCAL_ROOT/}
  if grep -Fxq "$obj" $PUSHED_LIST; then
    skipped=$((skipped+1))
    continue
  fi
  enc=$(python3 -c "import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=''))" "$obj")
  url="https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&name=$enc&ifGenerationMatch=0"
  http=$(curl -sk -w '%{http_code}' -o /dev/null -X POST     -H "Authorization: Bearer $TOKEN"     -H 'Content-Type: application/octet-stream'     --data-binary @"$file" "$url")
  case $http in
    200) echo "$obj" >> $PUSHED_LIST; pushed=$((pushed+1)) ;;
    412) echo "$obj" >> $PUSHED_LIST; skipped=$((skipped+1)) ;;
    *)   echo "$(date -u +%FT%TZ) ERROR $http $obj" >> $LOG_ERR; errors=$((errors+1)) ;;
  esac
done < <(find $LOCAL_ROOT -type f   -not -path "$STATE_DIR/*"   \( -name '*.log' -o -name 'nfcapd.20*' \)   -mmin +10 -print0)

end=$(date -u +%FT%TZ)
cat > $STATE_JSON << JSON
{
  "start": "$start",
  "end": "$end",
  "pushed": $pushed,
  "skipped": $skipped,
  "errors": $errors,
  "total_pushed": $(wc -l < $PUSHED_LIST)
}
JSON

[ $errors -eq 0 ] && exit 0 || exit 1
