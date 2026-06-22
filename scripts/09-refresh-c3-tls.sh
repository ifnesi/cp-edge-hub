#!/usr/bin/env bash
# Generates a Control Center-specific TLS cert that includes the live C3 NLB
# hostnames as SANs — fixes the "Invalid SNI" browser error without touching
# the shared CA or the broker/SR/Connect certs.
#
# Safe to run on a live cluster: only the C3 pods are restarted.
#
# Usage:
#   EDGE_CTX=edge HUB_CTX=hub bash scripts/09-refresh-c3-tls.sh
#
# Prerequisites: cfssl, cfssljson, jq

set -euo pipefail

EDGE_CTX="${EDGE_CTX:-edge}"
HUB_CTX="${HUB_CTX:-hub}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${SCRIPT_DIR}/.."
CERTS_DIR="${SCRIPT_DIR}/../certs"
CA_CERT="${CERTS_DIR}/cacerts.pem"
CA_KEY="${CERTS_DIR}/rootCAkey.pem"
CA_CONFIG="${CERTS_DIR}/ca-config.json"

log() { echo "[$(date +%H:%M:%S)] $*"; }

for bin in cfssl cfssljson jq kubectl; do
  command -v "${bin}" &>/dev/null || { echo "ERROR: ${bin} not found in PATH"; exit 1; }
done

[[ -f "${CA_CERT}" ]] || { echo "ERROR: ${CA_CERT} not found — run certs/generate-certs.sh first"; exit 1; }
[[ -f "${CA_KEY}"  ]] || { echo "ERROR: ${CA_KEY} not found — run certs/generate-certs.sh first"; exit 1; }

# Fetch the C3 NLB hostname for a cluster (empty if not yet deployed)
get_c3_nlb() {
  local ctx="$1" ns="$2"
  kubectl --context="${ctx}" get svc controlcenter-bootstrap-lb -n "${ns}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
}

# Generate a C3 server cert and push it as tls-controlcenter in the namespace
generate_and_push() {
  local cluster="$1" ctx="$2" ns="$3" nlb_host="$4"
  local base_hosts=(
    "controlcenter.${cluster}.kafka.demo"
    "*.${cluster}.kafka.demo"
    "controlcenter.${ns}.svc.cluster.local"
    "controlcenter"
  )

  log "[${cluster}] Building C3 cert SANs..."
  local hosts_json
  hosts_json=$(printf '%s\n' "${base_hosts[@]}" | jq -R . | jq -s .)
  if [[ -n "${nlb_host}" ]]; then
    log "[${cluster}] Adding NLB SAN: ${nlb_host}"
    hosts_json=$(echo "${hosts_json}" | jq --arg h "${nlb_host}" '. += [$h]')
  else
    log "[${cluster}] No NLB found — skipping NLB SAN (C3 not deployed yet?)"
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "${tmpdir}"' RETURN

  # Build CSR JSON
  jq -n \
    --arg cn "controlcenter-${cluster}" \
    --argjson hosts "${hosts_json}" \
    '{CN: $cn, hosts: $hosts, key: {algo: "rsa", size: 2048},
      names: [{C:"US", L:"MountainView", O:"Confluent", OU:$cn, ST:"California"}]}' \
    > "${tmpdir}/csr.json"

  log "[${cluster}] Generating cert..."
  cfssl gencert \
    -ca="${CA_CERT}" \
    -ca-key="${CA_KEY}" \
    -config="${CA_CONFIG}" \
    -profile=server \
    "${tmpdir}/csr.json" | cfssljson -bare "${tmpdir}/controlcenter"

  log "[${cluster}] Pushing tls-controlcenter secret to ${ns}..."
  kubectl --context="${ctx}" create secret generic tls-controlcenter \
    --namespace="${ns}" \
    --from-file=fullchain.pem="${tmpdir}/controlcenter.pem" \
    --from-file=cacerts.pem="${CA_CERT}" \
    --from-file=privkey.pem="${tmpdir}/controlcenter-key.pem" \
    --dry-run=client -o yaml | kubectl --context="${ctx}" apply -f -

  log "[${cluster}] Applying ControlCenter CR (switches to tls-controlcenter)..."
  kubectl --context="${ctx}" apply -f "${REPO_DIR}/${cluster}/05-controlcenter.yaml"

  log "[${cluster}] Waiting for C3 rollout..."
  kubectl --context="${ctx}" rollout status statefulset/controlcenter -n "${ns}" --timeout=300s

  log "[${cluster}] Done."
}

log "Fetching C3 NLB hostnames..."
HUB_NLB=$(get_c3_nlb  "${HUB_CTX}"  "cp-hub")
EDGE_NLB=$(get_c3_nlb "${EDGE_CTX}" "cp-edge")
log "  Hub  NLB: ${HUB_NLB:-<not found>}"
log "  Edge NLB: ${EDGE_NLB:-<not found>}"

generate_and_push "hub"  "${HUB_CTX}"  "cp-hub"  "${HUB_NLB}"
generate_and_push "edge" "${EDGE_CTX}" "cp-edge" "${EDGE_NLB}"

log ""
log "=== C3 TLS refresh complete ==="
log "Re-run this script any time the NLB hostnames change."
