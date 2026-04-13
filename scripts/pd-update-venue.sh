#!/bin/bash
# pd-update-venue.sh — DHCPv6-PD プレフィックス変更検知 & r3 自動更新
#
# VyOS task-scheduler で 1 分間隔実行:
#   set system task-scheduler task pd-update interval 1m
#   set system task-scheduler task pd-update executable path /config/scripts/pd-update-venue.sh
#
# 動作:
#   1. dum0 の IPv6 グローバルアドレスから現在の /64 プレフィックスを取得
#   2. 前回のプレフィックスと比較
#   3. 変更があれば:
#      a. r1 の IPv6 ルートを wg0 経由に更新
#      b. r3 の VyOS API で IPv6 設定を全更新
#         (interface address, RA, DHCPv6, RA name-server)
#
# WireGuard allowed-ips は OPTAGE 割当範囲 2001:ce8::/32 で固定済みのため
# プレフィックス変更時の更新は不要。

STATE_FILE="/tmp/pd_current_prefix"
R3_API="https://192.168.11.1"
API_KEY="BwAI"
LOG_TAG="pd-update-venue"

log() { logger -t "$LOG_TAG" "$1"; }

# --- 1. dum0 から現在のプレフィックスを取得 ---
# DHCPv6-PD で付与された global /64 を flags に依存せず拾う
CURRENT_ADDR=$(ip -6 addr show dev dum0 scope global \
    | awk '/inet6 / {print $2}' | cut -d/ -f1 | head -1)

if [ -z "$CURRENT_ADDR" ]; then
    # dum0 にグローバル IPv6 がない (PPPoE 未接続 or PD 未取得)
    exit 0
fi

# アドレスからプレフィックス部分を計算 (下位 64bit をゼロ化)
# python3 で正確に計算
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

# プレフィックス部分のみ (::以前 + ::)
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
    # 変更なし — ルートが消えていないか確認だけ行う
    if ! ip -6 route show "$NEW_PREFIX" dev wg0 2>/dev/null | grep -q .; then
        log "WARN: wg0 route missing for $NEW_PREFIX, re-adding"
        ip -6 route del "$NEW_PREFIX" dev dum0 2>/dev/null
        ip -6 route replace "$NEW_PREFIX" dev wg0 metric 100
    fi
    exit 0
fi

log "PREFIX CHANGED: ${OLD_PREFIX:-'(none)'} -> ${NEW_PREFIX}"

# --- 3a. r1 ルート更新 ---
ip -6 route del "$NEW_PREFIX" dev dum0 2>/dev/null
ip -6 route replace "$NEW_PREFIX" dev wg0 metric 100
log "r1 route updated: $NEW_PREFIX -> wg0"

# --- 3b. r3 API で IPv6 設定を更新 ---
# 旧プレフィックスの設定を削除
if [ -n "$OLD_PREFIX" ]; then
    OLD_PREFIX_ADDR=$(python3 -c "
import ipaddress
net = ipaddress.IPv6Network('${OLD_PREFIX}')
print(str(net.network_address))
")
    log "Deleting old config on r3 (prefix: $OLD_PREFIX)"
    curl -sk --connect-timeout 10 -X POST "$R3_API/configure" \
        -H 'Content-Type: application/json' \
        -d "$(cat <<DELJSON
{
  "key": "$API_KEY",
  "commands": [
    {"op": "delete", "path": ["interfaces", "ethernet", "eth2", "vif", "30", "address", "${OLD_PREFIX_ADDR}1/64"]},
    {"op": "delete", "path": ["interfaces", "ethernet", "eth2", "vif", "40", "address", "${OLD_PREFIX_ADDR}2/64"]},
    {"op": "delete", "path": ["service", "router-advert"]},
    {"op": "delete", "path": ["service", "dhcpv6-server"]}
  ]
}
DELJSON
)" > /dev/null 2>&1
fi

# 新プレフィックスで設定を投入
log "Applying new config on r3 (prefix: $NEW_PREFIX)"
RESULT=$(curl -sk --connect-timeout 10 -X POST "$R3_API/configure" \
    -H 'Content-Type: application/json' \
    -d "$(cat <<SETJSON
{
  "key": "$API_KEY",
  "commands": [
    {"op": "set", "path": ["interfaces", "ethernet", "eth2", "vif", "30", "address", "${PREFIX_ADDR}1/64"]},
    {"op": "set", "path": ["interfaces", "ethernet", "eth2", "vif", "40", "address", "${PREFIX_ADDR}2/64"]},

    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.30", "prefix", "$NEW_PREFIX"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.30", "managed-flag"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.30", "other-config-flag"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.30", "name-server", "${PREFIX_ADDR}1"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.30", "interval", "max", "60"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.30", "interval", "min", "20"]},

    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.40", "prefix", "$NEW_PREFIX"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.40", "managed-flag"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.40", "other-config-flag"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.40", "name-server", "${PREFIX_ADDR}2"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.40", "interval", "max", "60"]},
    {"op": "set", "path": ["service", "router-advert", "interface", "eth2.40", "interval", "min", "20"]},

    {"op": "set", "path": ["service", "dhcpv6-server", "shared-network-name", "V6-POOL", "subnet", "$NEW_PREFIX", "range", "staff", "start", "${PREFIX_ADDR}1000"]},
    {"op": "set", "path": ["service", "dhcpv6-server", "shared-network-name", "V6-POOL", "subnet", "$NEW_PREFIX", "range", "staff", "stop", "${PREFIX_ADDR}ffff"]},
    {"op": "set", "path": ["service", "dhcpv6-server", "shared-network-name", "V6-POOL", "subnet", "$NEW_PREFIX", "range", "user", "start", "${PREFIX_ADDR}1:0"]},
    {"op": "set", "path": ["service", "dhcpv6-server", "shared-network-name", "V6-POOL", "subnet", "$NEW_PREFIX", "range", "user", "stop", "${PREFIX_ADDR}1:ffff"]},
    {"op": "set", "path": ["service", "dhcpv6-server", "shared-network-name", "V6-POOL", "subnet", "$NEW_PREFIX", "subnet-id", "60"]},
    {"op": "set", "path": ["service", "dhcpv6-server", "shared-network-name", "V6-POOL", "subnet", "$NEW_PREFIX", "option", "name-server", "${PREFIX_ADDR}1"]}
  ]
}
SETJSON
)")

if echo "$RESULT" | grep -q '"success": true'; then
    log "r3 config updated successfully"
    # r3 の設定を保存
    curl -sk --connect-timeout 10 -X POST "$R3_API/config-file" \
        -d "{\"key\":\"$API_KEY\",\"op\":\"save\"}" > /dev/null 2>&1
    log "r3 config saved"
else
    log "ERROR: r3 config update failed: $RESULT"
    # 失敗してもステートは更新して無限リトライを防止
    # 次回のスクリプト実行時にルート修復は試みる
fi

# ステートファイル更新
echo "$NEW_PREFIX" > "$STATE_FILE"
log "State file updated: $NEW_PREFIX"
