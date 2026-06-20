# Edge ↔ Hub Confluent Platform Demo - Deployment Guide

Two independent Confluent Platform clusters (Edge and Hub) deployed across two
AWS EKS clusters via Confluent for Kubernetes (CfK), with Cluster Linking and
Schema Linking replicating data from Edge to Hub.

### Versions

| Component | Version | Image |
|-----------|---------|-------|
| Confluent Platform | **8.2.1** | `cp-server` / `cp-schema-registry` / `cp-server-connect:8.2.1` |
| Confluent for Kubernetes (operator) | **3.2.0** | `confluent-init-container:3.2.0` |
| Control Center (next-gen) | **2.5.0** | `cp-enterprise-control-center-next-gen:2.5.0` |
| C3 bundled Prometheus / Alertmanager | **2.5.0** | `cp-enterprise-prometheus` / `cp-enterprise-alertmanager:2.5.0` |
| Splunk connector | **2.2.6** | `splunk/kafka-connect-splunk` installed into Connect from Confluent Hub |

```
EKS Cluster A - cp-edge (eu-west-2a)         EKS Cluster B - cp-hub (eu-west-2a)
┌───────────────────────────────────────┐   ┌─────────────────────────────────────────────┐
│ Controller nodes (m5.large ×3)        │   │ Controller nodes (m5.large ×3)              │
│   └─▶3× KRaft controller              │   │   └─▶3× KRaft controller                    │
│ Broker nodes (m5.xlarge ×3)           │   │ Broker nodes (m5.xlarge ×3)                 │
│   ├─▶3× Kafka broker (1 TB gp3 each)  │   │   ├─▶3× Kafka broker (1 TB gp3 each)        │
│   │     + embedded REST Proxy (8090)  │   │   │     + embedded REST Proxy (8090)        │
│   └─▶2× Schema Registry (8081, HTTPS) │   │   ├─▶2× Schema Registry (8081, HTTPS)       │
│   └─▶1× Control Center (edge.cluster) │   │   ├─▶1× Kafka Connect (8083)                │
│                                       │   │   │    └─▶Splunk plugin v2.2.6              │
│                                       │   │   └─▶1× Control Center (hub.cluster, 9021)  │
│                                       │   │        └─▶bundled Prometheus + Alertmanager │
│                                       │   |                                             |
│ External: SASL_SSL via NLB-per-broker │   │ Auth: SASL/PLAIN · KRaft ACLs               │
│ Auth: SASL/PLAIN · KRaft ACLs         │   │ External: SASL_SSL via NLB-per-broker       │
│ Monitoring: Prometheus ──▶ Hub        │   │ Monitoring: Prometheus + Grafana            │
│    (no local Grafana)                 │   │   (single Grafana — both clusters)          │
└─────────────────┬─────────────────────┘   └──────────────────────▲──────────────────────┘
                  │                                                │
                  │ Cluster Link (topics) + Schema Link (subjects) │
                  └────────────────────────────────────────────────┘
                   Edge ──▶ Hub (SASL_SSL, shared CA, NLB)

  Two C3 instances (edge.cluster / hub.cluster) each monitor their own cluster.
  ONE Grafana (on Hub): Edge Prometheus remote-writes to Hub, so a single
  Grafana shows both clusters. CoreDNS rewrites (scripts/06-cluster-dns.sh)
  resolve the cross-cluster *.kafka.demo names for Cluster/Schema Linking.
```

---

## Prerequisites

### Tools (Mac)

```bash
brew install cfssl                     # certificate generation
brew install helm                      # CfK operator
brew install awscli                    # AWS CLI (needed to auth kubectl to EKS)
brew install --cask temurin            # JDK for keytool (truststore)
brew tap hashicorp/tap
brew install hashicorp/tap/terraform   # infrastructure provisioning
brew install jq                        # JSON parsing in helper scripts
brew install --cask session-manager-plugin  # SSM shell access to producer EC2
brew install kubernetes-cli            # kubectl
```

Verify:
```bash
cfssl version
cfssljson --version
helm version
keytool -help 2>&1 | head -1
kubectl version --client
aws --version
terraform version
jq --version
```

> **Tip:** `scripts/00-preflight.sh` automates these checks (CLIs, AWS auth,
> and - once the clusters exist - node readiness, the `role=` node labels, and a
> capacity sanity check). Run it before each major step:
> ```bash
> EDGE_CTX=edge HUB_CTX=hub bash scripts/00-preflight.sh
> ```

### AWS credentials

Terraform and the AWS CLI both use the same credential chain. The simplest
approach for a PoC is a named profile:

```bash
aws configure --profile cp-poc
# AWS Access Key ID:     <your key>
# AWS Secret Access Key: <your secret>
# Default region:        eu-west-2
# Default output format: json

# Verify
aws sts get-caller-identity --profile cp-poc
```

Set the profile for the rest of the session:

```bash
export AWS_PROFILE=cp-poc
```

### IAM Permissions

Your AWS user needs the following permissions to provision all infrastructure. Ask your AWS admin to attach these **managed policies**:

- **`AmazonVPCFullAccess`** — VPC, subnets, security groups, NAT gateway, route tables
- **`AmazonEC2FullAccess`** — EC2 instances, node groups, EBS volumes, launch templates
- **`IAMFullAccess`** — IAM role and policy creation
- **`CloudWatchLogsFullAccess`** — EKS cluster logging

