#!/bin/bash
# Install Confluent Platform license on Edge and Hub clusters.
# License is read from ../license.txt (JWT token).
# If license.txt does not exist, provides guidance on disabling the license in CRDs.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
LICENSE_FILE="${REPO_ROOT}/license.txt"

# Allow context overrides via env vars
EDGE_CTX="${EDGE_CTX:-edge}"
HUB_CTX="${HUB_CTX:-hub}"

# Check if license.txt exists
if [ ! -f "$LICENSE_FILE" ]; then
  echo "❌ license.txt not found in repo root"
  echo ""
  echo "The CfK resources are configured to use a license by default."
  echo "If you don't have a license, comment out the license blocks:"
  echo ""
  echo "  # In these files:"
  echo "  #   - edge/01-kraftcontroller.yaml"
  echo "  #   - edge/02-kafka.yaml"
  echo "  #   - edge/03-schemaregistry.yaml"
  echo "  #   - hub/01-kraftcontroller.yaml"
  echo "  #   - hub/02-kafka.yaml"
  echo "  #   - hub/03-schemaregistry.yaml"
  echo ""
  echo "  # Comment out these lines:"
  echo "  #   license:"
  echo "  #     secretRef: confluent-license"
  echo ""
  echo "Then re-apply the CRDs. Clusters will run in trial mode (some features have 30-day limits)."
  echo ""
  echo "If you have a license, place it here:"
  echo "  cat > license.txt <<'EOF'"
  echo "  <your-jwt-token-here>"
  echo "  EOF"
  echo ""
  echo "Then run this script again."
  exit 1
fi

# Trim whitespace from license content
LICENSE_CONTENT=$(cat "$LICENSE_FILE" | tr -d '[:space:]')

if [ -z "$LICENSE_CONTENT" ]; then
  echo "❌ license.txt is empty"
  exit 1
fi

# Validate JWT format (basic check: should have 3 parts separated by dots)
if [[ ! "$LICENSE_CONTENT" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]]; then
  echo "❌ license.txt does not appear to be a valid JWT token"
  echo "   Expected format: <header>.<payload>.<signature>"
  exit 1
fi

echo "📦 Installing Confluent Platform license..."

# CfK 3.2 expects the license secret key to be `license.txt` and its *value* to
# be in properties format: `license=<JWT>` (not the bare JWT).
LICENSE_VALUE="license=${LICENSE_CONTENT}"

# Create license secret on Edge cluster
echo "  → Creating license secret on Edge cluster (${EDGE_CTX})"
kubectl --context="${EDGE_CTX}" create secret generic confluent-license \
  --from-literal=license.txt="${LICENSE_VALUE}" \
  -n cp-edge \
  --dry-run=client -o yaml | kubectl --context="${EDGE_CTX}" apply -f -

# Create license secret on Hub cluster
echo "  → Creating license secret on Hub cluster (${HUB_CTX})"
kubectl --context="${HUB_CTX}" create secret generic confluent-license \
  --from-literal=license.txt="${LICENSE_VALUE}" \
  -n cp-hub \
  --dry-run=client -o yaml | kubectl --context="${HUB_CTX}" apply -f -

echo "✅ License secrets created successfully"
