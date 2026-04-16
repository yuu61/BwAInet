#!/usr/bin/env python3
"""BwAI Forensic local-server Zabbix template セットアップ"""
import json
import urllib.request
import sys

ZBX_URL = "http://192.168.11.6/api_jsonrpc.php"
ZBX_TOKEN = "5330c91396ac1d0d3e18251b84fe6dd5d2f5650c4d649608c3e37bd440e92dd9"
TEMPLATE_NAME = "BwAI Forensic local-server"
HOST_NAME = "local-server"


def api(method, params, req_id=1):
    body = json.dumps({"jsonrpc": "2.0", "method": method, "params": params, "id": req_id}).encode()
    req = urllib.request.Request(
        ZBX_URL,
        data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {ZBX_TOKEN}"},
        method="POST",
    )
    with urllib.request.urlopen(req) as r:
        return json.loads(r.read())


def main():
    # 1. 既存テンプレート検索 (再実行対応)
    r = api("template.get", {"output": ["templateid"], "filter": {"host": [TEMPLATE_NAME]}})
    if r["result"]:
        tpl_id = r["result"][0]["templateid"]
        print(f"[existing] templateid={tpl_id}")
    else:
        r = api("template.create", {
            "host": TEMPLATE_NAME,
            "name": TEMPLATE_NAME,
            "description": "rsyslog+nfcapd+GCS uploader 監視 (CT 200)",
            "groups": [{"groupid": "12"}],
        })
        tpl_id = r["result"]["templateids"][0]
        print(f"[created] templateid={tpl_id}")

    # 2. items (type=7=Zabbix agent (active); 使うのは passive なので type=0)
    # Actually: type=0=Zabbix agent (passive), type=7=Zabbix agent (active)
    items = [
        ("systemd.unit.info[rsyslog.service,ActiveState]", "rsyslog active state", 1, "60s", "7d"),
        ("systemd.unit.info[nfcapd.service,ActiveState]", "nfcapd active state", 1, "60s", "7d"),
        ("systemd.unit.info[gcs-forensic-push.timer,ActiveState]", "gcs-forensic-push timer active state", 1, "60s", "7d"),
        ("vfs.file.size[/mnt/data/.gcs-state/errors.log]", "GCS upload errors.log size", 3, "60s", "30d"),
        ("vfs.file.time[/mnt/data/.gcs-state/last-push.json,modify]", "GCS last-push.json mtime", 3, "60s", "30d"),
    ]
    for key, name, vtype, delay, hist in items:
        # check existing
        r = api("item.get", {"output": ["itemid"], "hostids": tpl_id, "filter": {"key_": key}})
        if r["result"]:
            print(f"  [exists] {key}")
            continue
        r = api("item.create", {
            "name": name,
            "key_": key,
            "hostid": tpl_id,
            "type": 0,  # Zabbix agent passive
            "value_type": vtype,
            "delay": delay,
            "history": hist,
            "trends": "0" if vtype == 1 else "365d",
        })
        print(f"  [new] {key} => {r.get('result', r.get('error'))}")

    # 3. triggers
    triggers = [
        (f'last(/{TEMPLATE_NAME}/systemd.unit.info[rsyslog.service,ActiveState])<>"active"',
         "rsyslog not active on {HOST.NAME}", 4),
        (f'last(/{TEMPLATE_NAME}/systemd.unit.info[nfcapd.service,ActiveState])<>"active"',
         "nfcapd not active on {HOST.NAME}", 4),
        (f'last(/{TEMPLATE_NAME}/systemd.unit.info[gcs-forensic-push.timer,ActiveState])<>"active"',
         "gcs-forensic-push timer not active on {HOST.NAME}", 2),
        (f'last(/{TEMPLATE_NAME}/vfs.file.size[/mnt/data/.gcs-state/errors.log])>0',
         "GCS upload errors detected on {HOST.NAME}", 2),
        (f'(now()-last(/{TEMPLATE_NAME}/vfs.file.time[/mnt/data/.gcs-state/last-push.json,modify]))>600',
         "GCS push timer stalled (>10min) on {HOST.NAME}", 2),
    ]
    for expr, desc, prio in triggers:
        r = api("trigger.get", {"output": ["triggerid"], "filter": {"description": [desc]}})
        if r["result"]:
            print(f"  [exists] {desc}")
            continue
        r = api("trigger.create", [{"expression": expr, "description": desc, "priority": prio}])
        print(f"  [new] {desc} => {r.get('result', r.get('error'))}")

    # 4. link template to host
    r = api("host.get", {"output": ["hostid"], "filter": {"host": [HOST_NAME]}, "selectParentTemplates": ["templateid"]})
    host = r["result"][0]
    host_id = host["hostid"]
    linked = [t["templateid"] for t in host.get("parentTemplates", [])]
    if tpl_id in linked:
        print(f"  [already linked] host {host_id}")
    else:
        linked.append(tpl_id)
        r = api("host.update", {
            "hostid": host_id,
            "templates": [{"templateid": t} for t in linked],
        })
        print(f"  [linked] host {host_id} => {r.get('result', r.get('error'))}")

    # 5. host macros
    macros = [
        ('{$VFS.FS.PUSED.MAX.WARN:"/mnt/data"}', "50"),
        ('{$VFS.FS.PUSED.MAX.CRIT:"/mnt/data"}', "80"),
    ]
    for macro, value in macros:
        r = api("usermacro.get", {"output": ["hostmacroid"], "hostids": host_id, "filter": {"macro": macro}})
        if r["result"]:
            r2 = api("usermacro.update", {"hostmacroid": r["result"][0]["hostmacroid"], "value": value})
            print(f"  [updated] {macro}={value} => {r2.get('result', r2.get('error'))}")
        else:
            r2 = api("usermacro.create", {"hostid": host_id, "macro": macro, "value": value})
            print(f"  [new] {macro}={value} => {r2.get('result', r2.get('error'))}")

    print("=== DONE ===")


if __name__ == "__main__":
    main()