Plus this **custom inline policy** for EKS-specific actions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "eks:CreateCluster",
        "eks:DescribeCluster",
        "eks:ListClusters",
        "eks:DeleteCluster",
        "eks:UpdateCluster",
        "eks:TagResource",
        "eks:CreateNodegroup",
        "eks:DescribeNodegroup",
        "eks:DeleteNodegroup",
        "eks:ListNodegroups",
        "eks:UpdateNodegroupVersion",
        "eks:DescribeUpdate",
        "eks:CreateAddon",
        "eks:DescribeAddon",
        "eks:DeleteAddon",
        "eks:ListAddons",
        "ec2:*",
        "iam:CreateRole",
        "iam:PutRolePolicy",
        "iam:AttachRolePolicy",
        "iam:GetRole",
        "iam:PassRole",
        "iam:CreateInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "ssm:StartSession",
        "ssm:TerminateSession",
        "ssm:ResumeSession",
        "ssm:DescribeSessions",
        "ssm:GetConnectionStatus",
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
        "ec2messages:AcknowledgeMessage",
        "ec2messages:DeleteMessage",
        "ec2messages:FailMessage",
        "ec2messages:GetEndpoint",
        "ec2messages:GetMessages",
        "ec2messages:SendReply"
      ],
      "Resource": "*"
    }
  ]
}
```

If your organization restricts `IAMFullAccess`, ask for these specific IAM permissions instead:
- `iam:CreateRole`
- `iam:PutRolePolicy`
- `iam:AttachRolePolicy`
- `iam:GetRole`
- `iam:PassRole`
- `iam:CreateInstanceProfile`
- `iam:AddRoleToInstanceProfile`

### Helm repos

```bash
helm repo add confluentinc https://packages.confluent.io/helm
helm repo update
```

---

## Step 0 - Provision EKS Infrastructure with Terraform

> **Do this before anything else.** The Terraform creates the VPC, two EKS
> clusters (`cp-edge` and `cp-hub`), node groups, IAM roles, EBS CSI add-on,
> and the `gp3` StorageClass.

Make sure to replace `your_email@example.com` with your actual email address before running the apply command.

```bash
cd terraform

terraform init
terraform plan -var="owner_email=your_email@example.com" # review what will be created
terraform apply -auto-approve -var="owner_email=your_email@example.com"  # ← replace with your email; takes ~15–20 minutes
```

### What Terraform creates

| Resource | Details |
|----------|---------|
| VPC | `10.0.0.0/16` |
| Public subnet | `10.0.0.0/24` (`eu-west-2a`) - NLBs attach here |
| Private subnet | `10.0.1.0/24` (`eu-west-2a`) - all EKS nodes live here |
| Private subnet B | `10.0.2.0/24` (`eu-west-2b`) - **empty**, only present because EKS requires cluster subnets to span ≥2 AZs. No nodes/EBS land here, so the workload stays single-AZ |
| NAT Gateway | Allows nodes to pull images / SSM reachability for producer host |
| EKS cluster `cp-edge` | Kubernetes 1.36, public+private endpoint |
| EKS cluster `cp-hub` | Kubernetes 1.36, public+private endpoint |
| Node group `broker` (×2) | 3 × `m5.xlarge` (4 vCPU / 16 GB) per cluster |
| Node group `controller` (×2) | 3 × `m5.large` (2 vCPU / 8 GB) per cluster |
| EBS CSI add-on (×2) | Enables dynamic EBS volume provisioning |
| StorageClass `gp3` (×2) | Default SC for 1 Ti broker data volumes |
| IAM roles | Cluster role + node role with ELB + EBS permissions |
| EC2 `producer-host` | `t3.medium`, private subnet, no public IP — runs Python producers/consumers |
| IAM role + instance profile | `AmazonSSMManagedInstanceCore` for SSM access |

> **Node sizing note:** Broker nodes are `m5.xlarge` (4 vCPU / 16 GB) rather
> than the minimum spec. This leaves ~8 GB headroom for the OS, daemonsets, and
> JVM overhead on top of the 8 GB pod request. The 1 TB Kafka data EBS volumes
> are provisioned separately by the CSI driver - they are **not** the node's
> root disk.
>
> **CPU request caveat:** Pod CPU *requests* are set below the node's vCPU count
> (broker `2500m` on a 4-vCPU node, controller `1500m` on a 2-vCPU node) because
> EKS reserves ~80–100m per node for the kubelet/system. Requesting the full
> vCPU count (`4` / `2`) leaves pods permanently `Pending`. Limits still burst to
> the full vCPU count. Schema Registry and Control Center are pinned to the
> broker node group (via `nodeSelector: role=broker`) - an `m5.large` controller
> node cannot fit both a KRaft controller and a 2-CPU SR/C3 pod.

### Connect to the producer host via SSM

After `terraform apply`, Terraform prints the instance ID and the ready-to-run
connect command:

```
producer_host_instance_id    = "i-0abc1234def56789"
producer_host_connect_command = "aws ssm start-session --target i-0abc1234def56789 --region eu-west-2"
```

**Open a shell on the producer host:**

```bash
# Copy the exact command from terraform output, or:
INSTANCE_ID=$(terraform output -raw producer_host_instance_id)
REGION=$(terraform output -raw aws_region)
aws ssm start-session --target "$INSTANCE_ID" --region "$REGION"
```

You get a bash shell running as `ssm-user`. No key pair, no public IP, no open
inbound ports. Auth is your local AWS CLI credentials (`AWS_PROFILE=cp-poc`).

> **Why this works:** The instance is in the private subnet. The NAT Gateway
> gives it outbound HTTPS to reach the SSM endpoints (`ssm.*`, `ssmmessages.*`,
> `ec2messages.*`). SSM connects inbound through AWS's control plane — no
> inbound security-group rule is needed on the instance.


---

### Point kubectl at the EKS clusters

After `terraform apply` completes, register both clusters in your local
kubeconfig. **This replaces any Docker Desktop / local cluster as the active
context.**

```bash
# Read names and region directly from Terraform state (avoids hardcoding)
EDGE_NAME=$(terraform output -raw edge_cluster_name)
HUB_NAME=$(terraform output -raw hub_cluster_name)

# Register Edge cluster (aliased as "edge" in kubeconfig)
aws eks update-kubeconfig --region "$REGION" --name "$EDGE_NAME" --alias edge

