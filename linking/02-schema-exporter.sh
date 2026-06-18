#!/usr/bin/env bash
# =============================================================================
# Schema Linking — configure a Schema Exporter on the Edge Schema Registry
# to continuously push schemas to the Hub Schema Registry.
#
# Schema Exporters are configured via Schema Registry REST API (no CfK CRD).
# This script automates that setup.
#
# Prerequisites:
#   - Both Schema Registries deployed and healthy
#   - Edge SR external LB FQDN resolved on your Mac (schemaregistry.edge.kafka.demo)
#   - scripts/06-cluster-dns.sh has been run — the Edge SR *pod* must be able to
#     resolve schemaregistry.hub.kafka.demo to push schemas to the Hub
#   - curl, jq installed on your Mac
#
# Usage:
#   ./02-schema-exporter.sh                    # create exporter for all subjects
#   SUBJECTS="subject1,subject2" ./02-schema-exporter.sh  # specific subjects only
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment variables if needed
# ---------------------------------------------------------------------------
EDGE_SR_URL="${EDGE_SR_URL:-https://schemaregistry.edge.kafka.demo:8081}"
HUB_SR_URL="${HUB_SR_URL:-https://schemaregistry.hub.kafka.demo:8081}"
EDGE_SR_USER="${EDGE_SR_USER:-admin}"
EDGE_SR_PASS="${EDGE_SR_PASS:-admin-secret}"
HUB_SR_USER="${HUB_SR_USER:-admin}"
HUB_SR_PASS="${HUB_SR_PASS:-admin-secret}"
EXPORTER_NAME="${EXPORTER_NAME:-edge-to-hub-exporter}"
CA_CERT="${CA_CERT:-./certs/cacerts.pem}"

# Comma-separated list of subject patterns to export.
# Supports wildcards: "my-topic-*"
# Leave empty to export ALL subjects (".*" wildcard).
SUBJECTS="${SUBJECTS:-}"

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# curl wrapper — mutual TLS off, custom CA, basic auth
sr_curl() {
  local url="$1"; shift
  curl -fsSL --cacert "${CA_CERT}" -u "${EDGE_SR_USER}:${EDGE_SR_PASS}" "$url" "$@"
}

# ---------------------------------------------------------------------------
# 1. Health-check both SRs
# ---------------------------------------------------------------------------
log "Checking Edge SR at ${EDGE_SR_URL}..."
sr_curl "${EDGE_SR_URL}/subjects" -o /dev/null || die "Edge SR not reachable"

log "Checking Hub SR at ${HUB_SR_URL}..."
curl -fsSL --cacert "${CA_CERT}" -u "${HUB_SR_USER}:${HUB_SR_PASS}" \
  "${HUB_SR_URL}/subjects" -o /dev/null || die "Hub SR not reachable"

# ---------------------------------------------------------------------------
# 2. Build the subjects array (a single JSON key — no duplicates)
# ---------------------------------------------------------------------------
if [[ -n "${SUBJECTS}" ]]; then
  # Comma-separated list -> JSON array, trimming whitespace around each entry.
  SUBJECTS_JSON="[$(echo "${SUBJECTS}" | tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/.*/"&"/' | paste -sd, -)]"
else
  SUBJECTS_JSON='["*"]'
fi

# Inline the shared CA as a single-line PEM (newlines escaped) so the exporter
# trusts the Hub SR server cert. Both clusters share one CA, so the Hub cert
# (SAN *.hub.kafka.demo) verifies cleanly against it.
CA_PEM=$(awk '{printf "%s\\n", $0}' "${CA_CERT}")

# ---------------------------------------------------------------------------
# 3. Create (or update) the exporter
# ---------------------------------------------------------------------------
log "Creating Schema Exporter '${EXPORTER_NAME}' on Edge SR..."

PAYLOAD=$(cat <<EOF
{
  "name": "${EXPORTER_NAME}",
  "contextType": "CUSTOM",
  "context": "hub",
  "subjects": ${SUBJECTS_JSON},
  "subjectRenameFormat": "\${subject}",
  "config": {
    "schema.registry.url": "${HUB_SR_URL}",
    "basic.auth.credentials.source": "USER_INFO",
    "basic.auth.user.info": "${HUB_SR_USER}:${HUB_SR_PASS}",
    "schema.registry.ssl.truststore.type": "PEM",
    "schema.registry.ssl.truststore.certificates": "${CA_PEM}"
  }
}
EOF
)

# Check if exporter already exists
HTTP_STATUS=$(curl -o /dev/null -s -w "%{http_code}" \
  --cacert "${CA_CERT}" \
  -u "${EDGE_SR_USER}:${EDGE_SR_PASS}" \
  "${EDGE_SR_URL}/exporters/${EXPORTER_NAME}")

if [[ "${HTTP_STATUS}" == "200" ]]; then
  log "Exporter exists — updating config..."
  sr_curl "${EDGE_SR_URL}/exporters/${EXPORTER_NAME}/config" \
    -X PUT \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" | jq .
else
  log "Creating new exporter..."
  sr_curl "${EDGE_SR_URL}/exporters" \
    -X POST \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" | jq .
fi

# ---------------------------------------------------------------------------
# 4. Start the exporter
# ---------------------------------------------------------------------------
log "Starting exporter '${EXPORTER_NAME}'..."
sr_curl "${EDGE_SR_URL}/exporters/${EXPORTER_NAME}/resume" -X PUT | jq .

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
log "Verifier — exporter status:"
sr_curl "${EDGE_SR_URL}/exporters/${EXPORTER_NAME}/status" | jq .

log ""
log "=== Schema Exporter setup complete ==="
log "Edge SR:    ${EDGE_SR_URL}"
log "Hub SR:     ${HUB_SR_URL}"
log "Exporter:   ${EXPORTER_NAME}"
log ""
log "Useful commands:"
log "  List exporters:   curl -k -u ${EDGE_SR_USER}:${EDGE_SR_PASS} ${EDGE_SR_URL}/exporters"
log "  Exporter status:  curl -k -u ${EDGE_SR_USER}:${EDGE_SR_PASS} ${EDGE_SR_URL}/exporters/${EXPORTER_NAME}/status"
log "  Pause:            curl -k -u ${EDGE_SR_USER}:${EDGE_SR_PASS} -X PUT ${EDGE_SR_URL}/exporters/${EXPORTER_NAME}/pause"
log "  Resume:           curl -k -u ${EDGE_SR_USER}:${EDGE_SR_PASS} -X PUT ${EDGE_SR_URL}/exporters/${EXPORTER_NAME}/resume"
