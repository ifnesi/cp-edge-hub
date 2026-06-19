#!/usr/bin/env bash
# Generates self-signed CA + server certs for Edge and Hub clusters.
# Prerequisites: cfssl, cfssljson, keytool (JDK), openssl
#   brew install cfssl
#   JDK: brew install --cask temurin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERTS_DIR="${SCRIPT_DIR}"
JKS_PASSWORD="${JKS_PASSWORD:-mystorepassword}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

# ---------------------------------------------------------------------------
# 1. Shared CA (single CA signs both clusters — simplifies cross-cluster TLS)
# ---------------------------------------------------------------------------
generate_ca() {
  log "Generating shared CA..."
  cat <<EOF > "${CERTS_DIR}/ca-csr.json"
{
  "CN": "Confluent Demo CA",
  "key": { "algo": "rsa", "size": 4096 },
  "names": [{ "C": "US", "O": "Confluent", "OU": "Demo" }]
}
EOF
  cfssl gencert -initca "${CERTS_DIR}/ca-csr.json" | cfssljson -bare "${CERTS_DIR}/ca"
  rm -f "${CERTS_DIR}/ca-csr.json"

  # Rename to conventional names
  mv "${CERTS_DIR}/ca.pem"     "${CERTS_DIR}/cacerts.pem"
  mv "${CERTS_DIR}/ca-key.pem" "${CERTS_DIR}/rootCAkey.pem"
  rm -f "${CERTS_DIR}/ca.csr"
  log "CA generated: cacerts.pem, rootCAkey.pem"
}

# ---------------------------------------------------------------------------
# 2. Server cert for a cluster
#    Usage: generate_server_cert <cluster> <domain-json-file> <output-dir>
# ---------------------------------------------------------------------------
generate_server_cert() {
  local cluster="$1"
  local domain_json="$2"
  local out_dir="$3"

  mkdir -p "${out_dir}"
  log "Generating server cert for ${cluster}..."

  cfssl gencert \
    -ca="${CERTS_DIR}/cacerts.pem" \
    -ca-key="${CERTS_DIR}/rootCAkey.pem" \
    -config="${CERTS_DIR}/ca-config.json" \
    -profile=server \
    "${domain_json}" | cfssljson -bare "${out_dir}/kafka-server"

  rm -f "${out_dir}/kafka-server.csr"
  log "Server cert generated: ${out_dir}/kafka-server.pem"
}

# ---------------------------------------------------------------------------
# 3. JKS truststore (for CLI / Java clients on the Mac)
# ---------------------------------------------------------------------------
generate_truststore() {
  local cluster="$1"
  local out_dir="$2"

  log "Generating JKS truststore for ${cluster}..."

  # Convert CA PEM to DER
  openssl x509 -outform der \
    -in "${CERTS_DIR}/cacerts.pem" \
    -out "${out_dir}/cacerts.der"

  # Import into JKS
  keytool -import -noprompt \
    -alias "ca-root" \
    -keystore "${out_dir}/truststore.jks" \
    -storepass "${JKS_PASSWORD}" \
    -file "${out_dir}/cacerts.der"

  rm -f "${out_dir}/cacerts.der"
  log "Truststore: ${out_dir}/truststore.jks (password: ${JKS_PASSWORD})"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
generate_ca

generate_server_cert "edge" \
  "${CERTS_DIR}/edge-domain.json" \
  "${CERTS_DIR}/edge"

generate_server_cert "hub" \
  "${CERTS_DIR}/hub-domain.json" \
  "${CERTS_DIR}/hub"

# Copy shared CA into each cluster's cert dir (needed for truststore + K8s secrets)
cp "${CERTS_DIR}/cacerts.pem"   "${CERTS_DIR}/edge/cacerts.pem"
cp "${CERTS_DIR}/rootCAkey.pem" "${CERTS_DIR}/edge/rootCAkey.pem"
cp "${CERTS_DIR}/cacerts.pem"   "${CERTS_DIR}/hub/cacerts.pem"
cp "${CERTS_DIR}/rootCAkey.pem" "${CERTS_DIR}/hub/rootCAkey.pem"

generate_truststore "edge" "${CERTS_DIR}/edge"
generate_truststore "hub"  "${CERTS_DIR}/hub"

log ""
log "=== Certificate generation complete ==="
log "Shared CA:   ${CERTS_DIR}/cacerts.pem"
log "Edge certs:  ${CERTS_DIR}/edge/"
log "Hub certs:   ${CERTS_DIR}/hub/"
log ""
log "Both clusters share the same CA so cross-cluster TLS (Cluster Link) works"
log "with a single truststore."
