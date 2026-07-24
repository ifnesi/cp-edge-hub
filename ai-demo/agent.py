#!/usr/bin/env python3
"""
SIEM AI Agent — terminal chat backed by AWS Bedrock + Confluent MCP Server.

Usage (on EC2, via the convenience wrapper):
    bash ~/ai-demo/run-agent.sh

Or manually:
    source ~/.ai-demo.env
    ~/ai-demo/.venv/bin/python ~/ai-demo/agent.py

Environment (written to ~/.ai-demo.env by setup-ai-demo.sh):
    AWS_REGION          — AWS region
    BEDROCK_MODEL        — Bedrock model id
    HUB_BOOTSTRAP        — Hub Kafka bootstrap (e.g. hub.kafka.demo:9092)
    HUB_SR_URL           — Hub Schema Registry URL
    KAFKA_USER           — Kafka SASL username
    KAFKA_PASSWORD       — Kafka SASL password
    SR_USER              — Schema Registry username
    SR_PASSWORD          — Schema Registry password
    CA_CERT_PATH         — Path to CA certificate (PEM)
    MCP_CONFIG_PATH      — Path to hub-mcp-config.yaml
    MCP_SERVER_PATH      — Path to mcp-confluent dist/index.js (~/mcp-confluent)
"""

import asyncio
import json
import os
import sys
from pathlib import Path
from tempfile import NamedTemporaryFile

import boto3
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from rich.console import Console
from rich.text import Text
from rich.live import Live

from core import ALLOWED_TOOLS, SYSTEM_PROMPT, BEDROCK_MODEL, missing_env_vars, mcp_tool_to_bedrock

console = Console()


# ── Bedrock streaming chat ─────────────────────────────────────────────────────

async def chat(session: ClientSession, bedrock, messages: list[dict]) -> None:
    mcp_tools_result = await session.list_tools()
    allowed = [t for t in mcp_tools_result.tools if t.name in ALLOWED_TOOLS]
    bedrock_tools = [mcp_tool_to_bedrock(t) for t in allowed]

    while True:
        response = bedrock.converse_stream(
            modelId=BEDROCK_MODEL,
            system=[{"text": SYSTEM_PROMPT}],
            messages=messages,
            toolConfig={"tools": bedrock_tools} if bedrock_tools else {},
        )

        current_text = ""
        tool_uses = []
        current_tool: dict | None = None
        stop_reason = None

        console.print()
        with Live(Text(""), console=console, refresh_per_second=15) as live:
            for event in response["stream"]:
                if "contentBlockStart" in event:
                    block = event["contentBlockStart"].get("start", {})
                    if "toolUse" in block:
                        current_tool = {
                            "toolUseId": block["toolUse"]["toolUseId"],
                            "name": block["toolUse"]["name"],
                            "input_str": "",
                        }

                elif "contentBlockDelta" in event:
                    delta = event["contentBlockDelta"]["delta"]
                    if "text" in delta:
                        current_text += delta["text"]
                        live.update(Text(current_text))
                    elif "toolUse" in delta and current_tool:
                        current_tool["input_str"] += delta["toolUse"].get("input", "")

                elif "contentBlockStop" in event:
                    if current_tool:
                        try:
                            current_tool["input"] = json.loads(current_tool["input_str"] or "{}")
                        except json.JSONDecodeError:
                            current_tool["input"] = {}
                        tool_uses.append(current_tool)
                        current_tool = None

                elif "messageStop" in event:
                    stop_reason = event["messageStop"].get("stopReason")

        # Append assistant turn to history
        assistant_content = []
        if current_text:
            assistant_content.append({"text": current_text})
        for tu in tool_uses:
            assistant_content.append({
                "toolUse": {
                    "toolUseId": tu["toolUseId"],
                    "name": tu["name"],
                    "input": tu["input"],
                }
            })
        if assistant_content:
            messages.append({"role": "assistant", "content": assistant_content})

        if stop_reason != "tool_use" or not tool_uses:
            break

        # Execute tool calls via MCP
        tool_results = []
        for tu in tool_uses:
            console.print(
                Text(f"\n  → tool: {tu['name']}  {json.dumps(tu['input'])}", style="dim italic")
            )
            try:
                result = await session.call_tool(tu["name"], tu["input"])
                result_text = "\n".join(
                    block.text for block in result.content if hasattr(block, "text")
                )
                tool_results.append({
                    "toolUseId": tu["toolUseId"],
                    "content": [{"text": result_text}],
                })
            except Exception as exc:
                console.print(Text(f"  [tool error] {exc}", style="red"))
                tool_results.append({
                    "toolUseId": tu["toolUseId"],
                    "content": [{"text": f"Error: {exc}"}],
                })

        messages.append({
            "role": "user",
            "content": [{"toolResult": tr} for tr in tool_results],
        })


# ── Main REPL ──────────────────────────────────────────────────────────────────

async def main():
    aws_region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION", "eu-west-2")
    mcp_config = os.environ.get(
        "MCP_CONFIG_PATH", str(Path(__file__).parent / "hub-mcp-config.yaml")
    )
    mcp_server = os.environ.get(
        "MCP_SERVER_PATH",
        str(Path.home() / "mcp-confluent" / "dist" / "index.js"),
    )
    ca_cert = os.environ.get("CA_CERT_PATH", "")

    missing = missing_env_vars()
    if missing:
        console.print(
            Text(f"Missing environment variables: {', '.join(missing)}\nRun setup-ai-demo.sh first.", style="bold red")
        )
        sys.exit(1)

    if not Path(mcp_server).exists():
        console.print(
            Text(f"MCP server not found at {mcp_server}\nRun setup-ai-demo.sh first.", style="bold red")
        )
        sys.exit(1)

    bedrock = boto3.client("bedrock-runtime", region_name=aws_region)

    mcp_env = {**os.environ}
    if ca_cert:
        mcp_env["NODE_EXTRA_CA_CERTS"] = ca_cert

    server_params = StdioServerParameters(
        command="node",
        args=[mcp_server, "--config", mcp_config],
        env=mcp_env,
    )

    console.print(Text("\n SIEM AI Agent  (type 'exit' or Ctrl-C to quit)\n", style="bold cyan"))
    console.print(Text(f" Model   : {BEDROCK_MODEL}", style="dim"))
    console.print(Text(f" Cluster : {os.environ.get('HUB_BOOTSTRAP', '')}", style="dim"))
    console.print(Text(f" Tools   : {', '.join(sorted(ALLOWED_TOOLS))}\n", style="dim"))

    mcp_log = NamedTemporaryFile(prefix="mcp-confluent-", suffix=".log", delete=False, mode="w")
    console.print(Text(f" MCP logs: {mcp_log.name}\n", style="dim"))

    async with stdio_client(server_params, errlog=mcp_log) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            messages: list[dict] = []

            while True:
                try:
                    user_input = console.input("[bold blue]You:[/bold blue] ").strip()
                except (EOFError, KeyboardInterrupt):
                    console.print("\nBye.")
                    break

                if not user_input or user_input.lower() in ("exit", "quit"):
                    console.print("Bye.")
                    break

                messages.append({"role": "user", "content": [{"text": user_input}]})
                console.print(Text("Agent:", style="bold green"), end=" ")

                try:
                    await chat(session, bedrock, messages)
                except Exception as exc:
                    console.print(Text(f"\n[error] {exc}", style="bold red"))
                    messages.pop()

                console.print()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
