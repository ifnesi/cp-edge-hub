#!/usr/bin/env bash
# Convenience wrapper — sources the env file and starts the web UI.
# Binds to 127.0.0.1 only; reach it via SSM port forwarding (see ai-demo/README.md).
set -euo pipefail

ENV_FILE="${HOME}/.ai-demo.env"
WEBUI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DEMO_DIR="$(cd "${WEBUI_DIR}/.." && pwd)"
PYTHON="${AI_DEMO_DIR}/.venv/bin/python"

[[ -f "${ENV_FILE}" ]] || { echo "Run setup-ai-demo.sh first."; exit 1; }
[[ -x "${PYTHON}" ]]   || { echo "Virtual env not found — run setup-ai-demo.sh first."; exit 1; }

source "${ENV_FILE}"
exec "${PYTHON}" "${WEBUI_DIR}/app.py"