# Register Hub cluster (aliased as "hub" in kubeconfig)
aws eks update-kubeconfig --region "$REGION" --name "$HUB_NAME" --alias hub
```

Verify both contexts exist and point to EKS (not Docker):

```bash
kubectl config get-contexts
# Should show:
#   edge    CpEdgeHub-edge    ...   <AWS account>.gr7.eu-west-2.eks.amazonaws.com
#   hub     CpEdgeHub-hub     ...   <AWS account>.gr7.eu-west-2.eks.amazonaws.com
```

Check that nodes are Ready on both clusters:

```bash
kubectl --context=edge get nodes
kubectl --context=hub  get nodes
# All 6 nodes per cluster should show STATUS=Ready
```

> **Switching back to Docker Desktop later:** Docker Desktop adds its own
> context (usually named `docker-desktop`). To switch back:
> ```bash
> kubectl config use-context docker-desktop
> ```
> To check which context is currently active:
> ```bash
> kubectl config current-context
> ```

Set the context variables used throughout this guide:

```bash
export EDGE_CTX="edge"
export HUB_CTX="hub"
```

---

## kubectl Quick Reference

| Goal | Command |
|------|---------|
| See all contexts | `kubectl config get-contexts` |
| Current context | `kubectl config current-context` |
| Switch to Edge | `kubectl config use-context edge` |
| Switch to Hub | `kubectl config use-context hub` |
| Switch to Docker Desktop | `kubectl config use-context docker-desktop` |
| Run one command against Edge | `kubectl --context=edge <command>` |
| Run one command against Hub | `kubectl --context=hub <command>` |

---

> **Back to repo root:** All steps from here on run from the repository root. If you followed Step 0 from inside `terraform/`, run `cd ..` before continuing.

## Step 1 - Generate TLS Certificates

A single self-signed CA signs certs for both clusters. This lets the Hub verify
Edge certificates using one shared truststore - essential for Cluster Linking.

```bash
bash certs/generate-certs.sh
```

Output:
```
certs/
├── cacerts.pem          ← shared CA certificate
├── rootCAkey.pem        ← shared CA private key
├── edge/
│   ├── kafka-server.pem      ← Edge server cert (fullchain)
│   ├── kafka-server-key.pem  ← Edge server private key
│   ├── cacerts.pem           ← copy of shared CA
│   ├── rootCAkey.pem         ← copy of shared CA key
│   └── truststore.jks        ← JKS for CLI clients
└── hub/
    ├── kafka-server.pem
    ├── kafka-server-key.pem
    ├── cacerts.pem
    ├── rootCAkey.pem
    └── truststore.jks
```

The Edge server certificate covers:
- `*.edge.kafka.demo` - external broker FQDNs
- `*.kafka.cp-edge.svc.cluster.local` - internal K8s service FQDNs
- `*.schemaregistry.cp-edge.svc.cluster.local` - Schema Registry

---

## Step 2 - Install CfK Operator

Install **Confluent for Kubernetes 3.2.x** on **both** EKS clusters. The
operator must be running before any platform CRDs are applied.

```bash
# Edge
kubectl --context="${EDGE_CTX}" create namespace cp-edge
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --kube-context="${EDGE_CTX}" \
  --namespace cp-edge

# Hub
kubectl --context="${HUB_CTX}" create namespace cp-hub
helm upgrade --install confluent-operator confluentinc/confluent-for-kubernetes \
  --kube-context="${HUB_CTX}" \
  --namespace cp-hub
```

> **KRaft note:** Confluent Platform 8.x is KRaft-only (ZooKeeper is removed), so
> the old `--set kRaftEnabled=true` flag is no longer required in CfK 3.2.x.

Wait for the operator pod, then confirm it's the 3.2.x line:

```bash
kubectl --context="${EDGE_CTX}" rollout status deploy/confluent-operator -n cp-edge
kubectl --context="${HUB_CTX}"  rollout status deploy/confluent-operator -n cp-hub

# Verify operator version (expect 3.2.x)
helm --kube-context="${EDGE_CTX}" list -n cp-edge
kubectl --context="${EDGE_CTX}" get deploy confluent-operator -n cp-edge \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

---

## Step 3 - Create Kubernetes Secrets

### Edge

```bash
KUBECTL_CONTEXT="${EDGE_CTX}" bash scripts/01-create-secrets-edge.sh
```

This creates three secrets in `cp-edge`:

| Secret | Contents |
|--------|---------|
| `tls-kafka` | `fullchain.pem`, `cacerts.pem`, `privkey.pem` |
| `ca-pair-sslcerts` | `ca.crt`, `ca.key` |
| `credential` | `plain.txt`, `plain-users.json`, `basic.txt` |

### Hub

```bash
KUBECTL_CONTEXT="${HUB_CTX}" bash scripts/02-create-secrets-hub.sh
```

This creates the following secrets in `cp-hub`:

| Secret | Contents |
|--------|---------|
| `tls-kafka` | Hub server cert + CA |
| `ca-pair-sslcerts` | Hub CA key-pair |
| `credential` | Hub SASL credentials |
| `edge-ca-cert` | Edge CA cert (for ClusterLink TLS verification) |
| `edge-cluster-link-credential` | `cluster-link` user credentials for Edge |
| `edge-credential` | `admin` credentials for Edge (legacy; unused by next-gen C3) |
| `prometheus-credentials` | next-gen C3 - bundled Prometheus server basic-auth users |
| `alertmanager-credentials` | next-gen C3 - bundled Alertmanager server basic-auth users |
| `prometheus-client-creds` | next-gen C3 - client creds used by components' `metricsClient` + C3 |
| `alertmanager-client-creds` | next-gen C3 - client creds C3 uses to read Alertmanager |

---

## Step 4 - Handle Confluent Platform License

The CfK resources are configured to use a license by default. Follow one of these paths:

### Path A: You have a Confluent Platform license

**1. Place your JWT license token in the repo root:**

```bash
cat > license.txt <<'EOF'
<your-jwt-license-token-here>
EOF
```

**2. Run the license installation script:**

```bash
EDGE_CTX="${EDGE_CTX}" HUB_CTX="${HUB_CTX}" bash scripts/07-install-license.sh
```

This script:
- Validates the JWT format
- Creates `confluent-license` secrets in both clusters (`cp-edge` and `cp-hub`)

> **Run this before Step 5 and Step 6.**  The license secret will be present when the CRDs are first applied — no reapply needed.

### Path B: You don't have a license (trial mode)

**Comment out the license blocks** in these files before deploying:
- `edge/01-kraftcontroller.yaml`
- `edge/02-kafka.yaml`
- `edge/03-schemaregistry.yaml`
- `hub/01-kraftcontroller.yaml`
- `hub/02-kafka.yaml`
- `hub/03-schemaregistry.yaml`

