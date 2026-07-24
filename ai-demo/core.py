"""
Shared configuration and helpers used by both the CLI agent (agent.py) and
the web UI (webui/app.py). Keeps the system prompt, allowed tools, and
MCP → Bedrock tool conversion in one place.
"""

import os

ALLOWED_TOOLS = {"list-topics", "consume-messages"}

SYSTEM_PROMPT = """\
You are an AI assistant for a SIEM (Security Information and Event Management) demo.
You have access to a read-only Confluent Platform Kafka cluster (Hub) that mirrors
security event data from an Edge cluster. Topics contain DNS logs, FortiGate firewall
logs, Palo Alto logs, and Windows Event Logs — all in Avro format, decoded via Schema Registry.

The tools' `cluster_id` and `environment_id` parameters are for Confluent Cloud only
and are optional. This is a self-managed Confluent Platform cluster with a single
connection configured — always omit `cluster_id` and `environment_id` when calling
tools; never ask the user for them.

When listing topics, focus on the siem_poc_* topics. When consuming messages,
fetch a small sample (10-20 messages) unless the user asks for more.
Be concise and highlight security-relevant patterns in the data.
"""

BEDROCK_MODEL = os.environ.get("BEDROCK_MODEL", "eu.anthropic.claude-haiku-4-5-20251001-v1:0")

REQUIRED_ENV_VARS = (
    "HUB_BOOTSTRAP",
    "HUB_SR_URL",
    "KAFKA_USER",
    "KAFKA_PASSWORD",
    "SR_USER",
    "SR_PASSWORD",
)


def missing_env_vars() -> list[str]:
    return [v for v in REQUIRED_ENV_VARS if not os.environ.get(v)]


def mcp_tool_to_bedrock(tool) -> dict:
    schema = tool.inputSchema or {"type": "object", "properties": {}}
    return {
        "toolSpec": {
            "name": tool.name,
            "description": tool.description or "",
            "inputSchema": {"json": schema},
        }
    }
