#!/usr/bin/env bash
# =============================================================================
# Run the Confluent MCP Server directly over HTTP so an external MCP client
# (e.g. Claude Code on your Mac) can connect to it through an SSM port-forward
# tunnel — instead of going through agent.py / webui.
#
# Separate from hub-mcp-config.yaml (stdio, used by agent.py/webui) — this
# uses hub-mcp-http-config.yaml (HTTP transport, API-key auth).
#
# Usage:
#   MCP_API_KEY="<generated-key>" bash ~/ai-demo/run-mcp-http.sh
#
# Generate a key first (one-time):
#   export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
#   node ~/mcp-confluent/dist/index.js --generate-key
# =============================================================================
set -euo pipefail

: "${MCP_HTTP_PORT:=8080}"

AI_DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${HOME}/.ai-demo.env"

[[ -f "${ENV_FILE}" ]] || { echo "Run setup-ai-demo.sh first."; exit 1; }
[[ -n "${MCP_API_KEY:-}" ]] || { echo "MCP_API_KEY is required. Generate one with:"; \
  echo "  node ~/mcp-confluent/dist/index.js --generate-key"; exit 1; }

source "${ENV_FILE}"
export MCP_API_KEY MCP_HTTP_PORT
export NODE_EXTRA_CA_CERTS="${CA_CERT_PATH}"

export NVM_DIR="${HOME}/.nvm"
[[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"

echo "Starting mcp-confluent on http://127.0.0.1:${MCP_HTTP_PORT} (API-key auth enabled)..."
exec node "${HOME}/mcp-confluent/dist/index.js" --config "${AI_DEMO_DIR}/hub-mcp-http-config.yaml"
