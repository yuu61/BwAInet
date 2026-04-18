#!/usr/bin/env python3
"""
netflow-summary.py
==================
local-server (CT 200) で systemd timer から 5 分間隔で起動。

最新の完成済 nfcapd ファイル (`/mnt/data/nfcapd/nfcapd.YYYYMMDDHHMM`) から
Top-N サマリを集計し、

  1. `/var/log/netflow/netflow-summary-YYYYMMDD.json` に JSON Lines として append
     (Loki 側障害時の再送ソースとしてローカル保持)
  2. CT 201 (zabbix-grafana) の Loki に HTTP push

ラベル設計 (低 cardinality):
  source=netflow, host=<self>, type=top_src_ip|..., interval=5m
高 cardinality (IP / port / proto 値) は本文 JSON に含める。
"""
from __future__ import annotations

import csv
import json
import os
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

# ---------- 定数 ----------
NFDIR = Path("/mnt/data/nfcapd")
OUTDIR = Path("/var/log/netflow")
LOKI_PUSH_URL = "http://192.168.11.6:3100/loki/api/v1/push"
NFDUMP = "/usr/bin/nfdump"

STATS = [
    ("top_src_ip",   "srcip/bytes"),
    ("top_dst_ip",   "dstip/bytes"),
    ("top_src_port", "srcport/bytes"),
    ("top_dst_port", "dstport/bytes"),
    ("top_proto",    "proto/bytes"),
]
TOP_N = 20
CONV_N = 10

NFCAPD_RE = re.compile(r"^nfcapd\.\d{12}$")


# ---------- ヘルパ ----------
def latest_nfcapd() -> Path | None:
    candidates = sorted(p for p in NFDIR.iterdir() if NFCAPD_RE.match(p.name))
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


def to_float(v: str) -> float:
    try:
        return float(v)
    except (ValueError, TypeError):
        return 0.0


# ---------- 集計 ----------
def collect_stats(latest: Path, ts: str, src_file: str) -> list[dict]:
    records: list[dict] = []

    for type_, expr in STATS:
        out = run_nfdump("-r", str(latest), "-s", expr, "-n", str(TOP_N), "-o", "csv", "-q")
        for rank, row in enumerate(csv.DictReader(out.splitlines()), 1):
            if not row.get("val"):
                continue
            records.append({
                "ts": ts,
                "interval": "5m",
                "src_file": src_file,
                "type": type_,
                "rank": rank,
                "val": row["val"],
                "proto": row.get("pr", ""),
                "flows": to_int(row.get("fl", "0")),
                "flow_pct": to_float(row.get("flP", "0")),
                "bytes": to_int(row.get("byt", "0")),
                "byte_pct": to_float(row.get("bytP", "0")),
                "bps": to_int(row.get("bps", "0")),
                "pps": to_int(row.get("pps", "0")),
                "duration_s": to_float(row.get("td", "0")),
            })

    out = run_nfdump("-r", str(latest), "-s", "record/bytes", "-n", str(CONV_N), "-o", "csv", "-q")
    for rank, row in enumerate(csv.DictReader(out.splitlines()), 1):
        if not row.get("sa"):
            continue
        records.append({
            "ts": ts,
            "interval": "5m",
            "src_file": src_file,
            "type": "top_conv",
            "rank": rank,
            "sa": row["sa"],
            "da": row.get("da", ""),
            "sp": row.get("sp", ""),
            "dp": row.get("dp", ""),
            "pr": row.get("pr", ""),
            "bytes_in": to_int(row.get("ibyt", "0")),
            "bytes_out": to_int(row.get("obyt", "0")),
            "pkts_in": to_int(row.get("ipkt", "0")),
            "pkts_out": to_int(row.get("opkt", "0")),
            "duration_s": to_float(row.get("td", "0")),
        })
    return records


BYTE_SUFFIX = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}


def parse_bytes(s: str) -> int:
    m = re.match(r"([\d.]+)\s*([KMGT]?)", s.strip())
    if not m:
        return 0
    return int(float(m.group(1)) * BYTE_SUFFIX.get(m.group(2), 1))


def collect_summary(latest: Path, ts: str, src_file: str) -> dict | None:
    out = run_nfdump("-r", str(latest), "-n", "0")
    m = re.search(
        r"Summary:\s*total flows:\s*([\d,]+),"
        r"\s*total bytes:\s*([\d.]+\s*[KMGT]?),"
        r"\s*total packets:\s*([\d,]+),"
        r"\s*avg bps:\s*(\d+),"
        r"\s*avg pps:\s*(\d+),"
        r"\s*avg bpp:\s*(\d+)",
        out,
    )
    if not m:
        return None
    return {
        "ts": ts,
        "interval": "5m",
        "src_file": src_file,
        "type": "summary",
        "flows": int(m.group(1).replace(",", "")),
        "bytes": parse_bytes(m.group(2)),
        "packets": int(m.group(3).replace(",", "")),
        "avg_bps": int(m.group(4)),
        "avg_pps": int(m.group(5)),
        "avg_bpp": int(m.group(6)),
    }


# ---------- 出力 ----------
def write_local(out_path: Path, records: list[dict]) -> None:
    """日次ファイルに JSON Lines で append (line-buffered で部分書き込み防止)。"""
    with open(out_path, "a", buffering=1) as f:
        for rec in records:
            f.write(json.dumps(rec, ensure_ascii=False, separators=(",", ":")) + "\n")


def push_to_loki(records: list[dict], host: str, ts: str) -> int:
    """type ごとにストリームをまとめて Loki に push。失敗時は stderr にエラー、ファイルは保存済"""
    if not records:
        return 0

    # ts (ISO8601) → ナノ秒 epoch
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    ts_ns = str(int(dt.timestamp() * 1_000_000_000))

    by_type: dict[str, list[dict]] = defaultdict(list)
    for rec in records:
        by_type[rec["type"]].append(rec)

    streams = []
    for type_, recs in by_type.items():
        labels = {
            "source": "netflow",
            "host": host,
            "type": type_,
            "interval": "5m",
        }
        values = []
        for rec in recs:
            line = json.dumps(rec, ensure_ascii=False, separators=(",", ":"))
            values.append([ts_ns, line])
        streams.append({"stream": labels, "values": values})

    body = json.dumps({"streams": streams}).encode("utf-8")
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


# ---------- メイン ----------
def main() -> int:
    OUTDIR.mkdir(parents=True, exist_ok=True)

    latest = latest_nfcapd()
    if latest is None:
        return 0

    now = datetime.now(timezone.utc)
    ts = now.isoformat(timespec="seconds")
    out_path = OUTDIR / f"netflow-summary-{now.strftime('%Y%m%d')}.json"
    host = socket.gethostname()

    records = collect_stats(latest, ts, latest.name)
    summary = collect_summary(latest, ts, latest.name)
    if summary:
        records.append(summary)

    if not records:
        return 0

    write_local(out_path, records)
    push_to_loki(records, host, ts)

    return 0


if __name__ == "__main__":
    sys.exit(main())
