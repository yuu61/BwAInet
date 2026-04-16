#!/bin/bash
# dns-cache-warmup.sh — r3 の DNS キャッシュをランダムなドメインで事前投入する (クライアント側実行版)
#
# 使い方:
#   ./dns-cache-warmup.sh
#   DNS_SERVER=192.168.11.1 QUERIES=500 TOP_N=10000 ./dns-cache-warmup.sh
#
# 動作:
#   Cisco Umbrella Top 1M (DNS クエリ統計ベース) を /tmp にダウンロード・展開し、
#   上位 TOP_N 件からランダムに QUERIES 件選んで A/AAAA を問い合わせ、
#   r3 の PowerDNS Recursor キャッシュを温める。
#   CSV は 24 時間キャッシュし、以降の実行では再ダウンロードしない。
#
# 依存: dig (bind-utils / dnsutils), curl, unzip, shuf (coreutils), mktemp

set -euo pipefail

DNS_SERVER="${DNS_SERVER:-192.168.11.1}"
QUERIES_PER_RUN="${QUERIES:-200}"
TOP_N="${TOP_N:-10000}"
TIMEOUT=2

UMBRELLA_URL="https://s3-us-west-1.amazonaws.com/umbrella-static/top-1m.csv.zip"
CACHE_DIR="/tmp/dns-cache-warmup"
ZIP_FILE="$CACHE_DIR/top-1m.csv.zip"
CSV_FILE="$CACHE_DIR/top-1m.csv"
CACHE_MAX_AGE=86400

log() { echo "[dns-warmup] $*" >&2; }

is_non_negative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

sample_file=""
cleanup() {
    [[ -n "$sample_file" && -f "$sample_file" ]] && rm -f "$sample_file"
}
trap cleanup EXIT

for cmd in dig curl unzip shuf mktemp; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
        log "ERROR: $cmd command not found"
        exit 1
    fi
done

if ! is_non_negative_integer "$QUERIES_PER_RUN"; then
    log "ERROR: QUERIES must be a non-negative integer (got: $QUERIES_PER_RUN)"
    exit 1
fi

if ! is_positive_integer "$TOP_N"; then
    log "ERROR: TOP_N must be a positive integer (got: $TOP_N)"
    exit 1
fi

mkdir -p "$CACHE_DIR"

need_download=1
if [[ -f "$CSV_FILE" ]]; then
    # GNU stat (Linux) と BSD stat (macOS) の両対応
    mtime=$(stat -c %Y "$CSV_FILE" 2>/dev/null || stat -f %m "$CSV_FILE" 2>/dev/null || true)
    if [[ -n "$mtime" ]]; then
        age=$(( $(date +%s) - mtime ))
        if (( age < CACHE_MAX_AGE )); then
            need_download=0
            log "using cached CSV (age=${age}s)"
        fi
    fi
fi

if (( need_download )); then
    log "downloading Umbrella Top 1M from $UMBRELLA_URL"
    if ! curl -fsSL -o "$ZIP_FILE" "$UMBRELLA_URL"; then
        log "ERROR: download failed"
        exit 1
    fi
    if ! unzip -o -q "$ZIP_FILE" -d "$CACHE_DIR"; then
        log "ERROR: unzip failed"
        exit 1
    fi
    log "extracted: $CSV_FILE"
fi

TOTAL=$(wc -l < "$CSV_FILE")
sample_file=$(mktemp "$CACHE_DIR/domains.XXXXXX")
if ! head -n "$TOP_N" "$CSV_FILE" | shuf -n "$QUERIES_PER_RUN" | cut -d, -f2 > "$sample_file"; then
    log "ERROR: failed to select sample domains"
    exit 1
fi

selected_domains=$(wc -l < "$sample_file")
log "start: selected $selected_domains domains from top $TOP_N of $TOTAL via $DNS_SERVER"

success=0
fail=0

while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue

    # A レコード
    if dig @"$DNS_SERVER" "$domain" A +short +time="$TIMEOUT" +tries=1 > /dev/null 2>&1; then
        success=$((success + 1))
    else
        fail=$((fail + 1))
    fi

    # AAAA レコード
    if dig @"$DNS_SERVER" "$domain" AAAA +short +time="$TIMEOUT" +tries=1 > /dev/null 2>&1; then
        success=$((success + 1))
    else
        fail=$((fail + 1))
    fi
done < "$sample_file"

log "done: success=$success fail=$fail (total=$((success + fail)) queries)"
