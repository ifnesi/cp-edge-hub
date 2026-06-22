# SIEM Emulator - Linux Service Setup (EC2)

This guide explains how to run the SIEM emulator components as persistent
**systemd** services on an Amazon Linux 2 / Amazon Linux 2023 EC2 instance so
that each process starts on boot and restarts automatically on failure.

---

## Prerequisites

First, connect to the EC2 instance via SSM (run this from your Mac, repo root):

```bash
INSTANCE_ID=$(cd terraform && terraform output -raw producer_host_instance_id)
REGION=$(cd terraform && terraform output -raw aws_region)
aws ssm start-session --target "$INSTANCE_ID" --region "$REGION"
```

Once you have a shell on the instance, clone the repo and set up the environment:

```bash
# Go to the user home folder
cd ~
# Clone the repo
git clone https://github.com/ifnesi/siem-emulator.git
cd siem-emulator

# Create the virtual environment and install dependencies
sudo dnf install -y python3.12
python3.12 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate
```

> The setup script auto-detects `REPO_DIR` as `demo/siem-emulator/` (relative to
> this repo). Override with `--repo-dir` if you clone the emulator elsewhere.

**Exit the EC2 session**, then run the following from your Mac (repo root) to
copy the Kafka client config files and demo scripts to the instance:

> **IAM requirement:** this script uses `ssm:SendCommand` — make sure your IAM
> user has that action in its inline policy (see **IAM Permissions** in the main
> README).

```bash
bash scripts/08-copy-config-to-ec2.sh
```

**Reconnect to the EC2:**

```bash
INSTANCE_ID=$(cd terraform && terraform output -raw producer_host_instance_id)
REGION=$(cd terraform && terraform output -raw aws_region)
aws ssm start-session --target "$INSTANCE_ID" --region "$REGION"
```

**Verify the files are in place and make the scripts executable:**

```bash
ls -l ~/siem-emulator/certs/       # cacerts.pem
ls -l ~/siem-emulator/kafka/       # kafka_edge/hub + registry_edge/hub .properties
sudo chmod +x ~/siem-emulator/*.sh
ls -l ~/siem-emulator/*.sh         # services_ctl.sh  setup_logging.sh  setup_services.sh
cat /etc/hosts
```

---

## Services

| Service name | Script | Working dir |
|---|---|---|
| `siem-producer-windows` | `siem_producer.py windows_event_log` | `REPO_DIR/` |
| `siem-producer-fortigate` | `siem_producer.py fortigate_log` | `REPO_DIR/` |
| `siem-producer-paloalto` | `siem_producer.py paloalto_log` | `REPO_DIR/` |
| `siem-producer-dns` | `siem_producer.py dns_log` | `REPO_DIR/` |
| `siem-fortigate-streaming` | `demo/fortigate_streaming_app.py` | `REPO_DIR/demo/` |
| `siem-paloalto-streaming` | `demo/paloalto_streaming_app.py` | `REPO_DIR/demo/` |
| `siem-dns-streaming` | `demo/dns_streaming_app.py` | `REPO_DIR/demo/` |

All services use `Restart=on-failure` with a 10-second back-off so a transient
broker outage or crash does not spin-loop the process.

---

## Quick start

Run everything from the `~/siem-emulator` folder on the EC2:

```bash
cd ~/siem-emulator

# 1. Create and enable all service units
sudo bash setup_services.sh --user ssm-user

# 2. Start every service and watch their status
sudo bash services_ctl.sh start
bash services_ctl.sh status
```

---

## Day-2 operations

```bash
# From demo/

# Start / stop / restart all at once
sudo bash services_ctl.sh start
sudo bash services_ctl.sh stop
sudo bash services_ctl.sh restart

# Status summary of all services
bash services_ctl.sh status

# Follow logs for a specific service via journald
sudo journalctl -u siem-producer-dns -f
sudo journalctl -u siem-dns-streaming -f

sudo journalctl -u siem-producer-fortigate -f
sudo journalctl -u siem-fortigate-streaming -f

sudo journalctl -u siem-producer-paloalto -f
sudo journalctl -u siem-paloalto-streaming -f

sudo journalctl -u siem-producer-windows -f

# Reload a unit file after editing it
sudo systemctl daemon-reload
sudo systemctl restart siem-producer-dns
```

---

## Disk logging (daily rotation, 30-day retention)

All services write to the console, which systemd captures via **journald**. To
also write logs to disk (one file per service, rotated daily, kept for 30 days)
run the logging setup script - **no Python code changes required**. It works by
reading the `SyslogIdentifier` field that each `.service` unit already sets and
forwarding matching entries from journald to per-service files via rsyslog.

```bash
# From demo/
sudo bash setup_logging.sh

# Follow logs via the on-disk log file (after logging setup - see below)
sudo tail -f /var/log/siem/producer-dns.log
sudo tail -f /var/log/siem/streaming-dns.log

sudo tail -f /var/log/siem/producer-fortigate.log
sudo tail -f /var/log/siem/streaming-fortigate.log

sudo tail -f /var/log/siem/producer-paloalto.log
sudo tail -f /var/log/siem/streaming-paloalto.log

sudo tail -f /var/log/siem/producer-windows.log
```

What the script does:

1. **Enables persistent journald storage** so logs survive reboots and remain
   queryable with `journalctl` even without rsyslog.
2. **Configures rsyslog** to route each service's output to its own file under
   `/var/log/siem/`.
3. **Installs a logrotate rule** that rotates files daily, compresses rotated
   files (`.gz`), and deletes files older than 30 days.

