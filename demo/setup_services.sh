#!/usr/bin/env bash
# setup_services.sh
# Creates, installs, and enables all SIEM emulator systemd service units.
# Run once as root (or via sudo) after cloning the repo.
#
# Usage (from ~/siem-emulator on the EC2):
#   sudo bash setup_services.sh
#   sudo bash setup_services.sh --repo-dir /opt/siem-emulator --user myuser
#   sudo bash setup_services.sh --frequency 0.05 --batch-size 50 --partitions 3 -rf 3
#   sudo bash setup_services.sh --kafka-config /path/to/kafka.properties --registry-config /path/to/registry.properties

set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
# This script lives in ~/siem-emulator/ on the EC2. Kafka/SR config files live
# in ~/siem-emulator/kafka/ (copied there by scripts/08-copy-config-to-ec2.sh).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"          # ~/siem-emulator/
REPO_DIR="${REPO_DIR:-${SCRIPT_DIR}}"                # ~/siem-emulator/
VENV_DIR="${REPO_DIR}/.venv"
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-$(logname 2>/dev/null || echo ssm-user)}}"
SYSTEMD_DIR="/etc/systemd/system"
RESTART_SEC=10   # seconds before restarting a failed service

# ── Producer defaults (passed to every siem_producer.py invocation) ───────────
FREQUENCY=0.1
BATCH_SIZE=20
PARTITIONS=3
REPLICATION_FACTOR=3
# Absolute paths so service units resolve correctly regardless of WorkingDirectory.
KAFKA_CONFIG="${REPO_DIR}/kafka/kafka_edge.properties"
REGISTRY_CONFIG="${REPO_DIR}/kafka/registry_edge.properties"

# ── Producer topic names ───────────────────────────────────────────────────────
TOPIC_WINDOWS="siem_poc_windows_eventlog_logs"
TOPIC_FORTIGATE="siem_poc_fortigate_logs"
TOPIC_PALOALTO="siem_poc_paloalto_logs"
TOPIC_DNS="siem_poc_dns_logs"

# ── Streaming app source topics ────────────────────────────────────────────────
SOURCE_TOPIC_FORTIGATE=$TOPIC_FORTIGATE
SOURCE_TOPIC_PALOALTO=$TOPIC_PALOALTO
SOURCE_TOPIC_DNS=$TOPIC_DNS

# ── DNS streaming app tunables ─────────────────────────────────────────────────
DNS_WINDOW_SECONDS=300

# Allow overrides from CLI flags
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo-dir)               REPO_DIR="$2";              VENV_DIR="${REPO_DIR}/.venv"; shift 2 ;;
    --user)                   SERVICE_USER="$2";           shift 2 ;;
    --frequency)              FREQUENCY="$2";              shift 2 ;;
    --batch-size)             BATCH_SIZE="$2";             shift 2 ;;
    --partitions)             PARTITIONS="$2";             shift 2 ;;
    --replication-factor)     REPLICATION_FACTOR="$2";     shift 2 ;;
    --kafka-config)           KAFKA_CONFIG="$2";           shift 2 ;;
    --registry-config)        REGISTRY_CONFIG="$2";        shift 2 ;;
    --topic-windows)          TOPIC_WINDOWS="$2";          shift 2 ;;
    --topic-fortigate)        TOPIC_FORTIGATE="$2";        shift 2 ;;
    --topic-paloalto)         TOPIC_PALOALTO="$2";         shift 2 ;;
    --topic-dns)              TOPIC_DNS="$2";              shift 2 ;;
    --source-topic-fortigate) SOURCE_TOPIC_FORTIGATE="$2"; shift 2 ;;
    --source-topic-paloalto)  SOURCE_TOPIC_PALOALTO="$2";  shift 2 ;;
    --source-topic-dns)       SOURCE_TOPIC_DNS="$2";       shift 2 ;;
    --window-seconds)         DNS_WINDOW_SECONDS="$2";     shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

PYTHON="${VENV_DIR}/bin/python"

echo "==> Repo dir            : ${REPO_DIR}"
echo "==> Venv                : ${VENV_DIR}"
echo "==> Run as              : ${SERVICE_USER}"
echo "==> Frequency           : ${FREQUENCY}s"
echo "==> Batch size          : ${BATCH_SIZE}"
echo "==> Partitions          : ${PARTITIONS}"
echo "==> Replication factor  : ${REPLICATION_FACTOR}"
echo "==> Kafka config        : ${KAFKA_CONFIG}"
echo "==> Registry config     : ${REGISTRY_CONFIG}"
echo "==> Topics (producers)  : windows=${TOPIC_WINDOWS}  fortigate=${TOPIC_FORTIGATE}  paloalto=${TOPIC_PALOALTO}  dns=${TOPIC_DNS}"
echo "==> Source topics (apps): fortigate=${SOURCE_TOPIC_FORTIGATE}  paloalto=${SOURCE_TOPIC_PALOALTO}  dns=${SOURCE_TOPIC_DNS}"
echo "==> DNS window          : ${DNS_WINDOW_SECONDS}s"
echo ""