In each file, comment out:
```yaml
# license:
#   secretRef: confluent-license
```

Clusters will run in **trial mode** (some features have 30-day limits).

Alternatively, run the script without `license.txt` and it will provide clear instructions:

```bash
EDGE_CTX="${EDGE_CTX}" HUB_CTX="${HUB_CTX}" bash scripts/07-install-license.sh
```

---

## Step 5 - Deploy Edge Cluster  

Apply the CRDs in order. Wait for each component before proceeding.

```bash
# KRaft controllers
kubectl --context="${EDGE_CTX}" apply -f edge/01-kraftcontroller.yaml

# Wait for all 3 KRaft pods to be Running (operator creates them asynchronously — watch until they appear)
kubectl --context="${EDGE_CTX}" get pods -n cp-edge -w
# Once all 3 kraftcontroller pods show Running/Ready, Ctrl-C and proceed.

# Kafka brokers + KafkaRestClass
kubectl --context="${EDGE_CTX}" apply -f edge/02-kafka.yaml

# Wait for all 3 broker pods to be Running
kubectl --context="${EDGE_CTX}" get pods -n cp-edge -w

# Schema Registry
kubectl --context="${EDGE_CTX}" apply -f edge/03-schemaregistry.yaml

# Wait for all 2 schema registry pods to be Running
kubectl --context="${EDGE_CTX}" get pods -n cp-edge -w

# Topics (21 SIEM topics - created via KafkaRestClass once brokers are ready)
kubectl --context="${EDGE_CTX}" apply -f edge/04-topics.yaml
```

### Verify Edge

```bash
kubectl --context="${EDGE_CTX}" get pods -n cp-edge
kubectl --context="${EDGE_CTX}" get kafka,kraftcontroller,schemaregistry -n cp-edge
```

Expected output:
```
NAME                          READY   STATUS    RESTARTS
kraftcontroller-0             1/1     Running   0
kraftcontroller-1             1/1     Running   0
kraftcontroller-2             1/1     Running   0
kafka-0                       1/1     Running   0
kafka-1                       1/1     Running   0
kafka-2                       1/1     Running   0
schemaregistry-0              1/1     Running   0
schemaregistry-1              1/1     Running   0
```

---

## Step 6 - Deploy Hub Cluster

Same sequence as Edge:

```bash
kubectl --context="${HUB_CTX}" apply -f hub/01-kraftcontroller.yaml
kubectl --context="${HUB_CTX}" get pods -n cp-hub -w

kubectl --context="${HUB_CTX}" apply -f hub/02-kafka.yaml
kubectl --context="${HUB_CTX}" get pods -n cp-hub -w

kubectl --context="${HUB_CTX}" apply -f hub/03-schemaregistry.yaml
kubectl --context="${HUB_CTX}" get pods -n cp-hub -w
```

### Kafka Connect with the Splunk Sink plugin (Hub only)

The Hub runs a single-node Kafka Connect cluster. The
[Splunk connector](https://github.com/splunk/kafka-connect-splunk)
(`splunk/kafka-connect-splunk` **v2.2.6**) is baked into the Connect image at
build time (`spec.build.onDemand` pulls it from Confluent Hub - nodes reach it
via the NAT gateway). Only the plugin JAR is installed here; the **connector
instance is created later, manually, in Control Center** (Step 11).

```bash
kubectl --context="${HUB_CTX}" apply -f hub/04-connect.yaml

# First start is slow - the init container downloads + installs the plugin.
kubectl --context="${HUB_CTX}" wait pod -l app=connect -n cp-hub \
  --for=condition=Ready --timeout=600s

# Confirm the Splunk Sink plugin is present
kubectl --context="${HUB_CTX}" exec -n cp-hub connect-0 -- \
  curl -s http://localhost:8083/connector-plugins | jq -r '.[].class' | grep -i splunk
```

> The Splunk connector (`splunk/kafka-connect-splunk`) is Splunk's open-source
> connector for forwarding Kafka topics to Splunk HEC. No license key required.

---

## Step 7 - Resolve External LB Addresses

CfK creates one NLB per broker on AWS. Wait a few minutes for AWS to provision
them, then run:

```bash
EDGE_CTX="${EDGE_CTX}" HUB_CTX="${HUB_CTX}" bash scripts/04-get-lb-ips.sh
```

Copy the output block into `/etc/hosts` on your Mac:

```bash
sudo nano /etc/hosts
# Paste the # --- Edge cluster --- and # --- Hub cluster --- blocks
```

`/etc/hosts` only accepts IP addresses, so the script resolves each AWS NLB
hostname to its current IP before printing the entries. **These NLB IPs are not
guaranteed to be static** — if AWS recycles them, re-run the script and update
`/etc/hosts`. (The ClusterLink `bootstrapEndpoint`, by contrast, uses the NLB
*hostnames* directly and is resolved in-cluster by CoreDNS — see Step 7.5.)

> **Tip:** If NLBs are pending for more than 5 minutes, check that your EKS node
> IAM role has the `elasticloadbalancing:*` permissions.

---

## Step 7.5 - Configure Cross-Cluster DNS (required for linking)

The `/etc/hosts` entries from Step 7 only work for CLI clients **on your Mac**.
Pods running inside EKS have no such entries, so anything that connects
cross-cluster *from inside a pod* - Cluster Linking (Hub→Edge) and Schema Linking
(Edge→Hub) - cannot resolve the `*.kafka.demo` names and will silently fail to
connect.

This script adds CoreDNS `rewrite` rules so each cluster resolves the *other*
cluster's `*.kafka.demo` FQDNs to the real AWS NLB hostnames (resolvable via the
NAT gateway). The original `.demo` name is preserved for the TLS handshake, so
the server cert SANs still match - no hostname-verification changes needed.

```bash
EDGE_CTX="${EDGE_CTX}" HUB_CTX="${HUB_CTX}" bash scripts/06-cluster-dns.sh
```

Verify resolution from inside a Hub broker pod:

```bash
kubectl --context="${HUB_CTX}" -n cp-hub exec kafka-0 -c kafka -- getent hosts b0.edge.kafka.demo
```

> Re-run this script if you re-provision the NLBs (the rules are idempotent).

---

## Step 8 - Configure Edge ACLs

The `cluster-link` user must have Read access to all topics and the Describe
Cluster privilege on Edge before the ClusterLink resource is applied.

```bash
# First update EDGE_BOOTSTRAP in the script or pass it via env:
EDGE_BOOTSTRAP="edge.kafka.demo:9092" bash scripts/03-edge-acls.sh
```

This grants:
- `cluster-link` → `DescribeCluster`, `Read` + `Describe` on all topics/groups
- `client` → `All` on all topics/groups (demo convenience)

---

## Step 9 - Apply the ClusterLink

**Apply the ClusterLink on the Hub context:**

```bash
kubectl --context="${HUB_CTX}" apply -f linking/01-clusterlink.yaml
kubectl --context="${HUB_CTX}" get clusterlink edge-to-hub -n cp-hub
```

That's the whole step — no file editing required. `linking/01-clusterlink.yaml`
already uses the stable `*.edge.kafka.demo` FQDNs for its `bootstrapEndpoint`,
and the CoreDNS rewrites from Step 7.5 resolve those to the real Edge NLBs from
inside the Hub pods (so the endpoint stays valid even if NLB IPs change).

> If you skipped Step 7.5, the link will fail to connect — the Hub pods can't
> resolve `*.edge.kafka.demo` without the CoreDNS rewrites.

**Optional:** to mirror different topics, edit the `mirrorTopics:` list before
applying:

```yaml
mirrorTopics:
  - name: "your-topic"
    state: ACTIVE
    replicationFactor: 3
```

Check link status:

```bash
kubectl --context="${HUB_CTX}" get clusterlink edge-to-hub -n cp-hub
kubectl --context="${HUB_CTX}" describe clusterlink edge-to-hub -n cp-hub
```

The `READY` condition should turn `True` within ~30 seconds. Mirror topics
appear as read-only topics on Hub:

```bash
kafka-topics --list \
  --bootstrap-server hub.kafka.demo:9092 \
  --command-config scripts/hub-sslcli.properties
```

---

## Step 10 - Configure Schema Linking

Schema Linking is done via Schema Registry REST API (no CfK CRD). The script
configures an Exporter on Edge SR that continuously pushes schemas to Hub SR.

**Export all subjects (default — use this):**

```bash
bash linking/02-schema-exporter.sh
```

> **Optional:** to limit the exporter to specific subjects instead of all, set
> `SUBJECTS` to a comma-separated list. Skip this unless you have a reason to
> restrict it:
>
> ```bash
> SUBJECTS="my-topic-value,my-topic-key" bash linking/02-schema-exporter.sh
> ```

Check exporter status:

```bash
curl -k \
  --cacert certs/cacerts.pem \
  -u admin:admin-secret \
  https://schemaregistry.edge.kafka.demo:8081/exporters/edge-to-hub-exporter/status
```

Verify subjects appear on Hub SR:

```bash
curl -k \
  --cacert certs/cacerts.pem \
  -u admin:admin-secret \
  https://schemaregistry.hub.kafka.demo:8081/subjects
```

---

## Architecture Details

### Cluster topology

| Component | Edge | Hub |
|-----------|------|-----|
| Namespace | `cp-edge` | `cp-hub` |
| KRaft replicas | 3 | 3 |
| Broker replicas | 3 | 3 |
| Schema Registry replicas | 2 | 2 |
| Kafka Connect | - | 1 (Splunk plugin v2.2.6) |
| Control Center | 1 (`edge.cluster`) | 1 (`hub.cluster`) |
| Broker storage | 1 Ti (`gp3`) | 1 Ti (`gp3`) |
| Broker node | `m5.xlarge` (4 vCPU / 16 GB) | `m5.xlarge` (4 vCPU / 16 GB) |
| Broker pod CPU | req `2500m` / limit `4` | req `2500m` / limit `4` |
| Broker pod RAM | 8 Gi | 8 Gi |
| Controller node | `m5.large` (2 vCPU / 8 GB) | `m5.large` (2 vCPU / 8 GB) |
| KRaft storage | 50 Gi | 50 Gi |
| Node placement | brokers→`role=broker`; KRaft→`role=controller`; SR→`role=broker` | same, plus Connect + C3→`role=broker` |
| External listener | SASL_SSL / NLB per broker | SASL_SSL / NLB per broker |
| Internal listener | SASL_PLAINTEXT | SASL_PLAINTEXT |
| Auth | SASL/PLAIN | SASL/PLAIN |
| ACL | KRaft ACL | KRaft ACL |
| Schema Registry | HTTPS (port 8081) | HTTPS (port 8081) |

### Users

| User | Password | Purpose |
|------|----------|---------|
| `kafka` | `kafka-secret` | Internal super-user (inter-broker, controller) |
| `admin` | `admin-secret` | Admin super-user (CLI, REST API, Schema Registry) |
| `client` | `client-secret` | Application user |
| `cluster-link` | `clusterlink-secret` | Cluster Link read access on Edge |

### Listener ports

| Listener | Port | Protocol | TLS |
|----------|------|---------|-----|
| internal | 9071 | SASL_PLAINTEXT | No |
| replication | 9072 | SASL_PLAINTEXT | No |
| external | 9092 | SASL_SSL | Yes |
| controller | 9074 | SASL_PLAINTEXT | No |
| REST proxy | 8090 | HTTPS | Yes |
| Schema Registry | 8081 | HTTPS | Yes |
| Kafka Connect REST (Hub) | 8083 | HTTP | No (cluster-internal only) |
| Control Center UI (Hub) | 9021 | HTTPS | Yes |
| C3 bundled Prometheus (Hub) | 9090 | HTTP + basic auth | No (cluster-internal only) |
| C3 bundled Alertmanager (Hub) | 9093 | HTTP + basic auth | No (cluster-internal only) |

### DNS / external access pattern

