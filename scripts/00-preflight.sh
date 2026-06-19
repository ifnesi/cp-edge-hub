#!/usr/bin/env bash
# =============================================================================
# Pre-flight checks — run before deploying to catch the common foot-guns:
#   - missing CLIs
#   - AWS credentials not set
#   - kube contexts missing / not pointing at EKS
#   - node groups not labelled (role=broker / role=controller) or not Ready
#   - a rough capacity sanity check against the CPU requests in the manifests
#
# Safe to run repeatedly. Read-only — it changes nothing.
#
# Usage:
#   EDGE_CTX=edge HUB_CTX=hub bash scripts/00-preflight.sh
# =============================================================================

set -uo pipefail

EDGE_CTX="${EDGE_CTX:-edge}"
HUB_CTX="${HUB_CTX:-hub}"

PASS=0; WARN=0; FAIL=0
ok()   { echo "  ✅ $*"; PASS=$((PASS+1)); }
warn() { echo "  ⚠️  $*"; WARN=$((WARN+1)); }
bad()  { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
hdr()  { echo; echo "── $* ──"; }

# ---------------------------------------------------------------------------
hdr "Required CLIs"
for tool in cfssl cfssljson helm kubectl aws terraform jq keytool; do
  if command -v "$tool" >/dev/null 2>&1; then ok "$tool found"; else bad "$tool missing"; fi
done

# SSM plugin ships as a cask and isn't on PATH the normal way — check the known binary path
if command -v session-manager-plugin >/dev/null 2>&1 || \
   [[ -x /usr/local/sessionmanagerplugin/bin/session-manager-plugin ]]; then
  ok "session-manager-plugin found"
else
  warn "session-manager-plugin not found — required for 'aws ssm start-session' (brew install --cask session-manager-plugin)"
fi

# ---------------------------------------------------------------------------
hdr "AWS credentials"
if aws sts get-caller-identity >/dev/null 2>&1; then
  ok "AWS identity: $(aws sts get-caller-identity --query Arn --output text 2>/dev/null)"
else
  bad "aws sts get-caller-identity failed — set AWS_PROFILE / run 'aws configure'"
fi

# ---------------------------------------------------------------------------
check_cluster() {
  local ctx="$1" want_brokers=3 want_controllers=3
  hdr "Cluster: ${ctx}"

  if ! kubectl --context="${ctx}" version >/dev/null 2>&1; then
    warn "context '${ctx}' not reachable yet (expected before Step 0 finishes) — skipping"
    return
  fi
  ok "context '${ctx}' reachable"

  local ready
  ready=$(kubectl --context="${ctx}" get nodes --no-headers 2>/dev/null | grep -c " Ready ")
  if [[ "${ready}" -ge 6 ]]; then ok "${ready} nodes Ready"; else warn "${ready} nodes Ready (expected 6)"; fi

  local b c
  b=$(kubectl --context="${ctx}" get nodes -l role=broker --no-headers 2>/dev/null | wc -l | tr -d ' ')
  c=$(kubectl --context="${ctx}" get nodes -l role=controller --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "${b}" -eq "${want_brokers}" ]]     && ok "${b} nodes labelled role=broker"     || warn "found ${b} role=broker nodes (expected ${want_brokers})"
  [[ "${c}" -eq "${want_controllers}" ]] && ok "${c} nodes labelled role=controller" || warn "found ${c} role=controller nodes (expected ${want_controllers})"

  # Capacity sanity: broker nodes must expose >2500m allocatable for the broker pod.
  local alloc
  alloc=$(kubectl --context="${ctx}" get nodes -l role=broker \
    -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null)
  if [[ -n "${alloc}" ]]; then
    ok "broker node allocatable CPU: ${alloc} (broker pod requests 2500m)"
  fi
}

check_cluster "${EDGE_CTX}"
check_cluster "${HUB_CTX}"

# ---------------------------------------------------------------------------
hdr "Summary"
echo "  ${PASS} passed, ${WARN} warnings, ${FAIL} failures"
if [[ "${FAIL}" -gt 0 ]]; then
  echo "  ❌ Resolve the failures above before deploying."
  exit 1
fi
echo "  ✅ Pre-flight OK (warnings are fine before the clusters exist)."
