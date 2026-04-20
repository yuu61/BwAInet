#!/usr/bin/env bash
# VyOS 起動時に /config/scripts/vyos-postconfig-bootup.script から呼ばれる。
# rolling image で /usr/sbin/softflowd と systemd unit が消えるため、
# /config/scripts/softflowd-bw/ に永続化した資産から再投入する。

set -eu

DIR=/config/scripts/softflowd-bw

# softflowd バイナリが無ければ .deb から install (Debian bookworm 由来 1.1.0)
if [[ ! -x /usr/sbin/softflowd ]]; then
    DEB=$(ls "${DIR}"/softflowd_*.deb 2>/dev/null | head -1 || true)
    if [[ -n "${DEB}" ]]; then
        dpkg -i "${DEB}" >/dev/null 2>&1 || true
        # Debian 既定 unit (softflowd.service) は instanced 運用と競合するため無効化
        systemctl disable --now softflowd.service 2>/dev/null || true
    fi
fi

install -m 0644 "${DIR}/softflowd-bw@.service" /etc/systemd/system/softflowd-bw@.service
install -m 0644 "${DIR}/softflowd-bw-wg0.env" /etc/default/softflowd-bw-wg0
install -m 0644 "${DIR}/softflowd-bw-wg1.env" /etc/default/softflowd-bw-wg1

systemctl daemon-reload
systemctl enable --now softflowd-bw@wg0.service softflowd-bw@wg1.service
