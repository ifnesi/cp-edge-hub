#!/usr/bin/env bash
# =============================================================================
# Copy client config files, CA cert, and demo scripts to the EC2 producer host
# via SSM (no SCP / no S3).
#
# Usage (from repo root):
#   INSTANCE_ID=i-0abc1234 REGION=eu-west-2 bash scripts/08-copy-config-to-ec2.sh
#
# If INSTANCE_ID / REGION are not set, they are read from Terraform state.
# Requires ssm:SendCommand + ssm:GetCommandInvocation on the target instance.
# =============================================================================

set -euo pipefail

log()  { echo "[$(date +%H:%M:%S)] $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

REMOTE_HOME="/home/ssm-user/siem-emulator"
REMOTE_KAFKA_DIR="${REMOTE_HOME}/kafka"
REMOTE_CERTS_DIR="${REMOTE_HOME}/certs"

EDGE_CTX="${EDGE_CTX:-}"
HUB_CTX="${HUB_CTX:-}"
EDGE_NS="cp-edge"
HUB_NS="cp-hub"

# Resolve INSTANCE_ID and REGION from Terraform if not already exported.
if [[ -z "${INSTANCE_ID:-}" ]]; then
  log "INSTANCE_ID not set — reading from Terraform state..."
  INSTANCE_ID=$(cd terraform && terraform output -raw producer_host_instance_id)
fi

if [[ -z "${REGION:-}" ]]; then
  log "REGION not set — reading from Terraform state..."
  REGION=$(cd terraform && terraform output -raw aws_region)
fi

[[ -n "${INSTANCE_ID}" ]] || die "Could not determine INSTANCE_ID"
[[ -n "${REGION}" ]]      || die "Could not determine REGION"

log "Target: ${INSTANCE_ID} (${REGION})"

# Send a single shell command via SSM; fire-and-forget with a short poll.
# --cli-read-timeout prevents the AWS CLI from hanging indefinitely.
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

# Send a multi-line shell script via SSM (base64-encoded to avoid JSON quoting issues).
ssm_run_script() {
  local script="$1"
  local b64
  b64=$(printf '%s' "${script}" | base64 | tr -d '\n')
  ssm_run "echo '${b64}' | base64 -d | bash"
}

# Get the NLB DNS hostname for a service (not the IP — the EC2 resolves it locally).
get_lb_fqdn() {
  local ctx="$1" ns="$2" svc="$3"
  local kctl="kubectl"
  [[ -n "${ctx}" ]] && kctl="kubectl --context=${ctx}"
  local addr
  addr=$($kctl get svc "${svc}" -n "${ns}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -z "${addr}" ]] && addr=$($kctl get svc "${svc}" -n "${ns}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  echo "${addr:-<pending>}"
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

# ── Ensure remote dirs exist ──────────────────────────────────────────────────
log "Creating remote directories..."
ssm_run "mkdir -p ${REMOTE_KAFKA_DIR} ${REMOTE_CERTS_DIR}"

# ── CA certificate ────────────────────────────────────────────────────────────
log "Copying CA certificate..."
send_file "certs/cacerts.pem" "${REMOTE_CERTS_DIR}"

# ── Kafka client configs ──────────────────────────────────────────────────────
log "Copying Kafka client configs..."
for src in \
  config/kafka_edge.properties \
  config/kafka_hub.properties \
  config/registry_edge.properties \
  config/registry_hub.properties
do
  [[ -f "${src}" ]] || die "File not found: ${src} — run scripts/05-generate-client-configs.sh first"
  send_file "${src}" "${REMOTE_KAFKA_DIR}"
done

# ── Demo scripts ──────────────────────────────────────────────────────────────
log "Copying demo scripts..."
for src in \
  demo/setup_services.sh \
  demo/services_ctl.sh \
  demo/setup_logging.sh
do
  send_file "${src}" "${REMOTE_HOME}"
done
ssm_run "chmod +x ${REMOTE_HOME}/*.sh"


# Patch all relative cert paths to absolute so configs work from any working directory.
log "Patching cert paths to absolute in configs..."
ssm_run "sed -i 's|ssl\.ca\.location=.*|ssl.ca.location=${REMOTE_CERTS_DIR}/cacerts.pem|g' ${REMOTE_KAFKA_DIR}/*.properties"
ssm_run "sed -i 's|schema\.registry\.ssl\.ca\.location=.*|schema.registry.ssl.ca.location=${REMOTE_CERTS_DIR}/cacerts.pem|g' ${REMOTE_KAFKA_DIR}/*.properties"

# ── /etc/hosts — resolve NLB hostnames on the EC2 (gets VPC-internal IPs) ────
log "Fetching NLB DNS hostnames from kubectl..."
EDGE_B0_FQDN=$(get_lb_fqdn "${EDGE_CTX}" "${EDGE_NS}" "kafka-0-lb")
EDGE_B1_FQDN=$(get_lb_fqdn "${EDGE_CTX}" "${EDGE_NS}" "kafka-1-lb")
EDGE_B2_FQDN=$(get_lb_fqdn "${EDGE_CTX}" "${EDGE_NS}" "kafka-2-lb")
EDGE_BS_FQDN=$(get_lb_fqdn "${EDGE_CTX}" "${EDGE_NS}" "kafka-bootstrap-lb")
EDGE_SR_FQDN=$(get_lb_fqdn "${EDGE_CTX}" "${EDGE_NS}" "schemaregistry-bootstrap-lb")
EDGE_REST_FQDN=$(get_lb_fqdn "${EDGE_CTX}" "${EDGE_NS}" "kafka-kafka-rest-bootstrap-lb")

HUB_B0_FQDN=$(get_lb_fqdn "${HUB_CTX}" "${HUB_NS}" "kafka-0-lb")
HUB_B1_FQDN=$(get_lb_fqdn "${HUB_CTX}" "${HUB_NS}" "kafka-1-lb")
HUB_B2_FQDN=$(get_lb_fqdn "${HUB_CTX}" "${HUB_NS}" "kafka-2-lb")
HUB_BS_FQDN=$(get_lb_fqdn "${HUB_CTX}" "${HUB_NS}" "kafka-bootstrap-lb")
HUB_SR_FQDN=$(get_lb_fqdn "${HUB_CTX}" "${HUB_NS}" "schemaregistry-bootstrap-lb")
HUB_REST_FQDN=$(get_lb_fqdn "${HUB_CTX}" "${HUB_NS}" "kafka-kafka-rest-bootstrap-lb")

for var_name in EDGE_B0_FQDN EDGE_B1_FQDN EDGE_B2_FQDN EDGE_BS_FQDN EDGE_SR_FQDN EDGE_REST_FQDN \
                HUB_B0_FQDN HUB_B1_FQDN HUB_B2_FQDN HUB_BS_FQDN HUB_SR_FQDN HUB_REST_FQDN; do
  val="${!var_name}"
  if [[ "${val}" == "<pending>" || -z "${val}" ]]; then
    die "${var_name} is not ready — check kubectl context and that NLBs have external IPs"
  fi
done

# The EC2 resolves each NLB FQDN via VPC DNS, yielding the NLB's private (VPC-internal) IP.
# This avoids hairpin-NAT issues that occur when private-subnet hosts try to reach
# internet-facing NLB public IPs via the NAT gateway.
log "Updating /etc/hosts on EC2 (EC2 resolves NLB FQDNs to VPC-internal IPs)..."
RESOLVE_CMD="$(cat <<SCRIPT
set -e
resolve() { dig +short "\$1" | grep -E '^[0-9.]+\$' | head -1; }
sed -i '/\\.kafka\\.demo/d' /etc/hosts
printf "%s   b0.edge.kafka.demo\n"            "\$(resolve ${EDGE_B0_FQDN})"   >> /etc/hosts
printf "%s   b1.edge.kafka.demo\n"            "\$(resolve ${EDGE_B1_FQDN})"   >> /etc/hosts
printf "%s   b2.edge.kafka.demo\n"            "\$(resolve ${EDGE_B2_FQDN})"   >> /etc/hosts
printf "%s   edge.kafka.demo\n"               "\$(resolve ${EDGE_BS_FQDN})"   >> /etc/hosts
printf "%s   schemaregistry.edge.kafka.demo\n" "\$(resolve ${EDGE_SR_FQDN})"  >> /etc/hosts
printf "%s   kafka.edge.kafka.demo\n"         "\$(resolve ${EDGE_REST_FQDN})" >> /etc/hosts
printf "%s   b0.hub.kafka.demo\n"             "\$(resolve ${HUB_B0_FQDN})"    >> /etc/hosts
printf "%s   b1.hub.kafka.demo\n"             "\$(resolve ${HUB_B1_FQDN})"    >> /etc/hosts
printf "%s   b2.hub.kafka.demo\n"             "\$(resolve ${HUB_B2_FQDN})"    >> /etc/hosts
printf "%s   hub.kafka.demo\n"                "\$(resolve ${HUB_BS_FQDN})"    >> /etc/hosts
printf "%s   schemaregistry.hub.kafka.demo\n" "\$(resolve ${HUB_SR_FQDN})"   >> /etc/hosts
printf "%s   kafka.hub.kafka.demo\n"          "\$(resolve ${HUB_REST_FQDN})"  >> /etc/hosts
SCRIPT
)"
ssm_run_script "${RESOLVE_CMD}"

log ""
log "SUCCESS"
log "  ${REMOTE_CERTS_DIR}/cacerts.pem"
log "  ${REMOTE_KAFKA_DIR}/*.properties"
log "  ${REMOTE_HOME}/*.sh  (executable)"

log "  /etc/hosts updated with fresh NLB IPs"
