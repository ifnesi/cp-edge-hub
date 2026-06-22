#!/usr/bin/env bash
# Generates (or regenerates) the four Python client config files under config/.
# Run this after Step 6 if you need to change bootstrap FQDNs, credentials,
# or the CA cert path.
#
# Override any value via environment variable before running, e.g.:
#   EDGE_BOOTSTRAP="b0.edge.kafka.demo:9092" KAFKA_USER=myuser ./scripts/05-generate-client-configs.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SCRIPT_DIR}/.."
CONFIG_DIR="${ROOT_DIR}/config"

# Defaults match the deployment settings in edge/ and hub/ CRDs
EDGE_BOOTSTRAP="${EDGE_BOOTSTRAP:-edge.kafka.demo:9092}"
HUB_BOOTSTRAP="${HUB_BOOTSTRAP:-hub.kafka.demo:9092}"
EDGE_SR_URL="${EDGE_SR_URL:-https://schemaregistry.edge.kafka.demo:8081}"
HUB_SR_URL="${HUB_SR_URL:-https://schemaregistry.hub.kafka.demo:8081}"
KAFKA_USER="${KAFKA_USER:-client}"
KAFKA_PASS="${KAFKA_PASS:-client-secret}"
SR_USER="${SR_USER:-admin}"
SR_PASS="${SR_PASS:-admin-secret}"
# Path written into config files — relative to wherever the Python script runs.
# Default assumes scripts run from the repo root.
CA_CERT_PATH="${CA_CERT_PATH:-certs/cacerts.pem}"

log() { echo "[$(date +%H:%M:%S)] $*"; }

mkdir -p "${CONFIG_DIR}"

# ---------------------------------------------------------------------------
write_kafka() {
  local cluster="$1" bootstrap="$2" out="$3"
  log "Writing ${out}..."
  cat > "${out}" <<EOF
# Kafka client configuration — ${cluster} cluster
# librdkafka / confluent-kafka-python reference:
# https://github.com/confluentinc/librdkafka/blob/master/CONFIGURATION.md

bootstrap.servers=${bootstrap}
security.protocol=SASL_SSL
sasl.mechanisms=PLAIN
sasl.username=${KAFKA_USER}
sasl.password=${KAFKA_PASS}

# Path to the shared CA certificate (relative to where your script runs).
ssl.ca.location=${CA_CERT_PATH}

# Uncomment to disable hostname verification (not recommended, even for PoC)
#ssl.endpoint.identification.algorithm=none

# Optional — tune for throughput
#compression.type=lz4
#batch.size=65536
#linger.ms=5
#statistics.interval.ms=1000
EOF
}

write_registry() {
  local cluster="$1" url="$2" out="$3"
  log "Writing ${out}..."
  cat > "${out}" <<EOF
# Schema Registry client configuration — ${cluster} cluster
# Used with confluent-kafka-python SerializingProducer / DeserializingConsumer.

schema.registry.url=${url}
schemaRegistryURL=${url}

# Basic auth
schema.registry.basic.auth.credentials.source=USER_INFO
schema.registry.basic.auth.user.info=${SR_USER}:${SR_PASS}

# TLS — shared CA cert (relative to where your script runs)
ssl.ca.location=${CA_CERT_PATH}
schema.registry.ssl.ca.location=${CA_CERT_PATH}

# Schema auto-registration (set to false in production)
auto.register.schemas=true
EOF
}

write_kafka    "Edge" "${EDGE_BOOTSTRAP}" "${CONFIG_DIR}/kafka_edge.properties"
write_kafka    "Hub"  "${HUB_BOOTSTRAP}"  "${CONFIG_DIR}/kafka_hub.properties"
write_registry "Edge" "${EDGE_SR_URL}"    "${CONFIG_DIR}/registry_edge.properties"
write_registry "Hub"  "${HUB_SR_URL}"     "${CONFIG_DIR}/registry_hub.properties"

log ""
log "=== Client configs written to ${CONFIG_DIR}/ ==="
log ""
log "Usage in Python (confluent-kafka):"
log "  from confluent_kafka import Producer"
log "  import configparser"
log ""
log "  config = configparser.ConfigParser()"
log "  config.read('config/kafka_edge.properties')"
log "  producer = Producer(dict(config['DEFAULT']))"
