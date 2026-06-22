#!/usr/bin/env bash
# =============================================================================
# Cross-cluster DNS — make the *.kafka.demo names resolvable INSIDE the pods.
#
# Why this is needed:
#   The /etc/hosts entries from scripts/04-get-lb-ips.sh only work for CLI
#   clients on your Mac. Pods running in EKS have no such entries, so anything
#   that connects cross-cluster from *inside* a pod fails to resolve:
#     - ClusterLink   : Hub brokers  -> b{0,1,2}.edge.kafka.demo:9092
#     - Control Center: Hub C3 pod   -> b{0,1,2}.edge.kafka.demo:9092
#     - Schema Linking: Edge SR pod  -> schemaregistry.hub.kafka.demo:8081
#
# What this does:
#   Adds CoreDNS `rewrite` rules so each cluster resolves the *other* cluster's
#   external FQDNs to the real AWS NLB hostnames (which public DNS resolves via
#   the NAT gateway). Because the rewrite preserves the original .demo name for
#   the TLS handshake, the server certificate SANs (*.edge.kafka.demo /
#   *.hub.kafka.demo) still match — no need to disable hostname verification.
#
# Run AFTER Step 6 (NLBs provisioned), BEFORE Step 8 (ClusterLink) / Step 9.
#
# Usage:
#   EDGE_CTX=edge HUB_CTX=hub bash scripts/06-cluster-dns.sh
# =============================================================================

set -euo pipefail

EDGE_CTX="${EDGE_CTX:-edge}"
HUB_CTX="${HUB_CTX:-hub}"
EDGE_NS="cp-edge"
HUB_NS="cp-hub"

log() { echo "[$(date +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# Resolve an LB service to its external hostname (NLBs return hostnames).
get_lb() {
  local ctx="$1" ns="$2" svc="$3" host
  host=$(kubectl --context="${ctx}" get svc "${svc}" -n "${ns}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [[ -n "${host}" ]] || die "Service ${svc} in ${ns} (${ctx}) has no LB hostname yet — wait for the NLB and retry."
  echo "${host}"
}

# Emit "rewrite name exact <demo-fqdn> <nlb-hostname>" lines for one cluster.
build_rules() {
  local ctx="$1" ns="$2" domain="$3"
  echo "rewrite name exact b0.${domain} $(get_lb "${ctx}" "${ns}" kafka-0-lb)"
  echo "rewrite name exact b1.${domain} $(get_lb "${ctx}" "${ns}" kafka-1-lb)"
  echo "rewrite name exact b2.${domain} $(get_lb "${ctx}" "${ns}" kafka-2-lb)"
  echo "rewrite name exact ${domain} $(get_lb "${ctx}" "${ns}" kafka-bootstrap-lb)"
  echo "rewrite name exact schemaregistry.${domain} $(get_lb "${ctx}" "${ns}" schemaregistry-bootstrap-lb)"
  echo "rewrite name exact kafka.${domain} $(get_lb "${ctx}" "${ns}" kafka-kafka-rest-bootstrap-lb)"
}

# Inject the rewrite rules into the target cluster's CoreDNS Corefile.
patch_coredns() {
  local target_ctx="$1" rules="$2"
  log "Patching CoreDNS on ${target_ctx}..."
  kubectl --context="${target_ctx}" -n kube-system get configmap coredns -o json \
    | RULES="${rules}" python3 -c '
import json, os, re, sys
cm = json.load(sys.stdin)
corefile = cm["data"]["Corefile"]
rules = os.environ["RULES"].strip().splitlines()
# Strip any rewrite rules we added previously so the script is idempotent.
corefile = "\n".join(l for l in corefile.splitlines()
                     if not l.strip().startswith("rewrite name exact "))
block = "\n".join("    " + r for r in rules)
# Insert our rules immediately after the first server-block opening brace.
corefile = re.sub(r"(\.:53 \{\n)", r"\1" + block + "\n", corefile, count=1)
cm["data"]["Corefile"] = corefile
print(json.dumps(cm))
' | kubectl --context="${target_ctx}" -n kube-system apply -f -
  # Roll CoreDNS so the new Corefile takes effect immediately.
  kubectl --context="${target_ctx}" -n kube-system rollout restart deploy/coredns
}

log "Collecting Edge NLB hostnames (context: ${EDGE_CTX})..."
EDGE_RULES=$(build_rules "${EDGE_CTX}" "${EDGE_NS}" "edge.kafka.demo")

log "Collecting Hub NLB hostnames (context: ${HUB_CTX})..."
HUB_RULES=$(build_rules "${HUB_CTX}" "${HUB_NS}" "hub.kafka.demo")

# Hub pods (ClusterLink, C3) must reach Edge -> put Edge rules in Hub CoreDNS.
patch_coredns "${HUB_CTX}" "${EDGE_RULES}"

# Edge pods (Schema exporter) must reach Hub -> put Hub rules in Edge CoreDNS.
patch_coredns "${EDGE_CTX}" "${HUB_RULES}"

log ""
log "=== Cross-cluster DNS configured ==="
log "Hub CoreDNS now resolves *.edge.kafka.demo; Edge CoreDNS resolves *.hub.kafka.demo."
log "TLS still verifies against the .demo SANs — no hostname-verification changes needed."
log ""
log "Verify from a pod, e.g.:"
log "  kubectl --context=${HUB_CTX} -n ${HUB_NS} exec kafka-0 -- \\"
log "    nslookup b0.edge.kafka.demo"
log ""
log "SUCCESS"
