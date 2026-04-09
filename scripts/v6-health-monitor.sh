#!/bin/bash
# v6-health-monitor.sh — IPv6 出口ヘルスチェック & RA プレフィックス廃止/復旧
#
# r3 の VyOS task-scheduler で 5 分間隔実行:
#   set system task-scheduler task v6-health interval 5
#   set system task-scheduler task v6-health executable path /config/scripts/v6-health-monitor.sh
#
# 動作:
#   各出口 (OPTAGE via r1, GCP via r2) に対して ping プローブを実行。
#   3 回連続失敗で障害判定 → 該当プレフィックスの RA を lifetime=0 に変更。
#   3 回連続成功で復旧判定 → RA を設計値の lifetime に戻す。
#
# 判定タイムライン (interval=5 の場合):
#   t=0min   障害発生
#   t=15min  3 回連続失敗 → RA lifetime=0 送出
#            クライアントが deprecated プレフィックスの使用を停止

set -u

exec 9>/tmp/v6-health.lock
flock -n 9 || { logger -t "v6-health" "another instance running, skip"; exit 0; }

STATE_DIR="/tmp/v6-health"
API_URL="https://192.168.11.1"
API_KEY="BwAI"
LOG_TAG="v6-health"
RA_INTERFACES="eth2.30 eth2.40"

FAIL_THRESHOLD=3   # 連続失敗回数で障害判定
OK_THRESHOLD=3     # 連続成功回数で復旧判定

# プローブ先 (複数指定: いずれか 1 つに到達できれば OK)
# Google Public DNS, Cloudflare DNS, Google DNS (alt)
PROBE_TARGETS="2001:4860:4860::8888 2606:4700:4700::1111 2001:4860:4860::8844"

# --- 設計値: 各出口の RA prefix lifetime ---
# OPTAGE: VyOS デフォルト (preferred=14400, valid=2592000) を使用
#         → restore 時は lifetime 設定を delete する
# GCP:    OPTAGE より短い lifetime で非優先化
#         → restore 時はこの値を set する
OPTAGE_RESTORE_MODE="delete"
GCP_PREFIX_HINT="2600:1900:"           # GCP subnet 検出用プレフィックス
GCP_RESTORE_MODE="set"
GCP_PREFERRED_LIFETIME="1800"
GCP_VALID_LIFETIME="14400"

log() { logger -t "$LOG_TAG" "$1"; }
mkdir -p "$STATE_DIR"
log "=== health check start ==="

# --- プローブ関数 ---
# 引数: $1=ソースアドレス
# ソースアドレスを指定することで、カーネルの src-based ルーティングにより
# OPTAGE ソース → wg0 → r1, GCP ソース → wg1 → r2 に振り分けられる。
probe_exit() {
    local src_addr="$1"

    if [ -z "$src_addr" ]; then
        return 1
    fi

    for target in $PROBE_TARGETS; do
        if ping -6 -c 1 -W 2 -I "$src_addr" "$target" > /dev/null 2>&1; then
            return 0  # 1 つでも到達できれば OK
        fi
    done
    return 1  # 全滅
}

# --- 状態管理関数 ---
get_fail_count() { cat "$STATE_DIR/${1}_fail" 2>/dev/null || echo 0; }
get_ok_count()   { cat "$STATE_DIR/${1}_ok"   2>/dev/null || echo 0; }

# unknown: ステートファイル未存在 (再起動後の初回)
get_status() { cat "$STATE_DIR/${1}_status" 2>/dev/null || echo "unknown"; }

