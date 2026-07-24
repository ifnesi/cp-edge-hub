#!/usr/bin/env bash
# =============================================================================
# Copy the AI demo files to the EC2 producer host via SSM (no SCP / no S3).
#
# Fully independent of the main siem-emulator demo (scripts/08-*) — copies its
# own CA cert and agent files. Re-run any time you update agent.py,
# hub-mcp-config.yaml, or the setup/run scripts.
#
# Prerequisite: the EC2 must already resolve *.kafka.demo hostnames. If you've
# run scripts/06-cluster-dns.sh + scripts/08-copy-config-to-ec2.sh for the main
# demo, this is already in place. Otherwise run scripts/08-copy-config-to-ec2.sh
# at least once to populate /etc/hosts on the EC2 (it does this regardless of
# whether you use the siem-emulator producers).
#
# Usage (from repo root):
#   INSTANCE_ID=i-0abc1234 REGION=eu-west-2 bash ai-demo/copy-to-ec2.sh
#
# If INSTANCE_ID / REGION are not set, they are read from Terraform state.
# Requires ssm:SendCommand + ssm:GetCommandInvocation on the target instance.
# =============================================================================

set -euo pipefail

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

AI_DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="/home/ssm-user"
REMOTE_AI_DIR="${HOME_DIR}/ai-demo"

# Resolve INSTANCE_ID and REGION from Terraform if not already exported.
if [[ -z "${INSTANCE_ID:-}" ]]; then
  log "INSTANCE_ID not set — reading from Terraform state..."
  INSTANCE_ID=$(cd "${AI_DEMO_DIR}/.." && terraform -chdir=terraform output -raw producer_host_instance_id)
fi

if [[ -z "${REGION:-}" ]]; then
  log "REGION not set — reading from Terraform state..."
  REGION=$(cd "${AI_DEMO_DIR}/.." && terraform -chdir=terraform output -raw aws_region)
fi

[[ -n "${INSTANCE_ID}" ]] || die "Could not determine INSTANCE_ID"
[[ -n "${REGION}" ]]      || die "Could not determine REGION"

log "Target: ${INSTANCE_ID} (${REGION})"

# Send a single shell command via SSM; fire-and-forget with a short poll.
ssm_run() {
  local cmd="$1"
  aws ssm send-command \
    --instance-id "${INSTANCE_ID}" \
    --region "${REGION}" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"${cmd}\"]" \
    --cli-read-timeout 30 \
    --output text > /dev/null 2>&1
  sleep 5
}

# Copy a local file to a remote directory via SSM (base64 to avoid quoting issues).
send_file() {
  local src="$1" remote_dir="$2"
  local filename b64
  filename=$(basename "${src}")
  [[ -f "${src}" ]] || die "File not found: ${src}"
  log "  ${src} → ${remote_dir}/${filename}"
  b64=$(base64 < "${src}" | tr -d '\n')
  ssm_run "mkdir -p ${remote_dir} && echo '${b64}' | base64 -d > ${remote_dir}/${filename}"
}

log "Creating remote directories..."
ssm_run "mkdir -p ${REMOTE_AI_DIR}/certs ${REMOTE_AI_DIR}/webui/templates"

log "Copying AI demo files..."
for src in \
  core.py \
  agent.py \
  requirements.txt \
  hub-mcp-config.yaml \
  setup-ai-demo.sh \
  run-agent.sh
do
  send_file "${AI_DEMO_DIR}/${src}" "${REMOTE_AI_DIR}"
done

log "Copying web UI files..."
for src in \
  webui/app.py \
  webui/mcp_worker.py \
  webui/run-webui.sh
do
  send_file "${AI_DEMO_DIR}/${src}" "${REMOTE_AI_DIR}/webui"
done
send_file "${AI_DEMO_DIR}/webui/templates/index.html" "${REMOTE_AI_DIR}/webui/templates"

log "Copying CA certificate..."
CA_CERT_SRC="${AI_DEMO_DIR}/../certs/cacerts.pem"
[[ -f "${CA_CERT_SRC}" ]] || die "${CA_CERT_SRC} not found — run certs/generate-certs.sh first"
send_file "${CA_CERT_SRC}" "${REMOTE_AI_DIR}/certs"

ssm_run "chmod +x ${REMOTE_AI_DIR}/setup-ai-demo.sh ${REMOTE_AI_DIR}/run-agent.sh ${REMOTE_AI_DIR}/webui/run-webui.sh"

log ""
log "SUCCESS"
log "  ${REMOTE_AI_DIR}/*  copied to EC2"
log ""
log "Next: SSH to the EC2 and run:"
log "  bash ${REMOTE_AI_DIR}/setup-ai-demo.sh"