if [[ ! -x "${PYTHON}" ]]; then
  echo "ERROR: Python not found at ${PYTHON}"
  echo "       Create the venv first:  python3 -m venv ${VENV_DIR} && ${VENV_DIR}/bin/pip install -r ${REPO_DIR}/requirements.txt"
  exit 1
fi

# ── Helper: write a .service file ─────────────────────────────────────────────
write_service() {
  local name="$1"       # e.g. siem-producer-windows
  local workdir="$2"    # absolute working directory
  local exec_cmd="$3"   # everything after the python binary
  local description="$4"

  local unit_file="${SYSTEMD_DIR}/${name}.service"

  cat > "${unit_file}" <<EOF
[Unit]
Description=${description}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
WorkingDirectory=${workdir}
ExecStart=${PYTHON} ${exec_cmd}
Restart=on-failure
RestartSec=${RESTART_SEC}
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${name}

[Install]
WantedBy=multi-user.target
EOF

  echo "  Created ${unit_file}"
}

# ── Service definitions ────────────────────────────────────────────────────────
echo "==> Writing service unit files..."

# Producers — working directory: REPO_DIR
PRODUCER_COMMON="-f ${FREQUENCY} -b ${BATCH_SIZE} -p ${PARTITIONS} -rf ${REPLICATION_FACTOR} --kafka-config ${KAFKA_CONFIG} --registry-config ${REGISTRY_CONFIG}"

write_service "siem-producer-windows" \
  "${REPO_DIR}" \
  "siem_producer.py windows_event_log -t ${TOPIC_WINDOWS} -k Computer ${PRODUCER_COMMON}" \
  "SIEM Producer — Windows Event Log"

write_service "siem-producer-fortigate" \
  "${REPO_DIR}" \
  "siem_producer.py fortigate_log -t ${TOPIC_FORTIGATE} --no-schema -k devname ${PRODUCER_COMMON}" \
  "SIEM Producer — FortiGate"

write_service "siem-producer-paloalto" \
  "${REPO_DIR}" \
  "siem_producer.py paloalto_log -t ${TOPIC_PALOALTO} --no-schema -k devname ${PRODUCER_COMMON}" \
  "SIEM Producer — Palo Alto"

write_service "siem-producer-dns" \
  "${REPO_DIR}" \
  "siem_producer.py dns_log -t ${TOPIC_DNS} -k src_ip ${PRODUCER_COMMON}" \
  "SIEM Producer — DNS"

# Streaming apps — working directory: REPO_DIR/demo
write_service "siem-fortigate-streaming" \
  "${REPO_DIR}/demo" \
  "fortigate_streaming_app.py --kafka-config ${KAFKA_CONFIG} -p ${PARTITIONS} -rf ${REPLICATION_FACTOR} --registry-config ${REGISTRY_CONFIG} --schema-dir ./schemas/ --source-topic ${SOURCE_TOPIC_FORTIGATE}" \
  "SIEM Streaming App — FortiGate"

write_service "siem-paloalto-streaming" \
  "${REPO_DIR}/demo" \
  "paloalto_streaming_app.py --kafka-config ${KAFKA_CONFIG} -p ${PARTITIONS} -rf ${REPLICATION_FACTOR} --registry-config ${REGISTRY_CONFIG} --schema-dir ./schemas/ --source-topic ${SOURCE_TOPIC_PALOALTO}" \
  "SIEM Streaming App — Palo Alto"

write_service "siem-dns-streaming" \
  "${REPO_DIR}/demo" \
  "dns_streaming_app.py --kafka-config ${KAFKA_CONFIG} -p ${PARTITIONS} -rf ${REPLICATION_FACTOR} --registry-config ${REGISTRY_CONFIG} --schema-dir ./schemas/ --source-topic ${SOURCE_TOPIC_DNS} --window-seconds ${DNS_WINDOW_SECONDS}" \
  "SIEM Streaming App — DNS Aggregation"

# ── Reload and enable ─────────────────────────────────────────────────────────
echo ""
echo "==> Reloading systemd daemon..."
systemctl daemon-reload

SERVICES=(
  siem-producer-windows
  siem-producer-fortigate
  siem-producer-paloalto
  siem-producer-dns
  siem-fortigate-streaming
  siem-paloalto-streaming
  siem-dns-streaming
)

echo "==> Enabling services (start on boot)..."
for svc in "${SERVICES[@]}"; do
  systemctl enable "${svc}"
  echo "  Enabled ${svc}"
done

echo ""
echo "Done. All services are installed and enabled."
echo ""
echo "Next steps (from ~/siem-emulator):"
echo "  Start all services now  :  bash services_ctl.sh start"
echo "  Check status            :  bash services_ctl.sh status"
echo "  Follow logs for a unit  :  journalctl -u siem-producer-dns -f"
