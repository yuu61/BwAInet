#!/bin/bash
# conntrack-logger (r2-gcp)
# venue→外部 public IP の NAT/NAT66 セッションのみ syslog facility local2 に出力。
# - original src/dst のみで判定 (reply 方向 src= の誤マッチ防止)
# - v4: src=venue subnet, dst=public (private/loopback/multicast 除外)
# - v6: src=venue GCP /64 (2600:1900:41d1:92::/64) のみ
#   r2 NAT66 source 以外は r2 を通過しないため dst フィルタ不要

V4_AWK='
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
'

V6_AWK='
  /\[(NEW|DESTROY)\]/ {
    src="";
    for (i=1; i<=NF; i++) {
      if (match($i, /^src=/)) { src = substr($i, 5); break }
    }
    if (src ~ /^2600:1900:41d1:92:/) print
  }
'

/usr/sbin/conntrack -E -e NEW,DESTROY -o timestamp,id 2>/dev/null \
  | /usr/bin/stdbuf -oL /usr/bin/awk "$V4_AWK" \
  | /usr/bin/logger -t conntrack-nat -p local2.info &
P4=$!

/usr/sbin/conntrack -f ipv6 -E -e NEW,DESTROY -o timestamp,id 2>/dev/null \
  | /usr/bin/stdbuf -oL /usr/bin/awk "$V6_AWK" \
  | /usr/bin/logger -t conntrack-nat6 -p local2.info &
P6=$!

trap "kill $P4 $P6 2>/dev/null" EXIT TERM INT
wait