```
b0.edge.kafka.demo:9092  →  NLB for kafka-0 pod
b1.edge.kafka.demo:9092  →  NLB for kafka-1 pod
b2.edge.kafka.demo:9092  →  NLB for kafka-2 pod
edge.kafka.demo:9092     →  NLB bootstrap (any broker)
kafka.edge.kafka.demo:8090  → REST proxy NLB
schemaregistry.edge.kafka.demo:8081  → Schema Registry NLB
```

The same pattern applies for `hub.kafka.demo`.

---

## Useful Commands

### Cluster health

```bash
# Pods on Edge
kubectl --context="${EDGE_CTX}" get pods -n cp-edge

# CfK resource status
kubectl --context="${EDGE_CTX}" get kafka,kraftcontroller,schemaregistry -n cp-edge -o wide

# Check a specific Kafka resource
kubectl --context="${EDGE_CTX}" describe kafka kafka -n cp-edge
```

### Topic management

```bash
# List topics on Edge
kafka-topics --list \
  --bootstrap-server edge.kafka.demo:9092 \
  --command-config scripts/edge-sslcli.properties

# Create a topic on Edge
kafka-topics --create \
  --topic my-topic \
  --partitions 6 \
  --replication-factor 3 \
  --bootstrap-server edge.kafka.demo:9092 \
  --command-config scripts/edge-sslcli.properties

# List topics on Hub (includes mirrored topics)
kafka-topics --list \
  --bootstrap-server hub.kafka.demo:9092 \
  --command-config scripts/hub-sslcli.properties
```

### ACL management

```bash
# List ACLs on Edge
kafka-acls \
  --bootstrap-server edge.kafka.demo:9092 \
  --command-config scripts/edge-sslcli.properties \
  --list

# Add ACL for client user on a specific topic
kafka-acls \
  --bootstrap-server edge.kafka.demo:9092 \
  --command-config scripts/edge-sslcli.properties \
  --add \
  --allow-principal "User:client" \
  --operation All \
  --topic "my-topic"
```

### REST API (Kafka Admin v3)

```bash
# List clusters
curl -k --cacert certs/cacerts.pem \
  -u admin:admin-secret \
  https://kafka.edge.kafka.demo:8090/kafka/v3/clusters

# The Kafka cluster ID is assigned randomly by Kafka - it is NOT the KRaft
# `clusterID` from the CRD. Fetch it from the REST API:
CLUSTER_ID=$(curl -sk --cacert certs/cacerts.pem -u admin:admin-secret \
  https://kafka.edge.kafka.demo:8090/kafka/v3/clusters | jq -r '.data[0].cluster_id')

# List topics
curl -k --cacert certs/cacerts.pem \
  -u admin:admin-secret \
  "https://kafka.edge.kafka.demo:8090/kafka/v3/clusters/${CLUSTER_ID}/topics"
```

### Cluster Link management

```bash
# Check link status
kubectl --context="${HUB_CTX}" get clusterlink edge-to-hub -n cp-hub

# List mirrors via REST on Hub (fetch the Hub's randomly-assigned cluster ID)
CLUSTER_ID=$(curl -sk --cacert certs/cacerts.pem -u admin:admin-secret \
  https://kafka.hub.kafka.demo:8090/kafka/v3/clusters | jq -r '.data[0].cluster_id')
curl -k --cacert certs/cacerts.pem \
  -u admin:admin-secret \
  "https://kafka.hub.kafka.demo:8090/kafka/v3/clusters/${CLUSTER_ID}/links"

# List mirror topics
curl -k --cacert certs/cacerts.pem \
  -u admin:admin-secret \
  "https://kafka.hub.kafka.demo:8090/kafka/v3/clusters/${CLUSTER_ID}/links/edge-to-hub/mirrors"
```

### Schema Registry

```bash
# List subjects on Edge
curl -k --cacert certs/cacerts.pem \
  -u admin:admin-secret \
  https://schemaregistry.edge.kafka.demo:8081/subjects

# Register a schema on Edge
curl -k --cacert certs/cacerts.pem \
  -u admin:admin-secret \
  -X POST \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  --data '{"schema":"{\"type\":\"record\",\"name\":\"Test\",\"fields\":[{\"name\":\"id\",\"type\":\"int\"}]}"}' \
  https://schemaregistry.edge.kafka.demo:8081/subjects/my-topic-value/versions

# Verify it appeared on Hub (after exporter sync)
curl -k --cacert certs/cacerts.pem \
  -u admin:admin-secret \
  https://schemaregistry.hub.kafka.demo:8081/subjects
```

---

## Monitoring

### What's included

| Component | Where | How to access |
|-----------|-------|--------------|
| **Control Center** | Both clusters (`cp-hub` = `hub.cluster`, `cp-edge` = `edge.cluster`) | `https://controlcenter.hub.kafka.demo:9021` / `https://controlcenter.edge.kafka.demo:9021` |
| **Kafka Connect** | Hub cluster, namespace `cp-hub` | Managed from Hub C3; REST `http://connect.cp-hub.svc.cluster.local:8083` (in-cluster) |
| **Grafana (single)** | Hub cluster, namespace `monitoring` | One NLB — shows both clusters (Step 12) |

This demo has **two** monitoring layers, by design:

- **Control Center (per cluster).** Next-gen C3 2.5.0 is single-cluster — each
  instance monitors only the Kafka cluster it's attached to, so there are two:
  **`hub.cluster`** (also manages Connect / the Splunk connector) and
  **`edge.cluster`**. Each bundles its own Prometheus + Alertmanager and ingests
  metrics via `dependencies.metricsClient`. The `name:` field sets the C3 instance
  identity (internal-topic prefix), not the Kafka cluster display name. The display
  name is set via `configOverrides.server: confluent.controlcenter.kafka.<Name>.bootstrap.servers`
  (dot-free token — `Edge` renders as "Edge" in the UI).
- **Grafana (single pane).** A `kube-prometheus-stack` runs on each cluster, but
  only **Hub** keeps a Grafana. Edge's Prometheus **remote-writes** to Hub's, so
  one Grafana covers both clusters — switch with the dashboard `Namespace`
  variable (`cp-edge` / `cp-hub`).

### Step 11 - Deploy Control Center (Hub)