# --- RA 制御関数 ---
# deprecate: 全 RA インターフェースの該当プレフィックスを lifetime=0 にする
deprecate_prefix() {
    local prefix="$1"
    local cmds=""

    for iface in $RA_INTERFACES; do
        cmds="${cmds}{\"op\":\"set\",\"path\":[\"service\",\"router-advert\",\"interface\",\"${iface}\",\"prefix\",\"${prefix}\",\"preferred-lifetime\",\"0\"]},"
        cmds="${cmds}{\"op\":\"set\",\"path\":[\"service\",\"router-advert\",\"interface\",\"${iface}\",\"prefix\",\"${prefix}\",\"valid-lifetime\",\"0\"]},"
    done
    cmds="${cmds%,}"

    local http_code
    http_code=$(curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' \
        -X POST "$API_URL/configure" \
        -H 'Content-Type: application/json' \
        -d "{\"key\":\"${API_KEY}\",\"commands\":[${cmds}]}" 2>/dev/null)
    [ "$http_code" = "200" ]
}

# restore: 設計値に戻す
#   mode=delete → lifetime 設定を削除して VyOS デフォルトに戻す (OPTAGE 用)
#   mode=set    → 指定した lifetime を set する (GCP 用)
restore_prefix() {
    local prefix="$1"
    local mode="$2"
    local pref_lt="$3"
    local valid_lt="$4"
    local cmds=""

    for iface in $RA_INTERFACES; do
        if [ "$mode" = "delete" ]; then
            cmds="${cmds}{\"op\":\"delete\",\"path\":[\"service\",\"router-advert\",\"interface\",\"${iface}\",\"prefix\",\"${prefix}\",\"preferred-lifetime\"]},"
            cmds="${cmds}{\"op\":\"delete\",\"path\":[\"service\",\"router-advert\",\"interface\",\"${iface}\",\"prefix\",\"${prefix}\",\"valid-lifetime\"]},"
        else
            cmds="${cmds}{\"op\":\"set\",\"path\":[\"service\",\"router-advert\",\"interface\",\"${iface}\",\"prefix\",\"${prefix}\",\"preferred-lifetime\",\"${pref_lt}\"]},"
            cmds="${cmds}{\"op\":\"set\",\"path\":[\"service\",\"router-advert\",\"interface\",\"${iface}\",\"prefix\",\"${prefix}\",\"valid-lifetime\",\"${valid_lt}\"]},"
        fi
    done
    cmds="${cmds%,}"

    local http_code
    http_code=$(curl -sk --connect-timeout 5 -o /dev/null -w '%{http_code}' \
        -X POST "$API_URL/configure" \
        -H 'Content-Type: application/json' \
        -d "{\"key\":\"${API_KEY}\",\"commands\":[${cmds}]}" 2>/dev/null)

    # delete モードでは「削除対象が存在しない」(400) も成功扱い
    # (既にデフォルト lifetime の場合、delete するものがない)
    if [ "$mode" = "delete" ]; then
        [ "$http_code" = "200" ] || [ "$http_code" = "400" ]
    else
        [ "$http_code" = "200" ]
    fi
}

# --- 出口チェック共通関数 ---
# 引数: $1=出口名, $2=prefix, $3=src_addr, $4=restore_mode, $5=pref_lt, $6=valid_lt
check_exit() {
    local name="$1"
    local prefix="$2"
    local src_addr="$3"
    local restore_mode="$4"
    local pref_lt="$5"
    local valid_lt="$6"

    if [ -z "$prefix" ]; then return; fi
    if [ -z "$src_addr" ]; then
        log "$name: src_addr is empty (src_from_prefix failed?), skipping"
        return
    fi

    local status
    status=$(get_status "$name")

    # --- 初回起動 (status=unknown) ---
    # /tmp は tmpfs のため再起動でステートが消える。
    # saved config に lifetime=0 が残っていても、プローブ結果に基づいて正しく初期化する。
    # probe OK → 即 restore (安全: 正常状態の確認)
    # probe FAIL → status=unknown のまま fail_count を累積。閾値到達で deprecate。
    #              unknown 中に probe OK が来れば即 restore する。
    #              (起動直後は BGP 再収束等で一時的に失敗しやすいため即 deprecate しない)
    if [ "$status" = "unknown" ]; then
        if probe_exit "$src_addr"; then
            log "$name exit INIT: probe OK, restoring prefix $prefix"
            if restore_prefix "$prefix" "$restore_mode" "$pref_lt" "$valid_lt"; then
                echo "up" > "$STATE_DIR/${name}_status"
            else
                log "$name exit INIT: restore API call failed (HTTP error), will retry next cycle"
            fi
            echo 0 > "$STATE_DIR/${name}_fail"
            echo 1 > "$STATE_DIR/${name}_ok"
        else
            local fail_count
            fail_count=$(get_fail_count "$name")
            fail_count=$((fail_count + 1))
            log "$name exit INIT: probe FAIL (fail_count=$fail_count/$FAIL_THRESHOLD)"
            echo "$fail_count" > "$STATE_DIR/${name}_fail"
            echo 0 > "$STATE_DIR/${name}_ok"

            if [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
                log "$name exit INIT: threshold reached, deprecating prefix $prefix"
                if deprecate_prefix "$prefix"; then
                    echo "down" > "$STATE_DIR/${name}_status"
                else
                    log "$name exit INIT: deprecate API call failed, will retry next cycle"
                fi
            fi
        fi
        return
    fi

    # --- 通常運用 ---
    if probe_exit "$src_addr"; then
        log "$name: probe OK (status=$status)"
        echo 0 > "$STATE_DIR/${name}_fail"
        local ok_count
        ok_count=$(get_ok_count "$name")
        ok_count=$((ok_count + 1))
        echo "$ok_count" > "$STATE_DIR/${name}_ok"

        if [ "$status" = "down" ] && [ "$ok_count" -ge "$OK_THRESHOLD" ]; then
            log "$name exit RECOVERED ($ok_count consecutive OK)"
            if restore_prefix "$prefix" "$restore_mode" "$pref_lt" "$valid_lt"; then
                echo "up" > "$STATE_DIR/${name}_status"
                echo 0 > "$STATE_DIR/${name}_ok"
            else
                log "$name: restore API call failed, will retry next cycle"
            fi
        fi
    else
        log "$name: probe FAIL (status=$status)"
        echo 0 > "$STATE_DIR/${name}_ok"
        local fail_count
        fail_count=$(get_fail_count "$name")
        fail_count=$((fail_count + 1))
        echo "$fail_count" > "$STATE_DIR/${name}_fail"

        if [ "$status" = "up" ] && [ "$fail_count" -ge "$FAIL_THRESHOLD" ]; then
            log "$name exit FAILED ($fail_count consecutive failures)"
            if deprecate_prefix "$prefix"; then
                echo "down" > "$STATE_DIR/${name}_status"
                echo 0 > "$STATE_DIR/${name}_fail"
            else
                log "$name: deprecate API call failed, will retry next cycle"
            fi
        fi
    fi
}

# --- メインロジック ---
# RA 設定からプレフィックスを動的検出
RA_HTTP_CODE=$(curl -sk --connect-timeout 3 -o /tmp/v6-health-ra.json -w '%{http_code}' \
    -X POST "$API_URL/retrieve" \
    -d "{\"key\":\"$API_KEY\",\"op\":\"showConfig\",\"path\":[\"service\",\"router-advert\",\"interface\",\"eth2.30\",\"prefix\"]}" \
    2>/dev/null)

if [ "$RA_HTTP_CODE" != "200" ]; then
    log "ERROR: RA config retrieval failed (HTTP $RA_HTTP_CODE), aborting health check"
    exit 1
fi

RA_JSON=$(cat /tmp/v6-health-ra.json)
if ! echo "$RA_JSON" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    log "ERROR: RA config response is not valid JSON, aborting health check"
    exit 1
fi

# prefix_hint に前方一致するプレフィックスを RA 設定から検出し、::1 をソースアドレスとする
detect_prefix() {
    local hint="$1"
    echo "$RA_JSON" | python3 -c "
import sys, json
hint = sys.argv[1]
d = json.load(sys.stdin)
for k in d.get('data', {}).get('prefix', {}):
    if k.startswith(hint):
        print(k); break
" "$hint" 2>/dev/null
}

src_from_prefix() {
    python3 -c "
import sys, ipaddress
net = ipaddress.IPv6Network(sys.argv[1])
print(net.network_address + 1)
" "$1" 2>/dev/null
}

OPTAGE_PREFIX=$(detect_prefix "2001:ce8:")
GCP_PREFIX=$(detect_prefix "$GCP_PREFIX_HINT")

OPTAGE_SRC=""
GCP_SRC=""

if [ -n "$OPTAGE_PREFIX" ]; then
    OPTAGE_SRC=$(src_from_prefix "$OPTAGE_PREFIX")
else
    log "WARNING: OPTAGE prefix not found in RA config (hint=2001:ce8:), skipping optage check"
fi

if [ -n "$GCP_PREFIX" ]; then
    GCP_SRC=$(src_from_prefix "$GCP_PREFIX")
else
    log "WARNING: GCP prefix not found in RA config (hint=$GCP_PREFIX_HINT), skipping gcp check"
fi

# チェック実行
check_exit "optage" "$OPTAGE_PREFIX" "$OPTAGE_SRC" "$OPTAGE_RESTORE_MODE" "" ""
check_exit "gcp"    "$GCP_PREFIX"    "$GCP_SRC"    "$GCP_RESTORE_MODE"    "$GCP_PREFERRED_LIFETIME" "$GCP_VALID_LIFETIME"

log "=== health check end ==="
