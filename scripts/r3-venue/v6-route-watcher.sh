#!/bin/bash
# v6-route-watcher.sh — netlink イベント駆動で v6-health-monitor をトリガ
#
# r3 の systemd で常駐実行 (v6-route-watcher.service):
#   sudo cp scripts/v6-route-watcher.sh  /config/scripts/
#   sudo cp scripts/v6-route-watcher.service  /etc/systemd/system/
#   sudo systemctl daemon-reload
#   sudo systemctl enable --now v6-route-watcher.service
#
# 動作:
#   `ip -6 monitor route` で kernel IPv6 ルーティング更新を watch。
#   wg0 / wg1 を絡む default route 変化を検知したら即 v6-health-monitor.sh --force-verify。
#   BGP 経路変化 (BFD 検知 → route withdraw) を 1-2 秒以内に拾い、
#   probe + deprecate まで含めて ~3-5 秒で RA lifetime=0 送出させる。
#
# デバウンス: 連続イベントは 3 秒ウィンドウで 1 回にまとめる (API スパム抑止)。

set -u

LOG_TAG="v6-route-watcher"
HEALTH_SCRIPT="/config/scripts/v6-health-monitor.sh"
LAST_RUN_FILE="/tmp/v6-route-watcher-last"
DEBOUNCE_SEC=3

log() { logger -t "$LOG_TAG" "$1"; }

log "started (watching wg0/wg1 default route)"

# ip monitor は無限ループで line を emit し続けるので exec で置き換え、
# pipe で while ループに流し込む。
/sbin/ip -6 monitor route | while read -r line; do
    # 関心: default route が wg0 or wg1 経由で add/change/delete されたとき
    # 典型的な行:
    #   "Deleted default via fe80::10:255:0:1 dev wg0 proto bgp metric 20"
    #   "default via fe80::10:255:1:2 dev wg1 proto bgp metric 20"
    if ! echo "$line" | grep -qE "default.*dev wg[01]"; then
        continue
    fi

    log "route event: $line"

    # デバウンス: 最終実行から DEBOUNCE_SEC 秒以内なら skip
    now=$(date +%s)
    last=$(cat "$LAST_RUN_FILE" 2>/dev/null || echo 0)
    if [ $((now - last)) -lt "$DEBOUNCE_SEC" ]; then
        log "debounced (last run ${now}s - ${last}s < ${DEBOUNCE_SEC}s)"
        continue
    fi
    echo "$now" > "$LAST_RUN_FILE"

    # health check を background で起動 (watcher 本体はブロックしない)
    "$HEALTH_SCRIPT" --force-verify &
    log "triggered v6-health-monitor.sh --force-verify (pid=$!)"
done
