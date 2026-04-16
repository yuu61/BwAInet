#!/bin/bash
# r1-home の WAN IP 追従 tracker
# 実行元: VyOS task-scheduler (毎分) + /config/scripts/vyos-postconfig-bootup.script
# 役割:
#   - tukushityann.net を解決
#   - r3 の wg0 peer endpoint を最新 IP に追従
#   - r1 公開 IP への /32 escape route (eth1 DHCP GW 経由) を設置
#     → BGP default (0.0.0.0/0 via wg0) で WG 外殻パケットが wg0 に吸われるループを防ぐ
#
# VyOS の validator 制約で config 内で FQDN / 動的 IP を使えないため、
# kernel 直叩き (wg set / ip route) で config 外から管理している。
# 詳細は docs/design/venue-vyos.md 参照。

set -u

FQDN="tukushityann.net"
WG_IF="wg0"
PEER_KEY="rTEhM34jCitAC3ULs3dd7dS/9BsB2JGQgSMCrJFUWE8="
WG_PORT="51820"
PHYS_IF="eth1"
STATE="/var/run/wg-r1-tracker.last-ip"

# r2-gcp endpoint (GCP 固定 IP)
R2_ENDPOINT="34.97.197.104"
R2_WG_IF="wg1"
R2_PEER_KEY="MrqbDhJi5hremMyo7lX1ColZshPKlwgiIjNlsel/w24="
R2_WG_PORT="51821"

# --- DNS 解決 ---
NEW_IP=$(getent ahostsv4 "$FQDN" 2>/dev/null | awk 'NR==1{print $1}')
if [ -z "$NEW_IP" ]; then
    logger -t wg-r1-tracker "DNS resolve failed: $FQDN"
    exit 0
fi

# --- eth1 の DHCP GW 取得 ---
# カーネルの route 出力は "default nhid N via X.X.X.X dev eth1 ..." 形式の場合があるため
# awk で "via" トークン直後の値を拾う (nhid と混同しない)
GW=$(ip -4 route show default dev "$PHYS_IF" \
    | awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')
if [ -z "$GW" ]; then
    logger -t wg-r1-tracker "No default route via $PHYS_IF, skipping"
    exit 0
fi

# --- /32 escape route を追従 (idempotent) ---
ip route replace "$NEW_IP/32" via "$GW" dev "$PHYS_IF" proto static

# --- 前回 IP の読み込み ---
LAST_IP=""
if [ -r "$STATE" ]; then
    LAST_IP=$(cat "$STATE")
fi

if [ "$LAST_IP" != "$NEW_IP" ]; then
    # 旧 /32 を削除 (新規追加済みなので安全)
    if [ -n "$LAST_IP" ] && [ "$LAST_IP" != "$NEW_IP" ]; then
        ip route del "$LAST_IP/32" 2>/dev/null || true
    fi
    # wg endpoint 更新
    wg set "$WG_IF" peer "$PEER_KEY" endpoint "$NEW_IP:$WG_PORT"
    echo "$NEW_IP" > "$STATE"
    logger -t wg-r1-tracker "r1 endpoint updated: ${LAST_IP:-<none>} -> $NEW_IP (via $GW dev $PHYS_IF)"
fi

# --- r2-gcp endpoint: wg0 経由の double encapsulation パス ---
# VyOS の WG peer address 設定は eth1 経由の auto-route を作成するが、
# 会場上流 (blackbox) が UDP をブロックする場合がある。
# wg0 (r1) 経由にルーティングし、r1 の escape route 経由で r2 に到達させる。
# VyOS config から address/port を削除し、wg set で endpoint を直接設定する。
ip route replace "$R2_ENDPOINT" via 10.255.0.1 dev wg0 proto static 2>/dev/null || true
wg set "$R2_WG_IF" peer "$R2_PEER_KEY" endpoint "$R2_ENDPOINT:$R2_WG_PORT" 2>/dev/null || true

exit 0
