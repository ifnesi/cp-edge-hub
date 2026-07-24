#!/usr/bin/env bash
# Convenience wrapper — sources the env file and starts the agent.
set -euo pipefail

ENV_FILE="${HOME}/.ai-demo.env"
AI_DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${AI_DEMO_DIR}/.venv/bin/python"

[[ -f "${ENV_FILE}" ]] || { echo "Run setup-ai-demo.sh first."; exit 1; }
[[ -x "${PYTHON}" ]]   || { echo "Virtual env not found — run setup-ai-demo.sh first."; exit 1; }

source "${ENV_FILE}"
exec "${PYTHON}" "${AI_DEMO_DIR}/agent.py"
