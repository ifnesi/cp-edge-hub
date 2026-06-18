#!/usr/bin/env bash
# Creates all Kubernetes secrets required by the Edge cluster.
# Run against the Edge EKS context.
#
# Usage:  KUBECTL_CONTEXT=<edge-ctx> ./scripts/01-create-secrets-edge.sh
#
# Prerequisites: certs/generate-certs.sh must have been run first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
CERTS_DIR="${ROOT_DIR}/certs/edge"
CREDS_DIR="${ROOT_DIR}/edge/credentials"
NS="cp-edge"
CTX="${KUBECTL_CONTEXT:-}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

KCL="kubectl"
[[ -n "${CTX}" ]] && KCL="kubectl --context=${CTX}"

# Verify certs exist
[[ -f "${CERTS_DIR}/kafka-server.pem"     ]] || { echo "ERROR: Run certs/generate-certs.sh first"; exit 1; }
[[ -f "${CERTS_DIR}/kafka-server-key.pem" ]] || { echo "ERROR: Run certs/generate-certs.sh first"; exit 1; }
[[ -f "${CERTS_DIR}/cacerts.pem"          ]] || { echo "ERROR: Run certs/generate-certs.sh first"; exit 1; }
[[ -f "${CERTS_DIR}/rootCAkey.pem"        ]] || { echo "ERROR: Run certs/generate-certs.sh first"; exit 1; }

log "Creating secrets in namespace ${NS} (context: ${CTX:-current})..."

# TLS secret — fullchain + private key + CA cert
log "  tls-kafka"
$KCL create secret generic tls-kafka \
  --namespace="${NS}" \
  --from-file=fullchain.pem="${CERTS_DIR}/kafka-server.pem" \
  --from-file=cacerts.pem="${CERTS_DIR}/cacerts.pem" \
  --from-file=privkey.pem="${CERTS_DIR}/kafka-server-key.pem" \
  --dry-run=client -o yaml | $KCL apply -f -

# CA key-pair secret (used by CfK to issue component certificates)
log "  ca-pair-sslcerts"
$KCL create secret generic ca-pair-sslcerts \
  --namespace="${NS}" \
  --from-file=ca.crt="${CERTS_DIR}/cacerts.pem" \
  --from-file=ca.key="${CERTS_DIR}/rootCAkey.pem" \
  --dry-run=client -o yaml | $KCL apply -f -

# SASL/PLAIN credentials secret
log "  credential"
$KCL create secret generic credential \
  --namespace="${NS}" \
  --from-file=plain.txt="${CREDS_DIR}/plain.txt" \
  --from-file=plain-users.json="${CREDS_DIR}/plain-users.json" \
  --from-file=basic.txt="${CREDS_DIR}/basic.txt" \
  --dry-run=client -o yaml | $KCL apply -f -

log ""
log "=== Edge secrets created ==="
$KCL get secrets -n "${NS}"
