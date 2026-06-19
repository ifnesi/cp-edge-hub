#!/usr/bin/env bash
# Imports the CfK-adapted Confluent Grafana dashboards (vendored in
# monitoring/grafana-dashboards/) into the single Grafana (Hub).
#
# These dashboards key on the `namespace`/`pod` labels and the FLATTENED metric
# names (e.g. kafka_server_kafkaserver_brokerstate) that CfK emits once the
# JMX-exporter rules in edge/02-kafka.yaml + edge/01-kraftcontroller.yaml (and
# the hub equivalents) are applied. They are the CfK-converted versions of the
# confluentinc/jmx-monitoring-stacks dashboards (via that repo's
# cfk/update-dashboards.sh), vendored here so the demo is self-contained.
#
# The Hub Grafana's Prometheus holds BOTH clusters (Edge remote-writes to it),
# so one import covers everything — switch clusters with the Namespace variable.
#
# Usage:
#   CTX=hub bash monitoring/04-import-dashboards.sh

set -euo pipefail

CTX="${CTX:-${HUB_CTX:-hub}}"
GRAFANA_CREDS="${GRAFANA_CREDS:-admin:prom-operator}"
DS_UID="${DS_UID:-prometheus}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASH_DIR="${SCRIPT_DIR}/grafana-dashboards"

log() { echo "[$(date +%H:%M:%S)] $*"; }

GRAFANA_URL="http://$(kubectl --context="${CTX}" get svc -n monitoring \
  kube-prometheus-stack-grafana -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
log "Grafana: ${GRAFANA_URL} (context: ${CTX})"

for f in "${DASH_DIR}"/*.json; do
  name=$(basename "$f")
  # Bind the dashboard's Prometheus datasource input to the provisioned datasource.
  jq --arg ds "${DS_UID}" \
    '{dashboard: ., overwrite: true, folderId: 0,
      inputs: [(.__inputs // [])[] | select(.type=="datasource")
               | {name: .name, type: "datasource", pluginId: .pluginId, value: $ds}]}' "$f" \
  | curl -s -X POST -H "Content-Type: application/json" -u "${GRAFANA_CREDS}" \
      --data @- "${GRAFANA_URL}/api/dashboards/import" \
  | jq -r --arg n "$name" '"  \($n): imported=\(.imported // .message)"'
done

log "Done. In Grafana, open a dashboard and set the Namespace variable (cp-edge / cp-hub)."
