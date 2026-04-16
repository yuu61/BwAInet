#!/bin/bash
# NDP table dump for forensic logging (VLAN 30/40 IPv6→MAC mapping)
# Runs every 1 minute via VyOS task-scheduler on r3.
# Sends to syslog facility local1, forwarded to CT 200 (192.168.11.2),
# rsyslog ruleset writes to /mnt/data/syslog-archive/ndp/.

for dev in eth2.30 eth2.40; do
  ip -6 neigh show dev "$dev" | sed "s/^/dev=$dev /" | logger -p local1.info -t ndp-dump
done
