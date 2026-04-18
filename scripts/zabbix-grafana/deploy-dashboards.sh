#!/usr/bin/env bash
# BwAI Grafana dashboards をリポジトリから zabbix-grafana CT に配置する。
#
# Grafana は /etc/grafana/provisioning/dashboards/*.yaml の設定で
# /var/lib/grafana/dashboards/bwai/ を 30 秒ごとに再ロードしている。
# ファイル内容が provisioner 優先のため、UI/API 経由の変更は上書きされる。
# このスクリプトは JSON を CT に配置し、provisioner に強制再ロードさせる。
#
# 使い方:
#   scripts/zabbix-grafana/deploy-dashboards.sh
#
# 環境変数:
#   SSH_HOST (default: zabbix-grafana)   — SSH config のエイリアス
#   REMOTE_DIR (default: /var/lib/grafana/dashboards/bwai)

set -euo pipefail

SSH_HOST=${SSH_HOST:-zabbix-grafana}
REMOTE_DIR=${REMOTE_DIR:-/var/lib/grafana/dashboards/bwai}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
LOCAL_DIR="${REPO_ROOT}/configs/grafana/dashboards/bwai"

if [[ ! -d "${LOCAL_DIR}" ]]; then
  echo "ERROR: ${LOCAL_DIR} が見つかりません" >&2
  exit 1
fi

echo ">>> ${LOCAL_DIR} -> ${SSH_HOST}:${REMOTE_DIR}"

ssh "${SSH_HOST}" "mkdir -p ${REMOTE_DIR}"
scp "${LOCAL_DIR}"/*.json "${SSH_HOST}:${REMOTE_DIR}/"
ssh "${SSH_HOST}" "chown grafana:grafana ${REMOTE_DIR}/*.json"

echo ">>> triggering provisioner reload"
ssh "${SSH_HOST}" "curl -sf -X POST -u admin:admin http://localhost:3000/api/admin/provisioning/dashboards/reload" \
  && echo "reloaded" \
  || echo "reload API call failed — provisioner の自動 reload (30s) を待ってください"
