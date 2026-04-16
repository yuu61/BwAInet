#!/bin/bash
# Zabbix テンプレート "BwAI Forensic local-server" を作成し、local-server ホストにリンク
set -euo pipefail

ZBX_URL=http://192.168.11.6/api_jsonrpc.php
ZBX_TOKEN=5330c91396ac1d0d3e18251b84fe6dd5d2f5650c4d649608c3e37bd440e92dd9
HOST=local-server

zabbix() {
  curl -s -X POST "$ZBX_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $ZBX_TOKEN" \
    --data-binary "$1"
}

# 1. テンプレート作成
echo "=== 1. template.create ==="
TPL_RESP=$(zabbix '{"jsonrpc":"2.0","method":"template.create","params":{"host":"BwAI Forensic local-server","name":"BwAI Forensic local-server","description":"rsyslog+nfcapd+GCS uploader 監視 (CT 200)","groups":[{"groupid":"12"}]},"id":1}')
echo "$TPL_RESP"
TPL_ID=$(echo "$TPL_RESP" | python -c "import sys,json;print(json.load(sys.stdin)['result']['templateids'][0])")
echo "templateid=$TPL_ID"

# 2. item 作成 (systemd 3 + ファイル 2)
echo "=== 2. items ==="
declare -A ITEMS=(
  ["systemd.unit.info[rsyslog.service,ActiveState]"]="rsyslog active state|CHAR|60s|7d"
  ["systemd.unit.info[nfcapd.service,ActiveState]"]="nfcapd active state|CHAR|60s|7d"
  ["systemd.unit.info[gcs-forensic-push.timer,ActiveState]"]="gcs-forensic-push timer active state|CHAR|60s|7d"
  ["vfs.file.size[/mnt/data/.gcs-state/errors.log]"]="GCS upload errors.log size|UINT64|60s|30d"
  ["vfs.file.time[/mnt/data/.gcs-state/last-push.json,modify]"]="GCS last-push.json mtime|UINT64|60s|30d"
)

# value_type: 0=numeric float, 1=character, 3=unsigned integer
for key in "${!ITEMS[@]}"; do
  IFS='|' read -r name vtype delay hist <<< "${ITEMS[$key]}"
  case "$vtype" in
    CHAR)   vt=1 ;;
    UINT64) vt=3 ;;
    *)      vt=0 ;;
  esac
  PARAMS=$(python -c "
import json
print(json.dumps({
  'jsonrpc':'2.0','method':'item.create','params':{
    'name':'$name','key_':'$key','hostid':'$TPL_ID',
    'type':7,'value_type':$vt,'delay':'$delay','history':'$hist','trends':'0'
  },'id':2
}))")
  R=$(zabbix "$PARAMS")
  echo "  $key => $(echo $R | python -c 'import sys,json;d=json.load(sys.stdin);print(d.get(\"result\",d.get(\"error\")))')"
done

# 3. triggers
echo "=== 3. triggers ==="
# expression, description, priority (0=notclass 2=warning 4=high)
declare -a TRIGS=(
  'last(/BwAI Forensic local-server/systemd.unit.info[rsyslog.service,ActiveState])<>"active"|rsyslog not active on {HOST.NAME}|4'
  'last(/BwAI Forensic local-server/systemd.unit.info[nfcapd.service,ActiveState])<>"active"|nfcapd not active on {HOST.NAME}|4'
  'last(/BwAI Forensic local-server/systemd.unit.info[gcs-forensic-push.timer,ActiveState])<>"active"|gcs-forensic-push timer not active on {HOST.NAME}|2'
  'last(/BwAI Forensic local-server/vfs.file.size[/mnt/data/.gcs-state/errors.log])>0|GCS upload errors detected on {HOST.NAME}|2'
  '(now()-last(/BwAI Forensic local-server/vfs.file.time[/mnt/data/.gcs-state/last-push.json,modify]))>600|GCS push timer stalled (>10min) on {HOST.NAME}|2'
)
for t in "${TRIGS[@]}"; do
  IFS='|' read -r expr desc prio <<< "$t"
  PARAMS=$(python -c "
import json
print(json.dumps({
  'jsonrpc':'2.0','method':'trigger.create','params':[{
    'expression':'''$expr''','description':'$desc','priority':$prio
  }],'id':3
}))")
  R=$(zabbix "$PARAMS")
  echo "  [$desc] => $(echo $R | python -c 'import sys,json;d=json.load(sys.stdin);print(d.get(\"result\",d.get(\"error\")))')"
done

# 4. host にテンプレートをリンク
echo "=== 4. host link ==="
HOSTID=$(zabbix '{"jsonrpc":"2.0","method":"host.get","params":{"output":["hostid"],"filter":{"host":["'"$HOST"'"]}},"id":4}' \
  | python -c "import sys,json;print(json.load(sys.stdin)['result'][0]['hostid'])")
echo "hostid=$HOSTID"
R=$(zabbix "{\"jsonrpc\":\"2.0\",\"method\":\"host.update\",\"params\":{\"hostid\":\"$HOSTID\",\"templates\":[{\"templateid\":\"$TPL_ID\"}]},\"id\":5}")
echo "link result: $R"

# 5. host macros for /mnt/data thresholds
echo "=== 5. host macros (/mnt/data thresholds) ==="
R=$(zabbix "{\"jsonrpc\":\"2.0\",\"method\":\"usermacro.create\",\"params\":[
  {\"hostid\":\"$HOSTID\",\"macro\":\"{\$VFS.FS.PUSED.MAX.WARN:\\\"/mnt/data\\\"}\",\"value\":\"50\"},
  {\"hostid\":\"$HOSTID\",\"macro\":\"{\$VFS.FS.PUSED.MAX.CRIT:\\\"/mnt/data\\\"}\",\"value\":\"80\"}
],\"id\":6}")
echo "macros: $R"

echo
echo "=== DONE ==="
