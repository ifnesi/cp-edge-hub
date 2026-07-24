#!/usr/bin/env python3
"""
SIEM AI Agent — Web UI (Flask backend + React frontend, no build step).

Binds to 127.0.0.1 only — reach it via SSM port forwarding, never expose
this port on a public interface.

Usage:
    source ~/.ai-demo.env
    ~/ai-demo/.venv/bin/python ~/ai-demo/webui/app.py
"""

import json
import os
import sys
import uuid
from pathlib import Path

import boto3
from flask import Flask, Response, jsonify, render_template, request, session

sys.path.insert(0, str(Path(__file__).parent.parent))
from core import BEDROCK_MODEL, SYSTEM_PROMPT, missing_env_vars  # noqa: E402
from mcp_worker import MCPWorker  # noqa: E402

WEBUI_PORT = int(os.environ.get("WEBUI_PORT", "5050"))

missing = missing_env_vars()
if missing:
    print(f"Missing environment variables: {', '.join(missing)}\nRun setup-ai-demo.sh first.", file=sys.stderr)
    sys.exit(1)

app = Flask(__name__)
app.secret_key = os.environ.get("FLASK_SECRET_KEY", uuid.uuid4().hex)

aws_region = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION", "eu-west-2")
bedrock = boto3.client("bedrock-runtime", region_name=aws_region)

worker = MCPWorker()
worker.start()

# In-memory per-session conversation history — fine for a single-process demo.
CONVERSATIONS: dict[str, list[dict]] = {}


def get_conversation() -> list[dict]:
    sid = session.get("sid")
    if not sid or sid not in CONVERSATIONS:
        sid = uuid.uuid4().hex
        session["sid"] = sid
        CONVERSATIONS[sid] = []
    return CONVERSATIONS[sid]


@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/login", methods=["POST"])
def login():
    data = request.get_json(force=True) or {}
    username = (data.get("username") or "").strip()
    if not username:
        return jsonify({"error": "Username is required"}), 400
    session["username"] = username
    session["sid"] = uuid.uuid4().hex
    CONVERSATIONS[session["sid"]] = []
    return jsonify({"username": username})


@app.route("/api/logout", methods=["POST"])
def logout():
    session.clear()
    return jsonify({"ok": True})


@app.route("/api/me")
def me():
    username = session.get("username")
    if not username:
        return jsonify({"error": "Not logged in"}), 401
    return jsonify({
        "username": username,
        "model": BEDROCK_MODEL,
        "cluster": os.environ.get("HUB_BOOTSTRAP", ""),
    })


def sse(event: dict) -> str:
    return f"data: {json.dumps(event)}\n\n"


@app.route("/api/chat", methods=["POST"])
def chat():
    if not session.get("username"):
        return jsonify({"error": "Not logged in"}), 401

    data = request.get_json(force=True) or {}
    user_message = (data.get("message") or "").strip()
    if not user_message:
        return jsonify({"error": "message is required"}), 400

    messages = get_conversation()
    messages.append({"role": "user", "content": [{"text": user_message}]})

    def generate():
        bedrock_tools = worker.bedrock_tools()

        while True:
            response = bedrock.converse_stream(
                modelId=BEDROCK_MODEL,
                system=[{"text": SYSTEM_PROMPT}],
                messages=messages,
                toolConfig={"tools": bedrock_tools} if bedrock_tools else {},
            )

            current_text = ""
            tool_uses = []
            current_tool = None
            stop_reason = None

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
                        yield sse({"type": "text_delta", "text": delta["text"]})
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

            tool_results = []
            for tu in tool_uses:
                yield sse({"type": "tool_call", "name": tu["name"], "input": tu["input"]})
                try:
                    result = worker.call_tool(tu["name"], tu["input"])
                    result_text = "\n".join(
                        block.text for block in result.content if hasattr(block, "text")
                    )
                    tool_results.append({"toolUseId": tu["toolUseId"], "content": [{"text": result_text}]})
                except Exception as exc:  # noqa: BLE001
                    yield sse({"type": "tool_error", "name": tu["name"], "error": str(exc)})
                    tool_results.append({"toolUseId": tu["toolUseId"], "content": [{"text": f"Error: {exc}"}]})

            messages.append({
                "role": "user",
                "content": [{"toolResult": tr} for tr in tool_results],
            })

        yield sse({"type": "done"})

    return Response(generate(), mimetype="text/event-stream")


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=WEBUI_PORT, debug=False, use_reloader=False, threaded=True)
