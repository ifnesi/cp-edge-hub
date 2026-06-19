#!/usr/bin/env bash
# Sets ACLs on the Edge cluster for:
#   - cluster-link user (needed for Cluster Linking)
#   - client user (generic application use)
#
# Usage:
#   KUBECTL_CONTEXT=<edge-ctx> \
#   EDGE_BOOTSTRAP=edge.kafka.demo:9092 \
#   ./scripts/03-edge-acls.sh
#
# Requires the sslcli.properties client config to be present, or set
# BOOTSTRAP and SSL_CONFIG env vars.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."

EDGE_BOOTSTRAP="${EDGE_BOOTSTRAP:-edge.kafka.demo:9092}"
SSL_CONFIG="${SSL_CONFIG:-${ROOT_DIR}/scripts/edge-sslcli.properties}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

acl() {
  kafka-acls \
    --bootstrap-server "${EDGE_BOOTSTRAP}" \
    --command-config "${SSL_CONFIG}" \
    "$@"
}

# -------------------------------------------------------------------------
# cluster-link user — needs DescribeCluster + Read on all mirrored topics
# -------------------------------------------------------------------------
log "Granting cluster-link user ACLs on Edge..."

acl --add \
  --allow-principal "User:cluster-link" \
  --operation Describe \
  --cluster

acl --add \
  --allow-principal "User:cluster-link" \
  --operation Describe \
  --operation Read \
  --topic '*' \
  --resource-pattern-type literal

acl --add \
  --allow-principal "User:cluster-link" \
  --operation Describe \
  --operation Read \
  --group '*' \
  --resource-pattern-type literal

# -------------------------------------------------------------------------
# client user — all operations on all topics/groups (demo only)
# -------------------------------------------------------------------------
log "Granting client user ACLs on Edge..."

acl --add \
  --allow-principal "User:client" \
  --operation All \
  --topic '*' \
  --resource-pattern-type literal \
  --group '*'

log ""
log "=== ACLs on Edge ==="
acl --list
