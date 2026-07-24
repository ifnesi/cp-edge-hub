# SIEM AI Agent

An AI chat agent that lets you query the Hub Kafka cluster in natural
language, available as a **terminal CLI** and a **web UI**. Both use AWS
Bedrock (Claude Haiku 4.5) as the LLM and the
[Confluent MCP Server](https://github.com/confluentinc/mcp-confluent) as the
Kafka interface (cloned directly on the EC2 during setup).

This demo is **self-contained** — its own Python venv, own CA cert copy, own
setup script — independent of the main siem-emulator demo under `demo/`.

```
You ──▶ agent.py / webui ──▶ AWS Bedrock (Claude Haiku 4.5)
                          │
                          ▼ tool calls (stdio)
                     mcp-confluent (~/mcp-confluent on EC2)
                          │
                          ▼ SASL_SSL / HTTPS
                     Hub Kafka + Schema Registry
```

The agent is **read-only** and exposes three tools to the model:
- `list-topics` — list topics on the Hub cluster
- `consume-messages` — fetch and Avro-decode messages from a topic via Schema Registry
- `list-schemas` — list registered schemas in the Hub Schema Registry

The web UI binds to `127.0.0.1` on the EC2 only — it is never exposed
publicly. Reach it from your Mac via an SSM port-forward tunnel (see
[Web UI](#web-ui) below). Login is username-only (no password) — it just
labels the session, matching the demo's trust model.

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

## Option A — Web UI (Recommended)

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

## Option B — Terminal CLI

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
