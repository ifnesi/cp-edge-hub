#!/usr/bin/env bash
# Installs kube-prometheus-stack (Prometheus + Grafana + Alertmanager) on
# both Edge and Hub EKS clusters.
#
# Usage:
#   EDGE_CTX=edge HUB_CTX=hub ./monitoring/01-install-prometheus-stack.sh
#
# After install:
#   - Prometheus scrapes JMX metrics from Kafka/KRaft/SR via PodMonitors
#   - Grafana is accessible at http://grafana.edge.kafka.demo (after /etc/hosts update)
#   - Default Grafana credentials: admin / prom-operator

set -euo pipefail

EDGE_CTX="${EDGE_CTX:-edge}"
HUB_CTX="${HUB_CTX:-hub}"
MONITORING_NS="monitoring"
STACK_VERSION="65.2.0"   # kube-prometheus-stack chart version

log() { echo "[$(date +%H:%M:%S)] $*"; }

install_stack() {
  local ctx="$1"
  local cluster_label="$2"

  log "Installing kube-prometheus-stack on ${ctx}..."

  kubectl --context="${ctx}" create namespace "${MONITORING_NS}" \
    --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -

  helm upgrade --install kube-prometheus-stack \
    prometheus-community/kube-prometheus-stack \
    --kube-context="${ctx}" \
    --namespace "${MONITORING_NS}" \
    --version "${STACK_VERSION}" \
    --set prometheus.prometheusSpec.podMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
    --set prometheus.prometheusSpec.podMonitorNamespaceSelector.matchExpressions[0].key=kubernetes.io/metadata.name \
    --set "prometheus.prometheusSpec.podMonitorNamespaceSelector.matchExpressions[0].operator=In" \
    --set "prometheus.prometheusSpec.podMonitorNamespaceSelector.matchExpressions[0].values={cp-edge,cp-hub,monitoring}" \
    --set grafana.adminPassword="prom-operator" \
    --set grafana.service.type=LoadBalancer \
    --set "grafana.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-type=nlb" \
    --set "grafana.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme=internet-facing" \
    --set alertmanager.enabled=false \
    --wait --timeout 5m

  log "kube-prometheus-stack installed on ${ctx}"
}

# Add chart repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

install_stack "${EDGE_CTX}" "edge"
install_stack "${HUB_CTX}"  "hub"

log ""
log "=== Prometheus stack installed on both clusters ==="
log ""
log "Get Grafana LB address on Edge:"
log "  kubectl --context=${EDGE_CTX} get svc -n ${MONITORING_NS} kube-prometheus-stack-grafana"
log ""
log "Default credentials: admin / prom-operator"
log ""
log "Next: apply monitoring/02-podmonitors.yaml on both clusters"
