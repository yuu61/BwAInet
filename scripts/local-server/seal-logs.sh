#!/bin/bash
# BwAI forensic log sealing
#  - preliminary: 会場、電源オフ前
#  - final:       自宅ラボ、GCS 転送完了検証後
#
# 出力: /mnt/data/manifests/<phase>/seal-<epoch>.{json,sha256,tsr}
# GCS:  gs://bwai-forensic-2026/manifests/<phase>/... (raw REST API)
#
# Usage:
#   seal-logs.sh preliminary
#   seal-logs.sh final
#   seal-logs.sh verify <manifest.json>

set -euo pipefail

CMD="${1:-preliminary}"
DATA_ROOT=/mnt/data
STATE_DIR="$DATA_ROOT/.gcs-state"
TSA_URL="https://freetsa.org/tsr"
TSA_CA=/etc/ssl/bwai-seal/freetsa-cacert.pem
TSA_CERT=/etc/ssl/bwai-seal/freetsa-tsa.crt
BUCKET=bwai-forensic-2026

case "$CMD" in
  preliminary|final)
    PHASE="$CMD"
    MANIFEST_DIR="$DATA_ROOT/manifests/$PHASE"
    ;;
  verify)
    shift
    MANIFEST="${1:-}"
    [ -n "$MANIFEST" ] || { echo "Usage: $0 verify <manifest.json>" >&2; exit 2; }
    [ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
    BASE="${MANIFEST%.json}"
    echo "=== recompute manifest sha256 ==="
    EXPECTED=$(awk '{print $1}' "${BASE}.sha256")
    ACTUAL=$(sha256sum "$MANIFEST" | awk '{print $1}')
    [ "$EXPECTED" = "$ACTUAL" ] && echo "manifest sha256 OK" || { echo "MANIFEST TAMPERED"; exit 1; }
    echo
    echo "=== verify TSA ==="
    openssl ts -verify -data "$MANIFEST" -in "${BASE}.tsr" \
      -CAfile "$TSA_CA" -untrusted "$TSA_CERT" || { echo "TSA verify FAILED"; exit 1; }
    echo
    echo "=== spot-check file hashes (first 5) ==="
    python3 - "$MANIFEST" <<'PY'
import json, sys, hashlib
m = json.load(open(sys.argv[1]))
ok = 0; ng = 0
for e in m['files'][:5]:
    p = f"/mnt/data/{e['path']}"
    try:
        h = hashlib.sha256(open(p,'rb').read()).hexdigest()
    except FileNotFoundError:
        print(f"  MISSING: {p}"); ng += 1; continue
    if h == e['sha256']:
        ok += 1
    else:
        print(f"  MISMATCH: {p}"); ng += 1
print(f"  {ok} matched, {ng} mismatched (sampled 5)")
PY
    exit 0
    ;;
  *)
    echo "Usage: $0 {preliminary|final|verify <manifest.json>}" >&2
    exit 2
    ;;
esac

