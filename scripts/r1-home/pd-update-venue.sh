#!/bin/bash
# pd-update-venue.sh — DHCPv6-PD プレフィックス変更検知 & r3 自動更新
#
# r1 の task-scheduler で 1 分間隔実行:
#   set system task-scheduler task pd-update interval 1
#   set system task-scheduler task pd-update executable path /config/scripts/pd-update-venue.sh
#
# 動作:
#   1. dum0 の IPv6 グローバルアドレスから現在の /64 プレフィックスを取得
#   2. 前回のプレフィックスと比較
#   3. 変更があれば:
#      a. r1 の IPv6 ルートを wg0 経由に更新
#      b. r3 の VyOS API で OPTAGE 関連設定のみを差し替え
#         - interface address (eth2.30/40)
#         - router-advert prefix (eth2.30/40)
#         - router-advert name-server (eth2.30/40)
#         ※ GCP prefix / interval / other-config-flag / interface group 等は触らない
#         ※ DHCPv6-server は運用方針で廃止 (SLAAC only)、一切投入しない
#         ※ RA interval は radvd 既定値 (Min 200s / Max 600s) を使用、interval は set しない
#         ※ managed-flag は設計上使用しない (DHCPv6 未使用のため)
#
# WireGuard allowed-ips は OPTAGE 割当範囲 2001:ce8::/32 で固定済みのため
# プレフィックス変更時の更新は不要。

STATE_FILE="/tmp/pd_current_prefix"
R3_API="https://192.168.11.1"
API_KEY="BwAI"
LOG_TAG="pd-update-venue"

log() { logger -t "$LOG_TAG" "$1"; }

# --- 1. dum0 から現在のプレフィックスを取得 ---
DUM0_ADDR_FULL=$(ip -6 addr show dev dum0 scope global \
    | awk '/inet6 / {print $2}' | head -1)

if [ -z "$DUM0_ADDR_FULL" ]; then
    # dum0 にグローバル IPv6 がない (PPPoE 未接続 or PD 未取得)
    exit 0
fi

CURRENT_ADDR=$(echo "$DUM0_ADDR_FULL" | cut -d/ -f1)
CURRENT_PLEN=$(echo "$DUM0_ADDR_FULL" | cut -d/ -f2)

# dum0 の address は必ず /128 で保持する (BGP v6 冗長経路の install 阻害を回避)
# VyOS DHCPv6-PD delegation は /64 で自動付与するため、毎回 /128 に置き換える
if [ "$CURRENT_PLEN" != "128" ]; then
    log "dum0 addr is /${CURRENT_PLEN}, converting to /128 (avoid /64 connected blocking BGP)"
    ip -6 addr del "${CURRENT_ADDR}/${CURRENT_PLEN}" dev dum0 2>/dev/null
    ip -6 addr add "${CURRENT_ADDR}/128" dev dum0
fi

