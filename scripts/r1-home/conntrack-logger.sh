#!/bin/bash
# conntrack-logger (r1-home)
# venue→外部 public IP の NAT セッションのみ syslog facility local2 に出力。
# - original src/dst のみで判定 (reply 方向 src= の誤マッチ防止)
# - dst が private/loopback/link-local/multicast の場合は除外
#   (家庭↔venue 等の内部通信、reply 方向の src=venue 誤マッチを排除)

/usr/sbin/conntrack -E -e NEW,DESTROY -o timestamp,id 2>/dev/null \
  | /usr/bin/stdbuf -oL /usr/bin/awk '
      /\[(NEW|DESTROY)\]/ {
        src=""; dst="";
        for (i=1; i<=NF; i++) {
          if (src=="" && match($i, /^src=/)) src = substr($i, 5)
          else if (dst=="" && match($i, /^dst=/)) { dst = substr($i, 5); break }
        }
        if (src ~ /^(192\.168\.(11|30|40|41|42|43)\.|10\.(64\.5[6-9]|255)\.)/ &&
            dst !~ /^(10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|127\.|169\.254\.|22[4-9]\.|2[3-5][0-9]\.)/) {
          print
        }
      }
    ' \
  | /usr/bin/logger -t conntrack-nat -p local2.info