C3 manages the Connect cluster from Step 6, so complete **Step 6 (Deploy Hub Cluster)**
first. (It no longer reaches Edge, so the Edge NLBs / Step 7.5 are not required
for C3 itself.)

```bash
kubectl --context="${HUB_CTX}" apply -f hub/05-controlcenter.yaml

# The pod runs three containers (C3 + Prometheus + Alertmanager) - give it time.
kubectl --context="${HUB_CTX}" get pods -n cp-hub -w
```

**Access the UI.** The C3 web UI is on port 9021 (HTTPS), exposed via its own
NLB (`controlcenter-bootstrap-lb`). Resolve it to an `/etc/hosts` entry like the
other components, then open it in your browser:

```bash
# Resolve the C3 NLB to an IP and print the /etc/hosts line:
HOST=$(kubectl --context="${HUB_CTX}" get svc controlcenter-bootstrap-lb -n cp-hub \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "$(dig +short "$HOST" | grep -E '^[0-9.]+$' | head -1)   controlcenter.hub.kafka.demo"

# Add that line to /etc/hosts, then open:
#   https://controlcenter.hub.kafka.demo:9021
```

> **Fallback (no /etc/hosts edit):** `kubectl --context="${HUB_CTX}" port-forward
> -n cp-hub svc/controlcenter 9021:9021`, then open `https://localhost:9021`.

(Accept the self-signed cert warning.)

**Add the Splunk connector** from the UI: open the **`connect`** cluster →
**Add connector → Splunk Sink Connector**, then fill in the Splunk HEC settings
(`splunk.hec.uri`, `splunk.hec.token`, source topics). The plugin is already
installed (Step 6); C3 only creates the running connector instance.

### Step 11b - Deploy Control Center (Edge)

The Edge cluster runs its own C3 (`name: edge.cluster`). It requires the Edge
metrics secrets (created by `scripts/01-create-secrets-edge.sh`) and the Edge
components' `metricsClient` dependency — both already in place if you ran Step 3
and Step 5 with the current manifests.

> **Re-running Step 3/5?** If you deployed Edge *before* these C3 additions,
> re-run `scripts/01-create-secrets-edge.sh` (adds the 4 metrics secrets) and
> re-apply `edge/01-kraftcontroller.yaml`, `edge/02-kafka.yaml`,
> `edge/03-schemaregistry.yaml` (adds `metricsClient`). The operator rolls the
> pods automatically.

```bash
kubectl --context="${EDGE_CTX}" apply -f edge/05-controlcenter.yaml
kubectl --context="${EDGE_CTX}" get pods -n cp-edge -w   # wait for controlcenter-0 Ready
```

Access it the same way as Hub, via its NLB:

```bash
HOST=$(kubectl --context="${EDGE_CTX}" get svc controlcenter-bootstrap-lb -n cp-edge \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo "$(dig +short "$HOST" | grep -E '^[0-9.]+$' | head -1)   controlcenter.edge.kafka.demo"
# Add to /etc/hosts, then open https://controlcenter.edge.kafka.demo:9021
```

### Step 12 - Deploy Prometheus + the single Grafana

Installs `kube-prometheus-stack` on both clusters: Hub gets the central
Prometheus (remote-write receiver) **and the only Grafana**; Edge gets a
Prometheus that remote-writes to Hub. Takes ~10 minutes.

```bash
EDGE_CTX="${EDGE_CTX}" HUB_CTX="${HUB_CTX}" \
  bash monitoring/01-install-prometheus-stack.sh
```

Apply the PodMonitor (scrapes the CfK JMX exporter on port `prometheus`/7778) on
**both** clusters:

```bash
kubectl --context="${EDGE_CTX}" apply -f monitoring/02-podmonitors.yaml -n cp-edge
kubectl --context="${HUB_CTX}"  apply -f monitoring/02-podmonitors.yaml -n cp-hub
```

Get the (single) Grafana NLB address — **on Hub** — and log in with `admin` / `prom-operator`:

```bash
kubectl --context="${HUB_CTX}" get svc -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
```

### Step 13 - Import Confluent Grafana Dashboards

Import the CfK-adapted dashboards (vendored in `monitoring/grafana-dashboards/`)
into the Hub Grafana — one import covers both clusters:

```bash
CTX="${HUB_CTX}" bash monitoring/04-import-dashboards.sh
```

In Grafana, open **Kafka cluster**, set the **`Namespace`** variable
(`cp-edge` / `cp-hub`), Pod = `All`, time range = *Last 15 minutes*.

> **Why these dashboards (not the stock ones):** CfK's JMX exporter emits metrics
> as `kafka_server_replicamanager_value{name="UnderReplicatedPartitions"}`
> (attribute as a label), but the stock Confluent dashboards expect *flattened*
> names like `kafka_server_replicamanager_underreplicatedpartitions`. The
> JMX-exporter `rules` in `edge/01-kraftcontroller.yaml` / `edge/02-kafka.yaml`
> (and hub equivalents) flatten the names, and the vendored dashboards key on
> `namespace`/`pod`. See [`monitoring/README.md`](monitoring/README.md) for details.

---

## Python Client Configuration

The `config/` directory contains ready-to-use librdkafka property files for
`confluent-kafka-python`. They are pre-filled with the deployment's FQDNs and
credentials.

| File | Cluster | Used for |
|------|---------|---------|
| `config/kafka_edge.properties` | Edge | Producer / Consumer bootstrap |
| `config/kafka_hub.properties` | Hub | Producer / Consumer bootstrap |
| `config/registry_edge.properties` | Edge SR | Schema serialization |
| `config/registry_hub.properties` | Hub SR | Schema serialization |

All files assume scripts run from the **repo root** (so `ssl.ca.location=certs/cacerts.pem` resolves correctly). Adjust `CA_CERT_PATH` if running from a different directory.

### Reading configs in Python

