#!/usr/bin/env bash
# Installs kube-prometheus-stack for a SINGLE pane of glass across both clusters.
#
#   Hub  = central: Prometheus (remote-write receiver) + the only Grafana.
#   Edge = Prometheus only (Grafana disabled); it remote-writes its metrics to
#          the Hub Prometheus over an internal NLB (same VPC).
#
# Result: the Hub Grafana shows BOTH clusters — series carry a `cluster`
# (edge/hub) external label and keep their `namespace` (cp-edge/cp-hub) label,
# which the dashboards' Namespace variable uses to switch between clusters.
#
# Usage:
#   EDGE_CTX=edge HUB_CTX=hub ./monitoring/01-install-prometheus-stack.sh

set -euo pipefail

EDGE_CTX="${EDGE_CTX:-edge}"
HUB_CTX="${HUB_CTX:-hub}"
NS="monitoring"
STACK_VERSION="65.2.0"   # kube-prometheus-stack chart version

log() { echo "[$(date +%H:%M:%S)] $*"; }

# Shared by both installs: discover our PodMonitors in any CP namespace
# (nil-selector matches all PodMonitors); no Alertmanager for this PoC.
COMMON_SETS=(
  --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
  --set prometheus.prometheusSpec.podMonitorNamespaceSelector.matchExpressions[0].key=kubernetes.io/metadata.name
  --set "prometheus.prometheusSpec.podMonitorNamespaceSelector.matchExpressions[0].operator=In"
  --set "prometheus.prometheusSpec.podMonitorNamespaceSelector.matchExpressions[0].values={cp-edge,cp-hub,monitoring}"
  --set alertmanager.enabled=false
)

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo update >/dev/null

# ---------------------------------------------------------------------------
# 1. Hub — central Prometheus (remote-write receiver) + Grafana (the single UI)
# ---------------------------------------------------------------------------
log "Installing kube-prometheus-stack on Hub (central Prometheus + Grafana)..."
kubectl --context="${HUB_CTX}" create namespace "${NS}" \
  --dry-run=client -o yaml | kubectl --context="${HUB_CTX}" apply -f -

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --kube-context="${HUB_CTX}" --namespace "${NS}" --version "${STACK_VERSION}" \
  "${COMMON_SETS[@]}" \
  --set prometheus.prometheusSpec.enableRemoteWriteReceiver=true \
  --set prometheus.prometheusSpec.externalLabels.cluster=hub \
  --set grafana.adminPassword="prom-operator" \
  --set grafana.service.type=LoadBalancer \
  --set "grafana.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type=nlb" \
  --set "grafana.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme=internet-facing" \
  --wait --timeout 6m

# Internal NLB so Edge's Prometheus can reach the Hub remote-write receiver.
log "Exposing Hub Prometheus on an internal NLB (remote-write target)..."
kubectl --context="${HUB_CTX}" apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: prometheus-remote-write
  namespace: monitoring
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internal"
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: prometheus
    prometheus: kube-prometheus-stack-prometheus
  ports:
    - name: web
      port: 9090
      targetPort: 9090
EOF

log "Waiting for the internal NLB hostname..."
HUB_PROM=""
for _ in $(seq 1 30); do
  HUB_PROM=$(kubectl --context="${HUB_CTX}" get svc prometheus-remote-write -n "${NS}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "${HUB_PROM}" ]] && break
  sleep 15
done
[[ -n "${HUB_PROM}" ]] || { echo "ERROR: internal NLB never got a hostname"; exit 1; }
log "Hub remote-write endpoint: http://${HUB_PROM}:9090/api/v1/write"

# ---------------------------------------------------------------------------
# 2. Edge — Prometheus only (no Grafana); remote-writes to Hub
# ---------------------------------------------------------------------------
log "Installing kube-prometheus-stack on Edge (Prometheus only, remote-write to Hub)..."
kubectl --context="${EDGE_CTX}" create namespace "${NS}" \
  --dry-run=client -o yaml | kubectl --context="${EDGE_CTX}" apply -f -

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --kube-context="${EDGE_CTX}" --namespace "${NS}" --version "${STACK_VERSION}" \
  "${COMMON_SETS[@]}" \
  --set grafana.enabled=false \
  --set prometheus.prometheusSpec.externalLabels.cluster=edge \
  --set "prometheus.prometheusSpec.remoteWrite[0].url=http://${HUB_PROM}:9090/api/v1/write" \
  --wait --timeout 6m

log ""
log "=== Done. Single Grafana = Hub. ==="
log "Grafana URL:"
log "  kubectl --context=${HUB_CTX} get svc -n ${NS} kube-prometheus-stack-grafana \\"
log "    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'"
log "Credentials: admin / prom-operator"
log ""
log "Next: apply monitoring/02-podmonitors.yaml on BOTH clusters, then import"
log "dashboards into the Hub Grafana with monitoring/04-import-dashboards.sh."
