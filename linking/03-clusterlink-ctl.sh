#!/usr/bin/env bash
# =============================================================================
# Cluster Link control — pause / resume / status
#
# Simulates a network failure between Edge and Hub by pausing the entire
# Cluster Link. All 21 mirror topics stop replicating; consumer lag accumulates
# on Edge while local producers keep writing. Resuming restarts replication
# from the last committed offset — no data loss.
#
# Uses the Kafka REST Proxy v3 Admin API on Hub (embedded in the broker pod).
#
# Usage:
#   bash linking/03-clusterlink-ctl.sh pause    # drop the link (network failure)
#   bash linking/03-clusterlink-ctl.sh resume   # restore the link
#   bash linking/03-clusterlink-ctl.sh status   # show link + mirror topic lag
#
# Prerequisites:
#   - Hub REST proxy NLB reachable (kafka.hub.kafka.demo:8090)
#   - curl, jq installed
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment variables if needed
# ---------------------------------------------------------------------------
HUB_REST_URL="${HUB_REST_URL:-https://kafka.hub.kafka.demo:8090}"
HUB_USER="${HUB_USER:-admin}"
HUB_PASS="${HUB_PASS:-admin-secret}"
LINK_NAME="${LINK_NAME:-edge-to-hub}"
CA_CERT="${CA_CERT:-./certs/cacerts.pem}"

ACTION="${1:-status}"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# curl wrapper — shared CA, basic auth, JSON
krest() {
  local url="$1"; shift
  curl -fsSL --cacert "${CA_CERT}" \
    -u "${HUB_USER}:${HUB_PASS}" \
    -H "Content-Type: application/json" \
    "$url" "$@"
}

# ---------------------------------------------------------------------------
# Resolve the Hub cluster ID (required by the v3 API path)
# ---------------------------------------------------------------------------
get_cluster_id() {
  krest "${HUB_REST_URL}/v3/clusters" | jq -r '.data[0].cluster_id'
}

# ---------------------------------------------------------------------------
# Print link status + per-topic consumer lag
# ---------------------------------------------------------------------------
print_status() {
  local cluster_id="$1"
  local base="${HUB_REST_URL}/v3/clusters/${cluster_id}/links/${LINK_NAME}"

  echo ""
  log "=== Cluster Link: ${LINK_NAME} ==="
  krest "${base}" | jq '{
    link_name:    .link_name,
    link_state:   .link_state,
    source_cluster: .source_cluster_id
  }'

  echo ""
  log "=== Mirror topic lag ==="
  krest "${base}/mirrors" | jq -r '
    ["TOPIC", "STATE", "LAG"],
    ["-----", "-----", "---"],
    (.data[] | [
      .mirror_topic_name,
      .mirror_status,
      (.mirror_topic_partitions // [] | map(.mirror_lag // 0) | add // 0 | tostring)
    ])
    | @tsv' | column -t
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
log "Resolving Hub cluster ID..."
CLUSTER_ID=$(get_cluster_id)
log "Cluster ID: ${CLUSTER_ID}"

BASE_URL="${HUB_REST_URL}/v3/clusters/${CLUSTER_ID}/links/${LINK_NAME}"

case "${ACTION}" in
  pause)
    log "Pausing Cluster Link '${LINK_NAME}' (simulating network failure)..."
    krest "${BASE_URL}/mirrors" \
      -X POST \
      -d '{"action": "pause"}' | jq '{action: "pause", mirrors_affected: (.data | length)}'
    log "Link paused. Producers on Edge continue writing; Hub mirror topics stop replicating."
    print_status "${CLUSTER_ID}"
    ;;

  resume)
    log "Resuming Cluster Link '${LINK_NAME}'..."
    krest "${BASE_URL}/mirrors" \
      -X POST \
      -d '{"action": "resume"}' | jq '{action: "resume", mirrors_affected: (.data | length)}'
    log "Link resumed. Replication restarts from last committed offset — watch lag drain to 0."
    print_status "${CLUSTER_ID}"
    ;;

  status)
    print_status "${CLUSTER_ID}"
    ;;

  *)
    echo "Usage: $0 {pause|resume|status}"
    exit 1
    ;;
esac