```python
import configparser
from confluent_kafka import Producer, Consumer
from confluent_kafka.schema_registry import SchemaRegistryClient

def load_config(path: str) -> dict:
    parser = configparser.ConfigParser()
    # configparser requires a section header; fake one for flat property files
    with open(path) as f:
        content = "[DEFAULT]\n" + f.read()
    parser.read_string(content)
    # Strip comment lines and return as plain dict
    return {k: v for k, v in parser["DEFAULT"].items() if not k.startswith("#")}

# Kafka producer → Edge
producer = Producer(load_config("config/kafka_edge.properties"))

# Schema Registry → Edge
sr_conf = load_config("config/registry_edge.properties")
sr_client = SchemaRegistryClient({
    "url": sr_conf["schema.registry.url"],
    "basic.auth.user.info": sr_conf["schema.registry.basic.auth.user.info"],
    "ssl.ca.location": sr_conf["schema.registry.ssl.ca.location"],
})
```

### Regenerating configs

If FQDNs or credentials change, regenerate all four files:

```bash
bash scripts/05-generate-client-configs.sh

# Or override specific values:
KAFKA_USER=myapp KAFKA_PASS=mypassword bash scripts/05-generate-client-configs.sh
```

---

## Adding Mirror Topics After Initial Setup

Edit `linking/01-clusterlink.yaml`, add entries to the `mirrorTopics:` list, then:

```bash
kubectl --context="${HUB_CTX}" apply -f linking/01-clusterlink.yaml
```

---

### Step 14 — Deploy the SIEM producers and streaming apps on the Edge EC2

#### Access the EC2 instance

```bash
# Copy the exact command from terraform output, or:
INSTANCE_ID=$(terraform output -raw producer_host_instance_id)
REGION=$(terraform output -raw aws_region)
aws ssm start-session --target "$INSTANCE_ID" --region "$REGION"
```

You get a bash shell running as `ssm-user`. No key pair, no public IP, no open
inbound ports. Auth is your local AWS CLI credentials (`AWS_PROFILE=cp-poc`).

> **Why this works:** The instance is in the private subnet. The NAT Gateway
> gives it outbound HTTPS to reach the SSM endpoints (`ssm.*`, `ssmmessages.*`,
> `ec2messages.*`). SSM connects inbound through AWS's control plane — no
> inbound security-group rule is needed on the instance.


#### Deploy the services

Once on the instance, follow **[demo/README.md](demo/README.md)** to clone the SIEM emulator repo, install the Python virtual environment, and register all producers and streaming applications as persistent systemd services that target the Edge cluster.

---

## Demo — Simulating a Network Failure (Cluster Link pause/resume)

Use `linking/03-clusterlink-ctl.sh` to pause and resume the `edge-to-hub` Cluster
Link from your Mac. This simulates a network outage between Edge and Hub:

- **During pause:** the 21 mirror topics on Hub stop replicating. Consumer lag
  accumulates on Edge while the Python producers keep writing — demonstrating
  that Edge operates fully independently.
- **After resume:** replication restarts automatically from the last committed
  offset. Watch the lag drain to zero — no data is lost.

```bash
# Check current link and mirror topic state
bash linking/03-clusterlink-ctl.sh status

# Simulate network failure — pause the entire link
bash linking/03-clusterlink-ctl.sh pause

# ... show Edge producers still writing, lag growing in C3 or Grafana ...

# Restore the link — replication catches up automatically
bash linking/03-clusterlink-ctl.sh resume
```

The `status` output prints a table of mirror topic name / state / accumulated lag.
The `resume` command prints the same table immediately after resuming — refresh it
after ~30 seconds to see lag draining.

> The script uses the Kafka REST Proxy v3 Admin API on Hub
> (`https://kafka.hub.kafka.demo:8090`). Make sure the Hub REST proxy NLB is in
> `/etc/hosts` (Step 7) before running it from your Mac.

---

## Teardown

### Step A — Delete PVCs (must be done while the clusters are still up)

The EBS volumes provisioned by the CSI driver are **not** reclaimed automatically
when the cluster is deleted. Delete the PVCs first so Kubernetes can release and
delete the underlying EBS volumes before Terraform removes the clusters.

```bash
kubectl --context="${EDGE_CTX}" delete pvc --all -n cp-edge
kubectl --context="${HUB_CTX}"  delete pvc --all -n cp-hub

# Wait for all PVCs to disappear (and EBS volumes to be deleted) before continuing
kubectl --context="${EDGE_CTX}" get pvc -n cp-edge -w
kubectl --context="${HUB_CTX}"  get pvc -n cp-hub  -w
```

### Step B — Delete CP components and operators

```bash
# Hub - CP components (delete top-down: dependents first)
kubectl --context="${HUB_CTX}" delete -f hub/05-controlcenter.yaml
kubectl --context="${HUB_CTX}" delete -f linking/01-clusterlink.yaml
kubectl --context="${HUB_CTX}" delete -f hub/04-connect.yaml
kubectl --context="${HUB_CTX}" delete -f hub/03-schemaregistry.yaml
kubectl --context="${HUB_CTX}" delete -f hub/02-kafka.yaml
kubectl --context="${HUB_CTX}" delete -f hub/01-kraftcontroller.yaml

# Edge - CP components
kubectl --context="${EDGE_CTX}" delete -f edge/05-controlcenter.yaml
kubectl --context="${EDGE_CTX}" delete -f edge/04-topics.yaml
kubectl --context="${EDGE_CTX}" delete -f edge/03-schemaregistry.yaml
kubectl --context="${EDGE_CTX}" delete -f edge/02-kafka.yaml
kubectl --context="${EDGE_CTX}" delete -f edge/01-kraftcontroller.yaml

# Monitoring stacks (delete the Hub remote-write NLB first — it's applied separately)
kubectl --context="${HUB_CTX}" delete svc prometheus-remote-write -n monitoring --ignore-not-found
helm --kube-context="${EDGE_CTX}" uninstall kube-prometheus-stack -n monitoring
helm --kube-context="${HUB_CTX}"  uninstall kube-prometheus-stack -n monitoring

# CfK operators
helm --kube-context="${EDGE_CTX}" uninstall confluent-operator -n cp-edge
helm --kube-context="${HUB_CTX}"  uninstall confluent-operator -n cp-hub
```

### Step C — Destroy AWS infrastructure

```bash
cd terraform && terraform destroy
```
