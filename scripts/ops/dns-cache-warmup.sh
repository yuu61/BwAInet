#!/bin/bash
# dns-cache-warmup.sh — r3 の DNS キャッシュを dnsperf で人気ドメイン上位 N 件から事前投入する (クライアント側実行版)
#
# 使い方:
#   ./dns-cache-warmup.sh
#   DNS_SERVER=192.168.11.1 TOP_N=10000 CLIENTS=10 ./dns-cache-warmup.sh
#
# 動作:
#   Cisco Umbrella Top 1M を /tmp にダウンロード・展開し、
#   上位 TOP_N 件から A/AAAA の dnsperf 入力ファイルを生成して実行、
#   r3 の PowerDNS Recursor キャッシュを温める。
#   CSV は 24 時間キャッシュし、以降の実行では再ダウンロードしない。
#
# 依存: dnsperf (dns-oarc), curl, unzip

set -euo pipefail

DNS_SERVER="${DNS_SERVER:-192.168.11.1}"
TOP_N="${TOP_N:-10000}"
CLIENTS="${CLIENTS:-10}"          # dnsperf -c: 並列クライアント数
MAX_QPS="${MAX_QPS:-0}"           # dnsperf -Q: 最大 QPS (0=無制限)
RUN_TIMEOUT="${RUN_TIMEOUT:-60}"  # dnsperf -l: 実行時間上限 (秒)

UMBRELLA_URL="https://s3-us-west-1.amazonaws.com/umbrella-static/top-1m.csv.zip"
CACHE_DIR="/tmp/dns-cache-warmup"
ZIP_FILE="$CACHE_DIR/top-1m.csv.zip"
CSV_FILE="$CACHE_DIR/top-1m.csv"
QUERY_FILE="$CACHE_DIR/queries.txt"
CACHE_MAX_AGE=86400

log() { echo "[dns-warmup] $*" >&2; }

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

for cmd in dnsperf curl unzip; do
    if ! command -v "$cmd" > /dev/null 2>&1; then
        log "ERROR: $cmd command not found"
        exit 1
    fi
done

if ! is_positive_integer "$TOP_N"; then
    log "ERROR: TOP_N must be a positive integer (got: $TOP_N)"
    exit 1
fi

mkdir -p "$CACHE_DIR"

# --- Umbrella Top 1M の取得 (24h キャッシュ) ---
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

# --- dnsperf 入力ファイル生成 (<domain> <type> 形式) ---
# Umbrella CSV が CRLF の場合に \r が混入すると NXDOMAIN を量産するため tr -d で除去
head -n "$TOP_N" "$CSV_FILE" | tr -d '\r' | cut -d, -f2 | awk 'NF{print $1" A"; print $1" AAAA"}' > "$QUERY_FILE"
query_count=$(wc -l < "$QUERY_FILE")
log "prepared $query_count queries (top $TOP_N × {A,AAAA}) in $QUERY_FILE"

# --- dnsperf 実行 ---
log "running dnsperf against $DNS_SERVER (clients=$CLIENTS, max_qps=$MAX_QPS, timeout=${RUN_TIMEOUT}s)"
dnsperf_args=(
    -s "$DNS_SERVER"
    -d "$QUERY_FILE"
    -c "$CLIENTS"
    -l "$RUN_TIMEOUT"
    -n 1  # 入力を 1 パスのみ (未指定だと -l の間ループし続ける)
)
if (( MAX_QPS > 0 )); then
    dnsperf_args+=( -Q "$MAX_QPS" )
fi

dnsperf "${dnsperf_args[@]}"
