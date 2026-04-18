#!/usr/bin/env python3
"""
netflow-bw-summary.py
=====================
local-server (CT 200) で systemd timer から 5 分間隔で起動。

r3 VyOS 上の softflowd (wg0/wg1 別プロセス) が別ポート (2056/2057) に NetFlow v9 を
送出し、local-server の nfcapd インスタンスが `/mnt/data/nfcapd-bw-r1/` および
`/mnt/data/nfcapd-bw-r2/` に 5 分ローテーションで保存する。

このスクリプトは両ディレクトリを読み、

  - route: r1 (wg0 = r1-home 経路) / r2 (wg1 = r2-gcp 経路)
  - dir:   up (sa が venue 内部プレフィックス) / down (da が venue 内部)
  - ver:   v4 / v6

の 3 軸で 5 分 bytes/packets を集計し、

  1. `/var/log/netflow/netflow-bw-YYYYMMDD.json` に JSON Lines で append
  2. zabbix-grafana の Loki に `{source="netflow", type="bw"}` で push

する。既存 netflow-summary.py (forensic 用) とは完全に独立した経路。
"""
from __future__ import annotations

import csv
import ipaddress
import json
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

OUTDIR = Path("/var/log/netflow")
LOKI_PUSH_URL = "http://192.168.11.6:3100/loki/api/v1/push"
NFDUMP = "/usr/bin/nfdump"

# (route, nfcapd 保存ディレクトリ)。softflowd 側の割当は scripts/r3-venue/softflowd-bw/ 参照
BW_SOURCES: tuple[tuple[str, Path], ...] = (
    ("r1", Path("/mnt/data/nfcapd-bw-r1")),
    ("r2", Path("/mnt/data/nfcapd-bw-r2")),
)

# venue 内部プレフィックス。sa/da がここに該当すれば「venue 内部」扱い
INTERNAL_V4_NETS = tuple(ipaddress.ip_network(p) for p in (
    "192.168.0.0/16",  # VLAN 11/30/40 + 家族 LAN + mgmt
    "10.0.0.0/8",      # WireGuard tunnel (10.255.x.x) / 予備
    "172.16.0.0/12",   # 予備 RFC1918
))
INTERNAL_V6_NETS = tuple(ipaddress.ip_network(p) for p in (
    "2001:ce8:180:5a79::/64",  # OPTAGE venue
    "2600:1900:41d1:92::/64",  # GCP venue
    "fc00::/7",                # ULA
    "fd00:255::/32",           # WireGuard tunnel v6
))

NFCAPD_RE = re.compile(r"^nfcapd\.\d{12}$")

# nfdump 1.7.x `-o csv -q` のカラム位置 (ヘッダー無し固定順)
# 0:ts 1:te 2:td 3:sa 4:da 5:sp 6:dp 7:pr 8:flg 9:fwd 10:stos
# 11:ipkt 12:ibyt 13:opkt 14:obyt 15:in 16:out ...
_CSV_IDX_SA, _CSV_IDX_DA = 3, 4
_CSV_IDX_IPKT, _CSV_IDX_IBYT, _CSV_IDX_OPKT, _CSV_IDX_OBYT = 11, 12, 13, 14


def latest_nfcapd(nfdir: Path) -> Path | None:
    if not nfdir.is_dir():
        return None
    candidates = sorted(p for p in nfdir.iterdir() if NFCAPD_RE.match(p.name))
    return candidates[-1] if candidates else None


def run_nfdump(*args: str) -> str:
    res = subprocess.run([NFDUMP, *args], capture_output=True, text=True, check=False)
    if res.returncode != 0:
        sys.stderr.write(f"nfdump {args} failed: {res.stderr.strip()}\n")
    return res.stdout


def to_int(v: str) -> int:
    try:
        return int(float(v))
    except (ValueError, TypeError):
        return 0


def _is_internal(addr: str) -> bool:
    try:
        ip = ipaddress.ip_address(addr)
    except ValueError:
        return False
    if ip.is_link_local or ip.is_multicast or ip.is_loopback:
        return False
    nets = INTERNAL_V6_NETS if ip.version == 6 else INTERNAL_V4_NETS
    return any(ip in n for n in nets)


def collect_bw_for(route: str, latest: Path, ts: str) -> list[dict]:
    out = run_nfdump("-r", str(latest), "-o", "csv", "-q", "-n", "0")
    counters: dict[tuple[str, str], dict[str, int]] = defaultdict(
        lambda: {"bytes": 0, "pkts": 0}
    )
    for row in csv.reader(out.splitlines()):
        if len(row) <= _CSV_IDX_OBYT:
            continue
        sa = row[_CSV_IDX_SA].strip()
        da = row[_CSV_IDX_DA].strip()
        if not sa or not da:
            continue
        byt = to_int(row[_CSV_IDX_IBYT]) + to_int(row[_CSV_IDX_OBYT])
        if byt <= 0:
            continue
        pkt = to_int(row[_CSV_IDX_IPKT]) + to_int(row[_CSV_IDX_OPKT])

        sa_int = _is_internal(sa)
        da_int = _is_internal(da)
        if sa_int and not da_int:
            direction = "up"
        elif da_int and not sa_int:
            direction = "down"
        else:
            continue

        ver = "v6" if (":" in sa or ":" in da) else "v4"
        key = (direction, ver)
        counters[key]["bytes"] += byt
        counters[key]["pkts"] += pkt

    records: list[dict] = []
    for (direction, ver), v in counters.items():
        records.append({
            "ts": ts,
            "interval": "5m",
            "src_file": latest.name,
            "type": "bw",
            "route": route,
            "dir": direction,
            "ver": ver,
            "bytes": v["bytes"],
            "pkts": v["pkts"],
        })
    return records


def write_local(out_path: Path, records: list[dict]) -> None:
    with open(out_path, "a", buffering=1) as f:
        for rec in records:
            f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")


def push_to_loki(records: list[dict], host: str, ts: str) -> int:
    if not records:
        return 0
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    ts_ns = str(int(dt.timestamp() * 1_000_000_000))
    labels = {"source": "netflow", "host": host, "type": "bw", "interval": "5m"}
    values = [[ts_ns, json.dumps(rec, ensure_ascii=False, separators=(",", ":"))] for rec in records]
    body = json.dumps({"streams": [{"stream": labels, "values": values}]}).encode("utf-8")
    req = urllib.request.Request(
        LOKI_PUSH_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"loki push HTTP {e.code}: {e.read().decode()[:300]}\n")
        return e.code
    except Exception as e:
        sys.stderr.write(f"loki push error: {e}\n")
        return -1


def main() -> int:
    OUTDIR.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc)
    ts = now.isoformat(timespec="seconds")
    out_path = OUTDIR / f"netflow-bw-{now.strftime('%Y%m%d')}.json"
    host = socket.gethostname()

    records: list[dict] = []
    for route, nfdir in BW_SOURCES:
        latest = latest_nfcapd(nfdir)
        if latest is None:
            continue
        records.extend(collect_bw_for(route, latest, ts))

    if not records:
        return 0

    write_local(out_path, records)
    push_to_loki(records, host, ts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