# ---------- normal seal ----------
[ "$EUID" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
install -d -m 02750 -o root -g adm "$MANIFEST_DIR"

SEAL_EPOCH=$(date -u +%s)
SEAL_TS=$(date -u -d @$SEAL_EPOCH +%FT%TZ)
SEAL_BASE="$MANIFEST_DIR/seal-$SEAL_EPOCH"
MANIFEST="$SEAL_BASE.json"
HASH_FILE="$SEAL_BASE.sha256"
TSR_FILE="$SEAL_BASE.tsr"

echo "=== BwAI forensic seal: phase=$PHASE at $SEAL_TS ==="

# 1. Pre-seal GCS push healthiness check (preliminary only, warn-only)
if [ "$PHASE" = "preliminary" ] && [ -f "$STATE_DIR/last-push.json" ]; then
  AGE=$(( SEAL_EPOCH - $(stat -c %Y "$STATE_DIR/last-push.json") ))
  if [ "$AGE" -gt 600 ]; then
    echo "WARNING: GCS last push is ${AGE}s old (>10 min). Consider running /usr/local/sbin/gcs-forensic-push.sh before sealing." >&2
  fi
fi

# 2. Build file list (skip currently-written files: mtime < 60s)
TMP=$(mktemp)
trap "rm -f $TMP" EXIT
find "$DATA_ROOT" -type f \
  -not -path "$STATE_DIR/*" \
  -not -path "$DATA_ROOT/manifests/*" \
  -not -name 'lost+found' \
  \( -name '*.log' -o -name 'nfcapd.20*' \) \
  -not -name 'nfcapd.current.*' \
  -mmin +1 \
  -printf '%P\n' 2>/dev/null | sort > "$TMP" || true

# 3. Compute hashes and build JSON manifest
python3 - "$TMP" "$DATA_ROOT" "$PHASE" "$SEAL_TS" "$SEAL_EPOCH" > "$MANIFEST" <<'PY'
import sys, os, json, hashlib, socket, getpass, collections
list_file, root, phase, ts, epoch = sys.argv[1:6]
with open(list_file) as f:
    paths = [l.strip() for l in f if l.strip()]
files = []
cats = collections.Counter()
total = 0
for p in paths:
    full = os.path.join(root, p)
    try:
        with open(full, 'rb') as fh:
            data = fh.read()
    except FileNotFoundError:
        continue
    h = hashlib.sha256(data).hexdigest()
    size = len(data)
    files.append({"path": p, "size": size, "sha256": h})
    total += size
    top = p.split('/', 2)
    cat = '/'.join(top[:2]) if len(top) > 2 else top[0]
    cats[cat] += 1
m = {
    "phase": phase,
    "sealed_at": ts,
    "sealed_at_epoch": int(epoch),
    "hostname": socket.gethostname(),
    "sealed_by": getpass.getuser(),
    "root": root,
    "summary": {
        "total_files": len(files),
        "total_bytes": total,
        "categories": dict(cats),
    },
    "files": files,
}
json.dump(m, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY

# 4. Manifest self-hash
sha256sum "$MANIFEST" > "$HASH_FILE"

echo "manifest:  $MANIFEST"
python3 -c "
import json; m=json.load(open('$MANIFEST'))
print(f\"  files={m['summary']['total_files']} bytes={m['summary']['total_bytes']}\")
for k,v in sorted(m['summary']['categories'].items()):
    print(f\"    {k}: {v}\")"
echo "manifest sha256: $(awk '{print $1}' $HASH_FILE)"

# 5. TSA timestamp (FreeTSA)
if [ -f "$TSA_CA" ]; then
  openssl ts -query -data "$MANIFEST" -no_nonce -sha256 -cert -out "$SEAL_BASE.tsq" 2>/dev/null
  if curl -sS --max-time 15 -H 'Content-Type: application/timestamp-query' \
    --data-binary @"$SEAL_BASE.tsq" "$TSA_URL" -o "$TSR_FILE"; then
    if openssl ts -verify -data "$MANIFEST" -in "$TSR_FILE" \
      -CAfile "$TSA_CA" -untrusted "$TSA_CERT" 2>/dev/null; then
      echo "TSA timestamp:  OK"
      rm -f "$SEAL_BASE.tsq"
    else
      echo "WARNING: TSA verify failed but .tsr saved" >&2
    fi
  else
    echo "WARNING: TSA request failed (offline?)" >&2
    rm -f "$SEAL_BASE.tsq"
  fi
else
  echo "WARNING: TSA CA not installed at $TSA_CA, skipping TSA" >&2
fi

# 6. Upload manifest+hash+tsr to GCS (raw REST API, ifGenerationMatch=0)
TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)
if [ -n "$TOKEN" ]; then
  for f in "$MANIFEST" "$HASH_FILE" "$TSR_FILE"; do
    [ -f "$f" ] || continue
    name="manifests/$PHASE/$(basename $f)"
    enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$name")
    http=$(curl -sS -w '%{http_code}' -o /dev/null -X POST \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Content-Type: application/octet-stream' \
      --data-binary @"$f" \
      "https://storage.googleapis.com/upload/storage/v1/b/$BUCKET/o?uploadType=media&name=$enc&ifGenerationMatch=0")
    case $http in
      200) echo "  GCS uploaded: $name" ;;
      412) echo "  GCS already exists: $name" ;;
      *)   echo "  GCS ERROR $http: $name" >&2 ;;
    esac
  done
else
  echo "WARNING: no gcloud access token, skipping GCS upload" >&2
fi

echo
echo "=== SEAL COMPLETE ==="
echo "manifest:  $MANIFEST"
echo "sha256:    $HASH_FILE"
[ -f "$TSR_FILE" ] && echo "tsa:       $TSR_FILE"
echo
echo "NOC members should independently record the manifest sha256:"
awk '{print "  " $1}' "$HASH_FILE"
