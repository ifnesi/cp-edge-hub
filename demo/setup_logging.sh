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

# ── Step 2: rsyslog per-service routing ───────────────────────────────────────
echo "==> Configuring rsyslog routing to ${LOG_DIR}..."
mkdir -p "${LOG_DIR}"

cat > /etc/rsyslog.d/50-siem.conf <<EOF
# SIEM emulator — route each service to its own log file.
# Matched on SyslogIdentifier (= programname in rsyslog) set in each .service unit.
:programname, isequal, "siem-producer-windows"    ${LOG_DIR}/producer-windows.log
:programname, isequal, "siem-producer-fortigate"  ${LOG_DIR}/producer-fortigate.log
:programname, isequal, "siem-producer-paloalto"   ${LOG_DIR}/producer-paloalto.log
:programname, isequal, "siem-producer-dns"        ${LOG_DIR}/producer-dns.log
:programname, isequal, "siem-fortigate-streaming" ${LOG_DIR}/streaming-fortigate.log
:programname, isequal, "siem-paloalto-streaming"  ${LOG_DIR}/streaming-paloalto.log
:programname, isequal, "siem-dns-streaming"       ${LOG_DIR}/streaming-dns.log
EOF

systemctl restart rsyslog
echo "  Created /etc/rsyslog.d/50-siem.conf"
echo "  Restarted rsyslog."

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
    create 0640 root adm
    sharedscripts
    postrotate
        systemctl kill -s HUP rsyslog 2>/dev/null || true
    endscript
}
EOF

echo "  Created /etc/logrotate.d/siem"

# Dry-run to verify the config is valid
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
