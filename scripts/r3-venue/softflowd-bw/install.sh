#!/usr/bin/env bash
# r3 VyOS に softflowd をインストールして wg0/wg1 向けの instanced unit を起動する。
# VyOS は rolling image のため image 更新で /usr/sbin/softflowd と /etc/systemd/system/
# 配下の unit が消える。再投入時にこのスクリプトを再実行する。
#
# 使い方 (local-server 経由で .deb を運ぶ例):
#   ssh local-server apt-get download softflowd
#   scp -3 local-server:/tmp/softflowd_*.deb r3-venue:/tmp/
#   scp -3 scripts/r3-venue/softflowd-bw/*.service scripts/r3-venue/softflowd-bw/*.env \
#        scripts/r3-venue/softflowd-bw/install.sh r3-venue:/tmp/
#   ssh r3-venue 'sudo bash /tmp/install.sh'

set -euo pipefail

DEB=$(ls /tmp/softflowd_*.deb 2>/dev/null | head -1 || true)
if [[ -n "${DEB}" && "$(command -v softflowd || true)" == "" ]]; then
  echo ">>> dpkg -i ${DEB}"
  dpkg -i "${DEB}"
fi

# Debian 既定 unit は無効化 (wg0/wg1 を instanced で運用)
systemctl disable --now softflowd.service 2>/dev/null || true

install -m 0644 /tmp/softflowd-bw@.service /etc/systemd/system/softflowd-bw@.service
install -m 0644 /tmp/softflowd-bw-wg0.env /etc/default/softflowd-bw-wg0
install -m 0644 /tmp/softflowd-bw-wg1.env /etc/default/softflowd-bw-wg1

systemctl daemon-reload
systemctl enable --now softflowd-bw@wg0.service softflowd-bw@wg1.service

echo ">>> done"
systemctl is-active softflowd-bw@wg0.service softflowd-bw@wg1.service
