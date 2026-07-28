# SIEM AI Agent

Lets you query the Hub Kafka cluster in natural language, via the
[Confluent MCP Server](https://github.com/confluentinc/mcp-confluent)
(cloned directly on the EC2 during setup). Three ways to use it:

- **Option A — Claude Code** connected directly to the MCP server over HTTP
  (Claude itself is the agent — no Bedrock, no custom chat app)
- **Option B — Web UI** — a small Flask + React chat app using AWS Bedrock (Claude Haiku 4.5) as the LLM
- **Option C — Terminal CLI** — same Bedrock-backed agent as Option B, as a chat REPL

This demo is **self-contained** — its own Python venv, own CA cert copy, own
setup script — independent of the main siem-emulator demo under `demo/`.

```
Option A:  Claude Code ──▶ mcp-confluent (HTTP, API-key auth) ──▶ Hub Kafka + SR
Option B/C: agent.py / webui ──▶ AWS Bedrock (Claude Haiku 4.5)
                              │
                              ▼ tool calls (stdio)
                         mcp-confluent (~/mcp-confluent on EC2)
                              │
                              ▼ SASL_SSL / HTTPS
                         Hub Kafka + Schema Registry
```

All three are **read-only** against Hub and expose the same tools:
- `list-topics` — list topics on the Hub cluster
- `consume-messages` — fetch and Avro-decode messages from a topic via Schema Registry
- `list-schemas` — list registered schemas (full Avro definitions) in the Hub Schema Registry

None of these expose anything publicly — everything is reached from your Mac
via an SSM port-forward tunnel into the EC2's private subnet.

---

## Prerequisites

- EC2 producer host running (Terraform provisioned)
- EC2 has outbound internet access (NAT Gateway) — needed to clone mcp-confluent from GitHub
- The EC2 resolves `*.kafka.demo` hostnames. This is set up by
  `scripts/06-cluster-dns.sh` + `scripts/08-copy-config-to-ec2.sh` from the
  main deployment — run those once if you haven't already (they only touch
  `/etc/hosts` and don't require using the siem-emulator producers)
- Your AWS IAM role/user has `bedrock:InvokeModelWithResponseStream` permission
  for `eu.anthropic.claude-haiku-4-5-20251001-v1:0` in the region used by Terraform
  (`terraform output aws_region`)

---

## Setup

### Step 1 — Copy files to EC2 (run from your Mac, repo root)

```bash
bash ai-demo/copy-to-ec2.sh
```

This copies `core.py`, `agent.py`, `hub-mcp-config.yaml`, the setup/run
scripts, the `webui/` folder, and the CA certificate to `~/ai-demo/` on the EC2.

### Step 2 — Run setup on EC2 (run once after Step 1)

Connect to the EC2:

```bash
INSTANCE_ID=$(cd terraform && terraform output -raw producer_host_instance_id)
REGION=$(cd terraform && terraform output -raw aws_region)
aws ssm start-session --target "$INSTANCE_ID" --region "$REGION"
```

Then on the EC2:

```bash
bash ~/ai-demo/setup-ai-demo.sh
```

This script:
1. Installs Node.js 22 via nvm (if not already present)
2. Clones `https://github.com/confluentinc/mcp-confluent` into `~/mcp-confluent/` (or `git pull` if already cloned)
3. Runs `npm ci && npm run build` inside `~/mcp-confluent/`
4. Creates its own Python venv at `~/ai-demo/.venv/` and installs `boto3`, `mcp`, `rich`, `flask`
5. Writes `~/.ai-demo.env` with connection details (Hub bootstrap/SR URL default
   to the standard values used across this repo's demos; override via env vars
   if you've customized them — see the top of `setup-ai-demo.sh`)

---

## Option A — Claude Code (direct MCP connection)

Run the Confluent MCP Server over HTTP on the EC2 and connect Claude Code to
it directly through an SSM tunnel. Claude becomes the agent — no Bedrock, no
custom chat app. Anyone running Claude Code can follow these steps.

> **Enterprise policy note:** some Claude Code deployments block the ad-hoc
> `claude mcp add` command entirely (`Cannot add MCP server "...": not allowed
> by enterprise policy`) — it writes to your global user config, which many
> orgs disallow for auditability. The project-level `.mcp.json` approach below
> is the sanctioned alternative: the server is declared in a file checked into
> this repo, and Claude Code prompts you to approve it (or your admin
> allowlists it by name via `enabledMcpjsonServers` in settings) rather than
> letting any command silently register arbitrary servers. If your org blocks
> project MCP servers too, fall back to [Option B](#option-b--web-ui) or
> [Option C](#option-c--terminal-cli) instead.

### 1. Generate an API key on the EC2 (one-time)

Connect to the EC2 (see [Setup](#setup) above if you haven't already run
Steps 1–2), then:

```bash
export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
node ~/mcp-confluent/dist/index.js --generate-key
```

This prints a key like `MCP_API_KEY=3959339c...`. **Treat it as a secret** —
it grants read access to the Hub cluster's topics and schemas. Don't commit
it or paste it anywhere public.

### 2. Start the HTTP MCP server on the EC2

```bash
MCP_API_KEY="<paste-your-key>" nohup bash ~/ai-demo/run-mcp-http.sh > ~/mcp-http.log 2>&1 &
```

This uses `hub-mcp-http-config.yaml` (HTTP transport, API-key auth, bound to
`127.0.0.1:8080` on the EC2) — separate from `hub-mcp-config.yaml` (stdio),
which Options B/C use. Both can run at the same time without conflict.

Verify it started cleanly:

```bash
tail -20 ~/mcp-http.log
```

### 3. Tunnel to it from your Mac

Open a **separate terminal** on your Mac:

```bash
INSTANCE_ID=$(cd terraform && terraform output -raw producer_host_instance_id)
REGION=$(cd terraform && terraform output -raw aws_region)
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$REGION" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}'
```

Leave this running.

### 4. Register the MCP server with Claude Code

This repo already includes a project-level `.mcp.json` at the repo root
declaring the `hub-confluent` server:

```json
{
  "mcpServers": {
    "hub-confluent": {
      "type": "http",
      "url": "http://localhost:8080/mcp",
      "headers": {
        "cflt-mcp-api-key": "${MCP_API_KEY}"
      }
    }
  }
}
```

The API key is read from your shell environment (never hardcoded/committed).
Export it before launching Claude Code, from the repo root:

```bash
export MCP_API_KEY="<paste-your-key>"
claude
```

On first use, Claude Code will prompt you to approve the `hub-confluent`
project MCP server (since it's declared in `.mcp.json`, not added via `claude
mcp add`). Approve it, then ask things like *"what topics are on the Hub
cluster?"* or *"show me the schema for the DNS logs topic"* and Claude will
call the tools directly.

> To skip the approval prompt on every machine, add `"hub-confluent"` to
> `enabledMcpjsonServers` in your `~/.claude/settings.json` (or ask your org
> admin to allowlist it there).

### Stopping the HTTP MCP server

When you're done, stop it on the EC2 (and close the SSM tunnel on your Mac
with Ctrl-C):

```bash
pkill -f run-mcp-http.sh
```

---

## Option B — Web UI

The web UI is a Flask backend (reusing the same Bedrock + MCP logic as the
CLI) with a single-file React frontend loaded from a CDN — no npm install or
build step required.

### Start the web server on the EC2

```bash
bash ~/ai-demo/webui/run-webui.sh
```

This starts Flask on `127.0.0.1:5050` (change the port with `WEBUI_PORT` if needed).
Leave this running in the SSM session (or in the background — see note below).

### Tunnel to it from your Mac

Open a **separate terminal** on your Mac and start an SSM port-forwarding session:

```bash
INSTANCE_ID=$(cd terraform && terraform output -raw producer_host_instance_id)
REGION=$(cd terraform && terraform output -raw aws_region)
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$REGION" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["5050"],"localPortNumber":["5050"]}'
```

> **macOS note:** port 5000 is often taken locally by AirPlay Receiver — that's
> why Flask defaults to 5050 instead. Change both `portNumber` and
> `WEBUI_PORT`/`localPortNumber` together if you need a different port.

Then open **http://localhost:5050** in your browser. Enter any username (no
password) and start chatting.

> To run the web server in the background so it survives your SSM session
> closing, use `nohup bash ~/ai-demo/webui/run-webui.sh &` or run it inside a
> `tmux`/`screen` session on the EC2.

---

## Option C — Terminal CLI

```bash
bash ~/ai-demo/run-agent.sh
```

Or manually:

```bash
source ~/.ai-demo.env
~/ai-demo/.venv/bin/python ~/ai-demo/agent.py
```

### Example session

```
 SIEM AI Agent  (type 'exit' or Ctrl-C to quit)

 Model   : eu.anthropic.claude-haiku-4-5-20251001-v1:0
 Cluster : hub.kafka.demo:9092
 Tools   : consume-messages, list-schemas, list-topics

You: what topics are available?

Agent:
  → tool: list-topics  {}

  Here are the SIEM topics on the Hub cluster:
  - siem_poc_dns_logs-aggregate
  - siem_poc_fortigate_logs-event-system
  - siem_poc_fortigate_logs-traffic-forward
  ...

You: show me the last 5 DNS log messages

Agent:
  → tool: consume-messages  {"topic": "siem_poc_dns_logs-aggregate", "maxMessages": 5}

  Here are 5 recent DNS log entries: ...
```

---

## Redeploying after EC2 restart

The `~/.ai-demo.env` file persists across reboots. If the EC2 is replaced,
re-run `ai-demo/copy-to-ec2.sh` from your Mac (Step 1), then
`bash ~/ai-demo/setup-ai-demo.sh` on the EC2 (Step 2).

---

## IAM permissions for Bedrock

Your EC2 instance role (or SSM session credentials) need:

```json
{
  "Effect": "Allow",
  "Action": ["bedrock:InvokeModelWithResponseStream"],
  "Resource": [
    "arn:aws:bedrock:*::foundation-model/anthropic.claude-haiku*",
    "arn:aws:bedrock:*:*:inference-profile/eu.anthropic.claude-haiku*"
  ]
}
```

> **Cross-region inference profiles are region-specific.** `BEDROCK_MODEL`
> defaults to `eu.anthropic.claude-haiku-4-5-20251001-v1:0` (the `eu.` prefix
> matches Terraform's `eu-west-2` region). If you deploy in a different AWS
> region, list the profiles actually available there and override
> `BEDROCK_MODEL` accordingly:
> ```bash
> aws bedrock list-inference-profiles --region <your-region> \
>   --query "inferenceProfileSummaries[?contains(inferenceProfileId, 'haiku')].inferenceProfileId"
> ```

Check the current IAM role attached to the EC2 in the AWS Console under
**EC2 → Instances → IAM role**, then add the policy there.
