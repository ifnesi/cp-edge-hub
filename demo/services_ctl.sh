#!/usr/bin/env bash
# services_ctl.sh
# Start, stop, restart, or check the status of all SIEM emulator services.
#
# Usage:
#   bash services_ctl.sh start
#   bash services_ctl.sh stop
#   bash services_ctl.sh restart
#   bash services_ctl.sh status

set -euo pipefail

SERVICES=(
  siem-producer-windows
  siem-producer-fortigate
  siem-producer-paloalto
  siem-producer-dns
  siem-fortigate-streaming
  siem-paloalto-streaming
  siem-dns-streaming
)

ACTION="${1:-status}"

case "${ACTION}" in
  start|stop|restart)
    echo "==> ${ACTION^}ing all SIEM services..."
    for svc in "${SERVICES[@]}"; do
      echo -n "  ${svc} ... "
      systemctl "${ACTION}" "${svc}" && echo "OK" || echo "FAILED"
    done
    echo ""
    # Fall through to print status after start/restart
    if [[ "${ACTION}" != "stop" ]]; then
      echo "==> Current status:"
      for svc in "${SERVICES[@]}"; do
        active=$(systemctl is-active "${svc}" 2>/dev/null || true)
        printf "  %-35s %s\n" "${svc}" "${active}"
      done
    fi
    ;;

  status)
    echo "==> SIEM service status:"
    all_ok=true
    for svc in "${SERVICES[@]}"; do
      active=$(systemctl is-active "${svc}" 2>/dev/null || true)
      enabled=$(systemctl is-enabled "${svc}" 2>/dev/null || true)
      printf "  %-35s active=%-10s enabled=%s\n" "${svc}" "${active}" "${enabled}"
      [[ "${active}" == "active" ]] || all_ok=false
    done
    echo ""
    if ${all_ok}; then
      echo "All services are running."
    else
      echo "One or more services are not active. Run 'journalctl -u <service> -n 50' to investigate."
      exit 1
    fi
    ;;

  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac
