#!/usr/bin/env python3
"""
dhcpdns-collector.py
====================
r3-venue (VyOS) の task-scheduler から 1 分間隔で起動 (root 実行)。

- Kea control socket (/run/kea/dhcp4-ctrl-socket) から statistic-get-all
- pdns-recursor `rec_control get-all` で全メトリクス
- /var/lib/dhcpdns-collector/last.json と比較して累積カウンタを delta 化
  (NetFlow ダッシュボードと同じ `sum_over_time(unwrap *_delta)` idiom が使える)
- CT 201 (192.168.11.6:3100) の Loki に HTTP push

Loki ラベル (低 cardinality):
  source=dhcpdns, host=<self>, type=kea_global|kea_subnet|recursor, interval=1m
高 cardinality (subnet id, 個別 metric 値) は本文 JSON に含める。
"""
from __future__ import annotations

import json
import socket
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# ---------- 定数 ----------
KEA_SOCK = "/run/kea/dhcp4-ctrl-socket"
RECTL = "/usr/bin/rec_control"
STATE_DIR = Path("/var/lib/dhcpdns-collector")
STATE_FILE = STATE_DIR / "last.json"
LOKI_PUSH_URL = "http://192.168.11.6:3100/loki/api/v1/push"

KEA_GLOBAL_COUNTERS = [
    "pkt4-discover-received",
    "pkt4-offer-sent",
    "pkt4-request-received",
    "pkt4-ack-sent",
    "pkt4-nak-sent",
    "pkt4-decline-received",
    "pkt4-release-received",
    "pkt4-inform-received",
    "pkt4-parse-failed",
    "pkt4-receive-drop",
    "pkt4-received",
    "cumulative-assigned-addresses",
]

KEA_SUBNET_GAUGES = ["assigned-addresses", "total-addresses", "declined-addresses"]
KEA_SUBNET_COUNTERS = ["cumulative-assigned-addresses", "reclaimed-leases"]

REC_COUNTERS = [
    "questions", "all-outqueries", "cache-hits", "cache-misses",
    "packetcache-hits", "packetcache-misses",
    "noerror-answers", "nxdomain-answers", "servfail-answers",
    "answers0-1", "answers1-10", "answers10-100", "answers100-1000", "answers-slow",
    "tcp-questions", "tcp-outqueries",
    "throttled-outqueries", "outgoing-timeouts",
    "ipv6-questions", "ipv6-outqueries",
    "auth-zone-queries", "dnssec-validations",
]

REC_GAUGES = [
    "cache-entries", "packetcache-entries",
    "concurrent-queries", "qa-latency", "uptime",
]


# ---------- Kea ----------
def kea_call(command: str) -> dict:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(KEA_SOCK)
    s.send(json.dumps({"command": command}).encode())
    buf = b""
    while True:
        try:
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
        except socket.timeout:
            break
    s.close()
    return json.loads(buf.decode())


def kea_latest(stat) -> int:
    """Kea statistic-get-all は [[value, ts], ...] の履歴配列。最新は先頭 [0][0]。"""
    if isinstance(stat, list) and stat and isinstance(stat[0], list):
        try:
            return int(stat[0][0])
        except (ValueError, TypeError):
            return 0
    if isinstance(stat, (int, float)):
        return int(stat)
    return 0


def get_subnet_name_map() -> dict[int, str]:
    """Kea config-get から subnet id → 名前 (shared-network 名)。"""
    try:
        resp = kea_call("config-get")
        if resp.get("result") != 0:
            return {}
        cfg = resp.get("arguments", {}).get("Dhcp4", {})
        result: dict[int, str] = {}
        for sn in cfg.get("shared-networks", []):
            net_name = sn.get("name", "")
            for sub in sn.get("subnet4", []):
                sid = sub.get("id")
                if sid is not None:
                    result[int(sid)] = net_name or sub.get("subnet", str(sid))
        for sub in cfg.get("subnet4", []):
            sid = sub.get("id")
            if sid is not None and sid not in result:
                result[int(sid)] = sub.get("subnet", str(sid))
        return result
    except Exception as e:
        sys.stderr.write(f"subnet map err: {e}\n")
        return {}


def collect_kea() -> tuple[dict[str, int], dict[int, dict[str, int]]]:
    resp = kea_call("statistic-get-all")
    if resp.get("result") != 0:
        return {}, {}
    args = resp.get("arguments", {})

    global_m: dict[str, int] = {}
    for k in KEA_GLOBAL_COUNTERS:
        if k in args:
            global_m[k.replace("-", "_")] = kea_latest(args[k])

    subnet_m: dict[int, dict[str, int]] = {}
    for key, val in args.items():
        if not key.startswith("subnet["):
            continue
        try:
            close = key.index("]")
            sid = int(key[7:close])
            metric = key[close + 2:]
        except ValueError:
            continue
        if metric in KEA_SUBNET_GAUGES + KEA_SUBNET_COUNTERS:
            subnet_m.setdefault(sid, {})[metric.replace("-", "_")] = kea_latest(val)
    return global_m, subnet_m


# ---------- pdns-recursor ----------
def collect_recursor() -> dict[str, int]:
    try:
        proc = subprocess.run(
            [RECTL, "get-all"], capture_output=True, text=True, timeout=10, check=False
        )
    except Exception as e:
        sys.stderr.write(f"rec_control err: {e}\n")
        return {}
    result: dict[str, int] = {}
    for line in proc.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        name, val = parts[0].strip(), parts[1].strip()
        if val == "UNKNOWN" or not val:
            continue
        try:
            result[name.replace("-", "_")] = int(val)
        except ValueError:
            try:
                result[name.replace("-", "_")] = int(float(val))
            except ValueError:
                continue
    return result