### Log files

| Service | Log file |
|---|---|
| `siem-producer-windows` | `/var/log/siem/producer-windows.log` |
| `siem-producer-fortigate` | `/var/log/siem/producer-fortigate.log` |
| `siem-producer-paloalto` | `/var/log/siem/producer-paloalto.log` |
| `siem-producer-dns` | `/var/log/siem/producer-dns.log` |
| `siem-fortigate-streaming` | `/var/log/siem/streaming-fortigate.log` |
| `siem-paloalto-streaming` | `/var/log/siem/streaming-paloalto.log` |
| `siem-dns-streaming` | `/var/log/siem/streaming-dns.log` |

### Useful log commands

```bash
# Real-time tail of a single service log file
tail -f /var/log/siem/streaming-dns.log

# Historical query via journald (works with or without disk logging)
journalctl -u siem-dns-streaming --since yesterday
journalctl -u siem-dns-streaming --since "2h ago"

# Test logrotate config (dry-run)
sudo logrotate --debug /etc/logrotate.d/siem
```

---

## Deploy the Splunk Sink Connector

The Splunk HTTP Event Collector (HEC) connector reads all `siem_poc.*` topics from Hub
and forwards events to Splunk. Run these commands from the **repo root on your Mac**.

### Step 1 — Copy the CA cert into the Connect pod

The connector needs to verify Hub's Schema Registry TLS certificate.

```bash
kubectl --context=hub exec -n cp-hub connect-0 -- mkdir -p /home/appuser/certs
base64 < certs/cacerts.pem | \
  kubectl --context=hub exec -i -n cp-hub connect-0 -- \
    sh -c 'base64 -d > /home/appuser/certs/cacerts.pem'
```

> `kubectl cp` requires `tar` in the container image; the Connect image does not include it,
> so we pipe the cert as base64 instead.

### Step 2 — Deploy the connector

Run from your **Mac** (requires `jq` and `kubectl` with the hub context).
Substitute all `certs/cacerts.pem` references with the in-pod absolute path, then POST
the config to the Connect REST API from inside the pod:

```bash
HEC_TOKEN="<your-hec-token>"
HEC_URI="https://<your-splunk-host>:8088"

jq --arg token "$HEC_TOKEN" \
   --arg uri   "$HEC_URI" \
   '
   .config["splunk.hec.token"]  = $token |
   .config["splunk.hec.uri"]    = $uri
   ' demo/splunk-sink-config.json \
| kubectl --context=hub exec -i -n cp-hub connect-0 -- \
    curl -s -X POST http://localhost:8083/connectors \
         -H "Content-Type: application/json" \
         -d @-
```

### Step 3 — Verify

```bash
# List connectors
kubectl --context=hub exec -n cp-hub connect-0 -- \
  curl -s http://localhost:8083/connectors | jq

# Check connector status
kubectl --context=hub exec -n cp-hub connect-0 -- \
  curl -s http://localhost:8083/connectors/siem-poc-splunk-sink/status | jq
```

The connector's egress IP (visible to Splunk's HEC allowlist) is the NAT Gateway public IP.
Retrieve it with:

```bash
echo $(cd terraform && terraform output nat_gateway_public_ip)
```

### Delete the connector

To remove the connector (e.g. before redeploying with updated config):

```bash
kubectl --context=hub exec -n cp-hub connect-0 -- \
  curl -s -X DELETE http://localhost:8083/connectors/siem-poc-splunk-sink
```

---

## Manual commands (reference)

These are the exact commands each service wraps.

### Producers (run from `demo/siem-emulator/`)

```bash
# Windows Event Log producer
python siem_producer.py windows_event_log \
  -t siem_poc_windows_eventlog_logs -f 0.1 -b 20 -p 1 \
  --kafka-config ../../config/kafka_edge.properties \
  --registry-config ../../config/registry_edge.properties

# FortiGate producer
python siem_producer.py fortigate_log \
  -t siem_poc_fortigate_logs -f 0.1 -b 20 -p 1 --no-schema \
  --kafka-config ../../config/kafka_edge.properties \
  --registry-config ../../config/registry_edge.properties

# Palo Alto producer
python siem_producer.py paloalto_log \
  -t siem_poc_paloalto_logs -f 0.1 -b 20 -p 1 --no-schema \
  --kafka-config ../../config/kafka_edge.properties \
  --registry-config ../../config/registry_edge.properties

# DNS producer
python siem_producer.py dns_log \
  -t siem_poc_dns_logs -f 0.1 -b 20 -p 1 -k src_ip \
  --kafka-config ../../config/kafka_edge.properties \
  --registry-config ../../config/registry_edge.properties
```

### Streaming apps (run from `demo/siem-emulator/demo/`)

```bash
# FortiGate streaming app
python fortigate_streaming_app.py \
  --kafka-config ../../../config/kafka_edge.properties \
  --registry-config ../../../config/registry_edge.properties \
  --schema-dir ./schemas/ \
  --source-topic siem_poc_fortigate_logs

# Palo Alto streaming app
python paloalto_streaming_app.py \
  --kafka-config ../../../config/kafka_edge.properties \
  --registry-config ../../../config/registry_edge.properties \
  --schema-dir ./schemas/ \
  --source-topic siem_poc_paloalto_logs

# DNS streaming app
python dns_streaming_app.py \
  --kafka-config ../../../config/kafka_edge.properties \
  --registry-config ../../../config/registry_edge.properties \
  --schema-dir ./schemas/ \
  --source-topic siem_poc_dns_logs \
  --window-seconds 300
```
