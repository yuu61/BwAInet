#!/bin/bash
# VyOS post-commit hook: pdns-recursor を v4-only outgoing に固定する。
#
# 背景:
#   r3 の IPv6 outgoing が 100% タイムアウトしており (outgoing6-timeouts / ipv6-outqueries)、
#   cold resolve で network-timeout (1500ms) × v6 試行回数ぶん stall する
#   (deb.debian.org で実測 3.2s)。VyOS の service_dns_forwarding.py テンプレートは
#   `query-local-address=0.0.0.0,::` を固定出力するため、生成後にこのスクリプトで
#   上書きして pdns-recursor を再起動する。
#
# 配置: /config/scripts/commit/post-hooks.d/10-pdns-recursor-v4only
# 発火タイミング: VyOS commit のたび (起動時の暗黙 commit を含む)

set -eu

CONF=/run/pdns-recursor/recursor.conf
[ -f "$CONF" ] || exit 0

if grep -qE '^query-local-address=0\.0\.0\.0,::$' "$CONF"; then
  sed -i 's/^query-local-address=0\.0\.0\.0,::$/query-local-address=0.0.0.0/' "$CONF"
  systemctl restart pdns-recursor
fi