# ---------- 状態保存 ----------
def load_state() -> dict:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except Exception:
            return {}
    return {}


def save_state(state: dict) -> None:
    tmp = STATE_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(state))
    tmp.replace(STATE_FILE)


def delta(curr: int, prev: int | None) -> int | None:
    """前回値が無ければ None、再起動 (curr<prev) なら 0 にクランプ。"""
    if prev is None:
        return None
    d = curr - prev
    return d if d >= 0 else 0


# ---------- Loki push ----------
def push_to_loki(streams: list[dict]) -> int:
    if not streams:
        return 0
    body = json.dumps({"streams": streams}).encode("utf-8")
    req = urllib.request.Request(
        LOKI_PUSH_URL,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return resp.status
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"loki HTTP {e.code}: {e.read().decode()[:300]}\n")
        return e.code
    except Exception as e:
        sys.stderr.write(f"loki err: {e}\n")
        return -1


# ---------- メイン ----------
def build_kea_global_record(curr: dict[str, int], prev: dict[str, int],
                             ts: str, interval_s: int) -> dict:
    rec: dict = {"ts": ts, "type": "kea_global", "interval_s": interval_s}
    for ck, cv in curr.items():
        rec[ck + "_total"] = cv
        d = delta(cv, prev.get(ck))
        if d is not None:
            rec[ck + "_delta"] = d
    return rec


def build_kea_subnet_record(sid: int, sname: str, curr: dict[str, int], prev: dict[str, int],
                             ts: str, interval_s: int) -> dict:
    active = curr.get("assigned_addresses", 0)
    total = curr.get("total_addresses", 0)
    rec: dict = {
        "ts": ts, "type": "kea_subnet", "interval_s": interval_s,
        "subnet_id": sid, "subnet_name": sname,
        "active_leases": active, "total_addresses": total,
        "declined": curr.get("declined_addresses", 0),
    }
    if total > 0:
        rec["usage_pct"] = round(100 * active / total, 2)
    for k in KEA_SUBNET_COUNTERS:
        ck = k.replace("-", "_")
        if ck in curr:
            rec[ck + "_total"] = curr[ck]
            d = delta(curr[ck], prev.get(ck))
            if d is not None:
                rec[ck + "_delta"] = d
    return rec


def build_recursor_record(curr: dict[str, int], prev: dict[str, int],
                           ts: str, interval_s: int) -> dict:
    rec: dict = {"ts": ts, "type": "recursor", "interval_s": interval_s}
    for k in REC_GAUGES:
        ck = k.replace("-", "_")
        if ck in curr:
            rec[ck] = curr[ck]
    for k in REC_COUNTERS:
        ck = k.replace("-", "_")
        if ck in curr:
            rec[ck + "_total"] = curr[ck]
            d = delta(curr[ck], prev.get(ck))
            if d is not None:
                rec[ck + "_delta"] = d
    ch = rec.get("cache_hits_delta")
    cm = rec.get("cache_misses_delta")
    if ch is not None and cm is not None and (ch + cm) > 0:
        rec["cache_hit_ratio"] = round(ch / (ch + cm), 4)
    pch = rec.get("packetcache_hits_delta")
    pcm = rec.get("packetcache_misses_delta")
    if pch is not None and pcm is not None and (pch + pcm) > 0:
        rec["packetcache_hit_ratio"] = round(pch / (pch + pcm), 4)
    return rec


def main() -> int:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    host = socket.gethostname()
    now = datetime.now(timezone.utc)
    ts = now.isoformat(timespec="seconds")
    ts_ns = str(int(now.timestamp() * 1_000_000_000))

    state = load_state()
    prev_global = state.get("kea_global", {})
    prev_subnet = state.get("kea_subnet", {})  # {sid_str: {metric: value}}
    prev_recursor = state.get("recursor", {})
    prev_ts_str = state.get("ts")
    interval_s = 0
    if prev_ts_str:
        try:
            prev_dt = datetime.fromisoformat(prev_ts_str.replace("Z", "+00:00"))
            interval_s = max(0, int((now - prev_dt).total_seconds()))
        except Exception:
            pass

    kea_global, kea_subnet = collect_kea()
    subnet_map = get_subnet_name_map()
    rec = collect_recursor()

    streams: list[dict] = []
    base_labels = {"source": "dhcpdns", "host": host, "interval": "1m"}

    if kea_global:
        rec_g = build_kea_global_record(kea_global, prev_global, ts, interval_s)
        streams.append({
            "stream": {**base_labels, "type": "kea_global"},
            "values": [[ts_ns, json.dumps(rec_g, ensure_ascii=False, separators=(",", ":"))]],
        })

    if kea_subnet:
        for sid, metrics in sorted(kea_subnet.items()):
            name = subnet_map.get(sid, str(sid))
            prev_m = prev_subnet.get(str(sid), {})
            rec_s = build_kea_subnet_record(sid, name, metrics, prev_m, ts, interval_s)
            streams.append({
                "stream": {**base_labels, "type": "kea_subnet", "subnet_name": name},
                "values": [[ts_ns, json.dumps(rec_s, ensure_ascii=False, separators=(",", ":"))]],
            })

    if rec:
        rec_r = build_recursor_record(rec, prev_recursor, ts, interval_s)
        streams.append({
            "stream": {**base_labels, "type": "recursor"},
            "values": [[ts_ns, json.dumps(rec_r, ensure_ascii=False, separators=(",", ":"))]],
        })

    push_to_loki(streams)

    new_state = {
        "ts": ts,
        "kea_global": kea_global,
        "kea_subnet": {str(sid): m for sid, m in kea_subnet.items()},
        "recursor": rec,
    }
    save_state(new_state)
    return 0


if __name__ == "__main__":
    sys.exit(main())
