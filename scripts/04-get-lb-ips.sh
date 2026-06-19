#!/usr/bin/env bash
# Retrieves LoadBalancer external IPs/hostnames for both clusters
# and prints /etc/hosts entries for your Mac.
#
# Usage:
#   EDGE_CTX=<edge-ctx> HUB_CTX=<hub-ctx> ./scripts/04-get-lb-ips.sh

set -euo pipefail

EDGE_CTX="${EDGE_CTX:-}"
HUB_CTX="${HUB_CTX:-}"
EDGE_NS="cp-edge"
HUB_NS="cp-hub"

log() { echo "[$(date +%H:%M:%S)] $*"; }

get_lb() {
  local ctx="$1" ns="$2" svc="$3"
  local kctl="kubectl"
  [[ -n "${ctx}" ]] && kctl="kubectl --context=${ctx}"
  local addr
  addr=$($kctl get svc "${svc}" -n "${ns}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  [[ -z "${addr}" ]] && addr=$($kctl get svc "${svc}" -n "${ns}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
  if [[ -z "${addr}" ]]; then
    echo "<pending>"
    return
  fi
  # /etc/hosts needs an IP, not a hostname. AWS NLBs return a hostname — resolve it.
  if [[ "${addr}" =~ ^[0-9.]+$ ]]; then
    echo "${addr}"
  else
    local ip
    ip=$(dig +short "${addr}" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
    echo "${ip:-<unresolved:${addr}>}"
  fi
}

log "Fetching Edge LB addresses (context: ${EDGE_CTX:-current})..."
EDGE_B0=$(get_lb "${EDGE_CTX}" "${EDGE_NS}" "kafka-0-lb")
EDGE_B1=$(get_lb "${EDGE_CTX}" "${EDGE_NS}" "kafka-1-lb")
EDGE_B2=$(get_lb "${EDGE_CTX}" "${EDGE_NS}" "kafka-2-lb")
EDGE_BS=$(get_lb "${EDGE_CTX}" "${EDGE_NS}" "kafka-bootstrap-lb")
EDGE_SR=$(get_lb "${EDGE_CTX}" "${EDGE_NS}" "schemaregistry-bootstrap-lb")
EDGE_REST=$(get_lb "${EDGE_CTX}" "${EDGE_NS}" "kafka-kafka-rest-bootstrap-lb")

log "Fetching Hub LB addresses (context: ${HUB_CTX:-current})..."
HUB_B0=$(get_lb "${HUB_CTX}" "${HUB_NS}" "kafka-0-lb")
HUB_B1=$(get_lb "${HUB_CTX}" "${HUB_NS}" "kafka-1-lb")
HUB_B2=$(get_lb "${HUB_CTX}" "${HUB_NS}" "kafka-2-lb")
HUB_BS=$(get_lb "${HUB_CTX}" "${HUB_NS}" "kafka-bootstrap-lb")
HUB_SR=$(get_lb "${HUB_CTX}" "${HUB_NS}" "schemaregistry-bootstrap-lb")
HUB_REST=$(get_lb "${HUB_CTX}" "${HUB_NS}" "kafka-kafka-rest-bootstrap-lb")

cat <<EOF

# ============================================================
# Add to /etc/hosts on your Mac (sudo vi /etc/hosts)
# ============================================================

# --- Edge cluster ---
${EDGE_B0}   b0.edge.kafka.demo
${EDGE_B1}   b1.edge.kafka.demo
${EDGE_B2}   b2.edge.kafka.demo
${EDGE_BS}   edge.kafka.demo
${EDGE_SR}   schemaregistry.edge.kafka.demo
${EDGE_REST} kafka.edge.kafka.demo

# --- Hub cluster ---
${HUB_B0}   b0.hub.kafka.demo
${HUB_B1}   b1.hub.kafka.demo
${HUB_B2}   b2.hub.kafka.demo
${HUB_BS}   hub.kafka.demo
${HUB_SR}   schemaregistry.hub.kafka.demo
${HUB_REST} kafka.hub.kafka.demo

EOF