NEW_PREFIX=$(python3 -c "
import ipaddress
addr = ipaddress.IPv6Address('${CURRENT_ADDR}')
net = ipaddress.IPv6Network(str(addr) + '/64', strict=False)
print(str(net))
")

if [ -z "$NEW_PREFIX" ]; then
    log "ERROR: failed to compute prefix from ${CURRENT_ADDR}"
    exit 1
fi

PREFIX_ADDR=$(python3 -c "
import ipaddress
net = ipaddress.IPv6Network('${NEW_PREFIX}')
print(str(net.network_address))
")

# --- 2. 前回のプレフィックスと比較 ---
OLD_PREFIX=""
if [ -f "$STATE_FILE" ]; then
    OLD_PREFIX=$(cat "$STATE_FILE")
fi

if [ "$NEW_PREFIX" = "$OLD_PREFIX" ]; then
    # 変更なし — dum0 の connected 経路だけ抑止 (BGP 経路を優先させるため)
    # wg0 の static は追加しない (BGP の v6 冗長が同 prefix 競合で install 阻害されるため)
    ip -6 route del "$NEW_PREFIX" dev dum0 2>/dev/null
    exit 0
fi

log "PREFIX CHANGED: ${OLD_PREFIX:-'(none)'} -> ${NEW_PREFIX}"

# --- 3a. r1 ルート抑止 ---
# dum0 の connected 経路を削除 (BGP で受信した OPTAGE /64 経路を優先させる)
# wg0 の static は追加しない (BGP の v6 冗長が同 prefix 競合で install 阻害されるため)
ip -6 route del "$NEW_PREFIX" dev dum0 2>/dev/null
log "r1 dum0 route removed for $NEW_PREFIX (BGP takes over)"

# --- 3b. r3 API で OPTAGE 関連設定のみ差し替え ---
# 旧プレフィックス固有要素を削除 (router-advert/dhcpv6-server 全体は触らない)
if [ -n "$OLD_PREFIX" ]; then
    OLD_PREFIX_ADDR=$(python3 -c "
import ipaddress
net = ipaddress.IPv6Network('${OLD_PREFIX}')
print(str(net.network_address))
")
    log "Deleting old OPTAGE config on r3 (prefix: $OLD_PREFIX)"
    curl -sk --connect-timeout 10 -X POST "$R3_API/configure" \
        -H 'Content-Type: application/json' \
        -d "$(cat <<DELJSON
{
  "key": "$API_KEY",
  "commands": [
    {"op": "delete", "path": ["interfaces", "ethernet", "eth2", "vif", "30", "address", "${OLD_PREFIX_ADDR}1/64"]},
    {"op": "delete", "path": ["interfaces", "ethernet", "eth2", "vif", "40", "address", "${OLD_PREFIX_ADDR}2/64"]},
    {"op": "delete", "path": ["service", "router-advert", "interface", "eth2.30", "prefix", "${OLD_PREFIX}"]},
    {"op": "delete", "path": ["service", "router-advert", "interface", "eth2.40", "prefix", "${OLD_PREFIX}"]},
    {"op": "delete", "path": ["service", "router-advert", "interface", "eth2.30", "name-server", "${OLD_PREFIX_ADDR}1"]},
    {"op": "delete", "path": ["service", "router-advert", "interface", "eth2.40", "name-server", "${OLD_PREFIX_ADDR}2"]}
  ]
}
DELJSON
)" > /dev/null 2>&1
fi

# 新プレフィックスで設定を投入 (最小差分)
# - interface address: 新 OPTAGE /64 を eth2.30/40 に
# - router-advert prefix: lifetime 未指定 = radvd 既定 (preferred 14400, valid 2592000) = OPTAGE 優先継続
# - name-server: 新 OPTAGE アドレスで DNS forwarder の listen IP に
log "Applying new OPTAGE config on r3 (prefix: $NEW_PREFIX)"
RESULT=$(curl -sk --connect-timeout 10 -X POST "$R3_API/configure" \
    -H 'Content-Type: application/json' \
    -d "$(cat <<SETJSON
{
  "key": "$API_KEY",
  "commands": [
    {"op": "set", "path": ["interfaces", "ethernet", "eth2", "vif", "30", "address", "${PREFIX_ADDR}1/64"]},
    {"op": "set", "path": ["interfaces", "ethernet", "eth2", "vif", "40", "address", "${PREFIX_ADDR}2/64"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.30", "prefix", "${NEW_PREFIX}"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.40", "prefix", "${NEW_PREFIX}"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.30", "name-server", "${PREFIX_ADDR}1"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.40", "name-server", "${PREFIX_ADDR}2"]}
  ]
}
SETJSON
)")

if echo "$RESULT" | grep -q '"success": true'; then
    log "r3 config updated successfully"
    curl -sk --connect-timeout 10 -X POST "$R3_API/config-file" \
        -d "{\"key\":\"$API_KEY\",\"op\":\"save\"}" > /dev/null 2>&1
    log "r3 config saved"
else
    log "ERROR: r3 config update failed: $RESULT"
fi

# ステートファイル更新 (失敗時も次回リトライを阻害しないため更新)
echo "$NEW_PREFIX" > "$STATE_FILE"
log "State file updated: $NEW_PREFIX"
