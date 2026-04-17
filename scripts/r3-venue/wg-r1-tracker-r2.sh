#!/bin/bash
# r1-home の WAN IP 追従 tracker (r2-gcp 用)
# 実行元: VyOS task-scheduler (毎分) + /config/scripts/vyos-postconfig-bootup.script
# 役割:
#   - tukushityann.net を解決 (r1 の DDNS)
#   - r2 の wg1 peer endpoint を最新 IP に追従
#   - r1 公開 IP への /32 escape route (eth0 via GCE GW, onlink) を設置
#     → BGP default (0.0.0.0/0 via wg1) で WG 外殻パケットが wg1 に吸われるループを防ぐ
#   - table 200 の default route を onlink で設置 (policy local-route 用)
#
# GCE 固有:
#   - eth0 は /32 アドレスのため GCE GW (10.174.0.1) は直接接続ではない
#   - BGP default (via wg1) が static default (AD=210, via eth0) に勝つため、
#     next-hop 10.174.0.1 が wg1 経由に再帰解決されてループする
#   - GCE GW への /32 host route (dev eth0) を設置して再帰解決を防止
#   - VyOS の static route は onlink 非対応のため、kernel 直叩き (ip route) で管理

set -u

FQDN="tukushityann.net"
WG_IF="wg1"
PEER_KEY="rTEhM34jCitAC3ULs3dd7dS/9BsB2JGQgSMCrJFUWE8="
WG_PORT="51821"
PHYS_IF="eth0"
GCE_GW="10.174.0.1"
STATE="/var/run/wg-r1-tracker.last-ip"

# --- DNS 解決 ---
NEW_IP=$(getent ahostsv4 "$FQDN" 2>/dev/null | awk 'NR==1{print $1}')
if [ -z "$NEW_IP" ]; then
    logger -t wg-r1-tracker "DNS resolve failed: $FQDN"
    exit 0
fi

# --- GCE GW host route (全 next-hop 10.174.0.1 の再帰解決を防止) ---
# BGP default が wg1 を向くと、VyOS static route の next-hop 10.174.0.1 が
# wg1 経由に再帰解決される。GCE GW への /32 を dev eth0 で固定して防ぐ。
ip route replace "$GCE_GW/32" dev "$PHYS_IF" proto static 2>/dev/null || true

# --- /32 escape route を追従 ---
ip route replace "$NEW_IP/32" via "$GCE_GW" dev "$PHYS_IF" proto static

# --- table 200 の default route (policy local-route 用) ---
ip route replace default via "$GCE_GW" dev "$PHYS_IF" table 200

# --- 前回 IP の読み込み ---
LAST_IP=""
if [ -r "$STATE" ]; then
    LAST_IP=$(cat "$STATE")
fi

if [ "$LAST_IP" != "$NEW_IP" ]; then
    # 旧 /32 を削除
    if [ -n "$LAST_IP" ] && [ "$LAST_IP" != "$NEW_IP" ]; then
        ip route del "$LAST_IP/32" 2>/dev/null || true
    fi
    # wg endpoint 更新
    wg set "$WG_IF" peer "$PEER_KEY" endpoint "$NEW_IP:$WG_PORT"
    echo "$NEW_IP" > "$STATE"
    logger -t wg-r1-tracker "r1 endpoint updated: ${LAST_IP:-<none>} -> $NEW_IP (via $GCE_GW dev $PHYS_IF)"
fi

exit 0
