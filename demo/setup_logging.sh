#!/usr/bin/env bash
# setup_logging.sh
# Configures persistent disk logging for all SIEM emulator services.
# Run once as root (or via sudo) after setup_services.sh.
#
# What it does:
#   1. Enables persistent journald storage (logs survive reboots)
#   2. Configures rsyslog to route each service's output to /var/log/siem/
#   3. Installs a logrotate rule: daily rotation, 30-day retention, gzip compression
#
# No changes to any Python script are required — routing is done via the
# SyslogIdentifier field already set in each .service unit.
#
# Usage (from the demo/ folder):
#   sudo bash setup_logging.sh
#   sudo bash setup_logging.sh --log-dir /data/logs/siem --retain-days 60

set -euo pipefail

LOG_DIR="/var/log/siem"
RETAIN_DAYS=30

while [[ $# -gt 0 ]]; do
  case $1 in
    --log-dir)      LOG_DIR="$2";      shift 2 ;;
    --retain-days)  RETAIN_DAYS="$2";  shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "==> Log directory  : ${LOG_DIR}"
echo "==> Retention days : ${RETAIN_DAYS}"
echo ""

# ── Step 1: persistent journald storage ───────────────────────────────────────
echo "==> Enabling persistent journald storage..."
mkdir -p /var/log/journal
systemd-tmpfiles --create --prefix /var/log/journal
systemctl restart systemd-journald
echo "  Done."

# ── Step 2: per-service log files via journald forwarder units ────────────────
# Amazon Linux 2023 ships without rsyslog. We create a lightweight systemd
# "journal-tail" service for each SIEM unit that pipes journalctl output to a
# plain log file — no rsyslog required.
echo "==> Creating journald log-forwarder units to ${LOG_DIR}..."
mkdir -p "${LOG_DIR}"

declare -A UNITS=(
  [siem-producer-windows]="producer-windows.log"
  [siem-producer-fortigate]="producer-fortigate.log"
  [siem-producer-paloalto]="producer-paloalto.log"
  [siem-producer-dns]="producer-dns.log"
  [siem-fortigate-streaming]="streaming-fortigate.log"
  [siem-paloalto-streaming]="streaming-paloalto.log"
  [siem-dns-streaming]="streaming-dns.log"
)

for svc in "${!UNITS[@]}"; do
  logfile="${LOG_DIR}/${UNITS[$svc]}"
  forwarder="siem-log-${svc#siem-}"   # e.g. siem-log-producer-windows
  cat > "/etc/systemd/system/${forwarder}.service" <<EOF
[Unit]
Description=Journal forwarder for ${svc}
After=${svc}.service
BindsTo=${svc}.service

[Service]
Type=simple
ExecStart=/bin/bash -c 'journalctl -u ${svc} -f --output=short-iso >> ${logfile}'
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl enable --now "${forwarder}" > /dev/null 2>&1
  echo "  ${forwarder} → ${logfile}"
done

systemctl daemon-reload

# ── Step 3: logrotate rule ────────────────────────────────────────────────────
echo "==> Installing logrotate rule (daily, ${RETAIN_DAYS} days)..."

cat > /etc/logrotate.d/siem <<EOF
${LOG_DIR}/*.log {
    daily
    rotate ${RETAIN_DAYS}
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    sharedscripts
}
EOF

echo "  Created /etc/logrotate.d/siem"

logrotate --debug /etc/logrotate.d/siem > /dev/null 2>&1 \
  && echo "  logrotate config OK." \
  || echo "  WARNING: logrotate --debug returned an error — review /etc/logrotate.d/siem"

echo ""
echo "Done. Logs will appear in ${LOG_DIR}/ once the services produce output."
echo ""
echo "Useful commands:"
echo "  tail -f ${LOG_DIR}/streaming-dns.log"
echo "  journalctl -u siem-dns-streaming --since '1h ago'"
echo "  sudo logrotate --debug /etc/logrotate.d/siem   # dry-run rotation"
