## Lessons Learned

This section captures operational insights, gotchas, and best practices discovered while running this PoC. They apply to any future CP 8.x / CFK 3.x / KRaft deployment.

---

### Diagnosing cluster imbalance — triage order

Before touching any config, work the imbalance in this order. Most "imbalance" findings in a lightly-loaded cluster turn out to be cosmetic, and acting on them causes more churn than the skew itself.

1. **Always convert relative gaps to absolute numbers first.** A 40% relative gap at 1.7% disk fill is not the same problem as a 40% gap at 60% fill. The same applies to throughput (MB/s vs KB/s) and leader counts. Get real bytes with `kafka-log-dirs --describe` divided by the `dataVolumeCapacity` from the Kafka CRD; get throughput from C3 or the JMX metrics — then decide.
   - Watch for arithmetic drift in your own reporting: in this PoC the disk gap was first stated as "40%" but the actual log-dir numbers (18.3 / 20.0 / 14.2 GB) put broker 2 only ~22–29% below the other two. The headline number is what triggers escalation, so compute it from ground truth.
2. **Separate the dimensions — they have different root causes and different fixes.**
   - **Leader count skew** → affects CPU and client read/egress (fetches are served by leaders). Driven by partition leadership assignment.
   - **Throughput (read/write) skew** → follows leadership almost exactly; it is the leader skew expressed in bytes/sec, not an independent problem. In this PoC throughput split (~39.5 / 36.8 / 23.7%) tracked the total leader split (38.8 / 34.8 / 26.4%) within a couple of points.
   - **Disk skew** → tracks replica (data) placement, not leadership. Both leaders and followers retain the full local log, so disk footprint is about replica count/size, not who leads.
3. **Identify the dominant contributor before generalizing.** In this PoC, user-topic leaders were balanced (37/36/35) and `__consumer_offsets` was balanced (50/50/50). The entire skew came from internal/system topics, dominated by `_confluent-link-metadata` (29/21/0 — broker 2 had zero leaders).
4. **Check the relevant threshold before calling it a problem.** Leader and network distribution are non-triggering goals (SBC won't act on them alone); disk distribution triggers only above ~20% relative variance AND ~20% absolute fill. See the SBC goal-mechanics section. At PoC absolutes (~1.7% disk, ~0.17 MB/s), all three dimensions were below every actionable threshold → cosmetic, SBC correctly idle.

**Leader count ≠ byte load.** Balanced leader counts do not guarantee balanced throughput. A few high-volume partitions on two brokers can skew byte load even with equal leader counts. In a hub+edge topology, Cluster Linking mirror traffic follows the same leaders that dominate `_confluent-link-metadata`, concentrating load on those brokers. Use `kafka-log-dirs` plus per-topic partition size to identify hot partitions when byte load diverges from leader count.

---

### Adding brokers is the wrong lever for cosmetic imbalance

When a broker looks "underutilized," the instinct is to add capacity. For a balance problem this makes things worse, not better:

- **A new broker joins empty.** Kafka never auto-migrates existing partitions onto a freshly added broker. The new broker starts with zero leaders and zero data, so on day one a 3-way skew becomes a 4-way skew with one broker at ~0% — dashboards look *more* uneven, not less.
- **SBC will not populate it at low absolutes.** The disk goal needs ~20% absolute fill before it evaluates; the network goals are non-triggering. With nothing violated, SBC has no reason to move partitions onto the new broker — it sits idle until you manually run `kafka-reassign-partitions` or a forced `kafka-rebalance-cluster --rebalance`. That is the *same* manual rebalance you'd run without adding a broker, so the broker addition contributes nothing to balance.
- **The dominant skew source doesn't move anyway.** Adding a broker doesn't touch an existing topic's replica/leader layout (e.g. `_confluent-link-metadata`); only a manual reassignment of that topic does.

Add brokers for **capacity** (sustained produce > ~20 MB/s or consume > ~60 MB/s per broker over a 12h window, or disk crossing ~50% fill) or **availability/HA** (e.g. raising RF, surviving two simultaneous broker failures) — never to make a cosmetic dashboard look even. At this PoC's utilization neither justification applied.

---

### SBC (Self-Balancing Clusters) in KRaft mode

#### Where SBC actually runs

In CP 8.x KRaft deployments, SBC (the DataBalancer / Cruise Control engine) runs on the **active KRaft quorum leader controller**, not on broker pods. This has direct consequences:

- `confluent.balancer.enable=true` **must be set on the KRaftController CRD** (`configOverrides.server`) — the controller is where the engine actually runs. The Confluent docs say to set it on every broker and every controller, so keep both CRDs in sync; but if it is only on the broker the engine never starts.
- The working config pattern (see `edge/01-kraftcontroller.yaml` and `hub/01-kraftcontroller.yaml`):

```yaml
configOverrides:
 server:
 - confluent.balancer.enable=true
 - confluent.balancer.heal.uneven.load.trigger=ANY_UNEVEN_LOAD
 - inter.broker.listener.name=REPLICATION
 - listener.security.protocol.map=CONTROLLER:SASL_PLAINTEXT,REPLICATION:SASL_PLAINTEXT
 - listener.name.replication.sasl.enabled.mechanisms=PLAIN
 - listener.name.replication.sasl.mechanism=PLAIN
 - listener.name.replication.plain.sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="kafka" password="kafka-secret";
```

The `inter.broker.listener.name=REPLICATION` and the REPLICATION listener security block on the controller are what allow SBC to find broker endpoints and communicate. Without them, SBC throws `IllegalArgumentException: Bootstrap server endpoint was not provided` at startup. Controller-only nodes skip broker-role validation so adding REPLICATION to `listener.security.protocol.map` passes startup validation without requiring the listener to actually be bound.

A follower controller will log `no longer the metadata quorum leader` followed by `DataBalancer is disabled -- ignoring for now`. This is **not** evidence that SBC is globally disabled — it is a follower correctly stepping down. Only the active quorum leader runs the engine, so always confirm which controller is the leader before reading balancer logs (see verification below).

#### SBC config keys that do NOT exist

Do not add these to any CRD — they are silently accepted as unknown properties and do nothing:

- `confluent.balancer.bootstrap.servers`
- `confluent.balancer.sasl.jaas.config`
- `confluent.balancer.security.protocol`
- `confluent.balancer.sasl.mechanism`

SBC's Kafka admin client derives its security settings from the inter-broker listener configuration at runtime (`interBrokerClientConfigs()`). There is no `confluent.balancer.*` security namespace. The fix is always the REPLICATION listener config on the controller.

#### How to verify SBC health — do NOT trust `kafka-rebalance-cluster --status`

`kafka-rebalance-cluster --status` routes through the active controller's CONTROLLER listener (port 9074). In this setup, that path has connectivity issues from broker pods and the command times out even when SBC is completely healthy. A timeout is a transport failure, not a DataBalancer failure.

Authoritative diagnostic — grep the active controller pod logs:

```bash
# Find the active controller (it's the one with SBK_AnomalyDetector log entries)
for pod in kraftcontroller-0 kraftcontroller-1 kraftcontroller-2; do
    echo "=== $pod ==="
    kubectl --context="${EDGE_CTX}" logs -n cp-edge $pod --tail=50 2>&1 | \
    grep "SBK_AnomalyDetector\|GoalViolationDetector\|DataBalanceEngine" | tail -5
done
```

Look for:
- `SBK_AnomalyDetector` entries → SBC is running on this controller
- `GoalViolationDetector detect - Goal violation detector did not detect any violated goals` → SBC ran and found nothing to do (healthy and correctly idle)
- `DataBalanceEngine started` / `STARTING to RUNNING` → confirmed healthy startup
- `Failed when starting up DataBalanceEngine` / `BalancerOfflineException` → SBC broken, check REPLICATION listener config

Note: the anomaly detector logs its own model of replica load, e.g. `Max replica load per broker for resource disk in MiB is: [0=4140.6, 1=6732.9, 2=1121.9]`. That is SBC's tracked load (from telemetry), not raw disk bytes, and a large relative gap here with "no violated goals" is expected at low absolutes — do not mistake it for a fault.

#### How to manually trigger a full SBC rebalance (when needed)

SBC's non-triggering goals (`LeaderReplicaDistributionGoal`, `NetworkInboundUsageDistributionGoal`, `NetworkOutboundUsageDistributionGoal`, `TopicReplicaDistributionGoal`) only run after a detection goal fires first. An explicit `kafka-rebalance-cluster --rebalance` bypasses that gate and runs the full goal list including all non-triggering goals.

For KRaft clusters, the balancer API lives on the controller, so the command targets the controller directly via `--bootstrap-controller` (not `--bootstrap-server`). Run it from a controller pod:

```bash
# Dry-run first — review what it would move before committing
kubectl --context="${EDGE_CTX}" exec -n cp-edge kraftcontroller-0 -- \
    kafka-rebalance-cluster \
    --bootstrap-controller kraftcontroller.cp-edge.svc.cluster.local:9074 \
    --command-config /opt/confluentinc/etc/kafka/kafka.properties \
    --rebalance-dry-run

# Execute if the plan is acceptable
kubectl --context="${EDGE_CTX}" exec -n cp-edge kraftcontroller-0 -- \
    kafka-rebalance-cluster \
    --bootstrap-controller kraftcontroller.cp-edge.svc.cluster.local:9074 \
    --command-config /opt/confluentinc/etc/kafka/kafka.properties \
    --rebalance
```

Note: In this cluster, `kafka-rebalance-cluster` timed out due to CONTROLLER listener connectivity issues. The official KRaft troubleshooting entry "The balancer status for a KRaft controller hangs" covers this symptom — check that before assuming an SBC fault. If the issue persists, fall back to Path B (`kafka-reassign-partitions` with a throttle).

#### When to do a forced rebalance — and when NOT to

Do it when the leader/throughput imbalance has grown large enough to cause a real capacity problem — e.g., brokers 0/1 approaching saturation while broker 2 sits idle at sustained multi-MB/s throughput gaps, or when disk fill passes 20% on any broker with >20% relative variance.

Do NOT do it during active demo scenarios, link pause/resume tests, or any time you need Cluster Link stability visible in C3. See the Cluster Linking section below.

At the fill levels in this PoC (~1.7% disk, ~0.17 MB/s throughput), any leader skew is cosmetic. SBC is correctly idle.

#### SBC goal triggering mechanics

SBC has two distinct goal lists. The correct terminology:
- **Detection goals** (`anomaly.detection.goals`) — violations here trigger a rebalance: `DiskCapacityGoal`, `NetworkInboundCapacityGoal`, `NetworkOutboundCapacityGoal`, `ReplicaCapacityGoal`, `ReplicaDistributionGoal`, `DiskUsageDistributionGoal` (when disk variance > 20%), plus placement goals (`ReplicaPlacementGoal`, `RackAwareGoal`, etc.). The docs put it directly: "only replica counts and disk usage above 20 percent are triggering factors."
- **Rebalancing (non-triggering) goals** — only run after a detection goal fires: `LeaderReplicaDistributionGoal`, `NetworkInboundUsageDistributionGoal`, `NetworkOutboundUsageDistributionGoal`, `TopicReplicaDistributionGoal`. CPU distribution (`CpuUsageDistributionGoal`) is also non-triggering and is not in the default goal set — it must be added manually. There is no `CpuCapacityGoal`.
- Hard-vs-soft is a separate axis from triggering-vs-non-triggering. Hard goals (e.g. rack-awareness, replica placement) can abort a rebalancing round with `OptimizationFailureException` even when disk is skewed — if a forced rebalance produces no moves, check the data-balancer log for that exception before assuming SBC is broken.
- `confluent.balancer.heal.uneven.load.trigger=ANY_UNEVEN_LOAD` enables continuous detection-based self-healing (vs `EMPTY_BROKER` = broker add/remove only). It does **not** promote leader or network distribution into the detection set — those goals remain non-triggering even under `ANY_UNEVEN_LOAD`. This is a common misconception.
- The absolute disk floor still applies regardless of this setting — SBC won't run disk balancing until at least one broker exceeds ~20% disk-full.
- SBC tracks replica load via `_confluent-telemetry-metrics` topic data (CP 8.x uses the Telemetry Reporter; `_confluent-metrics` is the older Metrics Reporter topic from pre-8.x). Its internal state lives in `_confluent_balancer_api_state` — if SBC never starts, that topic is never created, which is a quick health check. SBC's view of replica load can differ significantly from raw `kafka-log-dirs` bytes — a ~6x relative gap between SBC's model and raw bytes with SBC finding no violations is normal.
- SBC requires broker disk capacities to be near-equal: if any broker's disk capacity differs from the average by more than 5%, SBC will not rebalance. All brokers in this PoC are 1 TiB so this is not an issue, but it is a silent rebalance-blocker on heterogeneous node types.

---

### C3 disk skew alarm vs SBC threshold mismatch

C3 and SBC use different thresholds and this causes false-positive critical alarms at low disk fill:

| | C3 disk skew warning | SBC DiskUsageDistributionGoal |
|---|---|---|
| Relative threshold | >10% mean absolute variance | >20% |
| Absolute floor | 1 GB default, configurable | ~20% disk-full on any broker |
| Configurable | Only the absolute floor | Not directly |

Both conditions must be true for C3 to fire: relative mean-absolute-difference > 10% **and** the absolute pairwise difference exceeds `confluent.controlcenter.disk.skew.warning.min.bytes` (default 1 GB). At ~1.7% fill on 1 TiB brokers, C3 fires "Critical: Disk Usage Distribution is not even" while SBC correctly stays idle. This is expected behavior — both components are working correctly, their thresholds just don't align out of the box. ("C3 shows disk skew warnings although SBC is enabled" is a documented Confluent support scenario.)

Fix: raise the absolute floor so C3 only warns when SBC would also consider acting:

```yaml
# In ControlCenter CRD configOverrides.server (see edge/05-controlcenter.yaml and hub/05-controlcenter.yaml):
- confluent.controlcenter.disk.skew.warning.min.bytes=10737418240 # 10 GB — for disks > 200 GB
```

Confluent's documented scaling guidance:
- Disk > 200 GB → 10 GB floor
- Disk < 200 GB → 2–5 GB floor
- For full SBC alignment on 1 TiB brokers: ~200 GB floor (`214748364800`)

The 10% relative threshold is hardcoded in C3 and cannot be changed. The property and its logic are unchanged in next-gen C3 (Prometheus/Alertmanager backend), so the same key works there.

**Always check absolute fill numbers before acting on relative percentages.** A 40% relative gap at 1.7% fill is not the same problem as a 40% gap at 60% fill. Get actual bytes with `kafka-log-dirs --describe` and divide by the `dataVolumeCapacity` from the Kafka CRD.

**Before tuning the floor, rule out two confounders** that tuning would mask rather than fix: (1) *stray partitions* — leftover data dirs on a broker that is no longer leader/replica still occupy space and skew C3's numbers; (2) C3's computed disk figure occasionally diverging from `df -h` / `kafka-log-dirs`. If you derived your numbers from actual log-dir sizes (as in this PoC), both are already ruled out and raising the floor is the correct action, not a cover-up.

---

### CFK next-gen C3 SASL misconfiguration (known CFK omission)

CFK generates `confluent.controlcenter.streams.sasl.*` correctly from `spec.dependencies.kafka.authentication` but does not generate the matching security properties for the named managed-cluster client (`confluent.controlcenter.kafka.<ClusterName>.*`).

Note the base `bootstrap.servers` connection is the Kafka Streams connection and is secured by the `confluent.controlcenter.streams.*` prefix — they are a pair. If `streams.*` has SASL, the base connection is already authenticated; do not add bare `security.protocol`/`sasl.*` to "fix" it (that is inert, the same class of trap as the `confluent.balancer.sasl.*` keys). The only genuinely missing client is the named managed-cluster one.

Without the fix, the named-cluster admin client defaults to PLAINTEXT, fails the SASL handshake on the INTERNAL listener (9071), and the cluster panel in C3 is permanently dead with `clusterId: null` in a retry loop.

Symptom in logs:

```
Cluster name: Edge lookup complete, clusterId: null, Exception:org.apache.kafka.common.errors.TimeoutException: Timed out waiting for a node assignment. Call: listNodes
```

Fix — add to ControlCenter CRD `configOverrides.server`:

```yaml
- confluent.controlcenter.kafka.<ClusterName>.security.protocol=SASL_PLAINTEXT
- confluent.controlcenter.kafka.<ClusterName>.sasl.mechanism=PLAIN
- confluent.controlcenter.kafka.<ClusterName>.sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${file:/mnt/secrets/credential/plain.txt:username}" password="${file:/mnt/secrets/credential/plain.txt:password}";
```

Where `<ClusterName>` is the dot-free token from `confluent.controlcenter.kafka.<ClusterName>.bootstrap.servers` (e.g., `Edge`, `Hub`).

Before applying, verify two things against the rendered `controlcenter.properties` — both are silent no-op traps if wrong:
1. **Credential path** — grep `confluent.controlcenter.streams.sasl.jaas.config` and copy the `${file:...}` path verbatim. A wrong path resolves to empty and reproduces the exact SASL failure you are fixing. Confirm the secret is actually mounted in the C3 pod: `kubectl exec controlcenter-0 -- cat <that-path>`.
2. **Mechanism match** — grep `confluent.controlcenter.streams.sasl.mechanism`. If it is `PLAIN`, the `PLAIN` above is correct; if it is `OAUTHBEARER` or `SCRAM-*`, match it or the handshake fails even with valid credentials. Also match the protocol to what the INTERNAL listener (9071) requires — if it is SASL over TLS it is `SASL_SSL` plus a truststore, not `SASL_PLAINTEXT`.

Confirm the fix:

```bash
kubectl --context="${EDGE_CTX}" logs -n cp-edge controlcenter-0 -c controlcenter 2>&1 | \
    grep "lookup complete" | tail -5
# Healthy: clusterId: <non-null>, Exception:null
```

**Authn success is not authz success.** Once the handshake passes, `listNodes` needs `Describe` on the `Cluster` resource for the C3 principal. The broker here runs `ConfluentServerAuthorizer` with `KRAFT_ACL`, and the streams connection working does not imply cluster-describe is granted (different ACL scope). If the symptom flips from `TimeoutException` to an authorization error (still `clusterId: null` but a different exception), the next fix is an ACL grant for the C3 principal, not more SASL config.

---

### Cluster Linking and partition rebalance risks

`_confluent-link-metadata` (observed in this PoC: 50 partitions, RF=3 — verify the default for your version rather than assuming) is the Cluster Linking coordinator topic. Each partition's leader runs the coordinator tasks for a subset of mirror topics. If a forced SBC rebalance or manual `kafka-reassign-partitions` moves leaders of this topic:

- Link coordinator tasks relocate to the new leader brokers
- Mirror-link clients briefly disconnect and reconnect (seconds, not minutes)
- No data loss, but lag metrics spike momentarily and link state shows a transient DEGRADED in C3

This topic was the dominant source of leader skew in this PoC (29/21/0 across brokers 0/1/2) — 50 of 142 internal leaders sat on it, all on brokers 0 and 1. It is compacted and tiny, so it drives **leader/throughput** skew, not disk skew. A bare preferred-leader election will NOT move leadership to broker 2 because broker 2 is never first in the replica list — you must reorder replicas first, then elect.

If broker 2 has zero preferred leaders on `_confluent-link-metadata`, that skew is an artifact of how KRaft partition placement works at low partition/replication counts (a known characteristic, less even than ZooKeeper's), not a fault. The fix path when it actually matters:

1. `kafka-reassign-partitions --generate` to get the current assignment JSON
2. Hand-edit the `replicas` arrays to rotate broker 2 to first position on ~1/3 of partitions (keep all three brokers in each set so RF stays 3)
3. `kafka-reassign-partitions --execute` with a throttle (`--throttle 10485760`), then `--verify` and remove the throttle
4. `kafka-leader-election --election-type PREFERRED --topic _confluent-link-metadata --all-topic-partitions`

This is supported — manual reassignment does not interrupt SBC, and Confluent's own runbooks reassign internal topics in production. The real caution is operational (coordinator-task relocation / brief mirror-link reconnection churn), so do it in a quiet window — not a support-policy prohibition.

The CoreDNS rewrite dependency is also worth knowing: the edge-to-hub Cluster Link uses `*.edge.kafka.demo` FQDNs in `bootstrapEndpoint`, resolved in Hub pods by the CoreDNS config from `scripts/06-cluster-dns.sh`. If the Hub cluster is reprovisioned, the CoreDNS rewrites are gone and the link will fail to reconnect even though the NLBs are healthy. Re-run `scripts/06-cluster-dns.sh` after any Hub cluster reprovision.

---

### General operational notes

**Adding properties to CRD `configOverrides` safely.** ConfigOverrides are additive — CFK writes them alongside auto-generated properties and they survive reconcile. Unknown property names are silently accepted as no-ops (the `confluent.balancer.sasl.*` trap). Always verify a property name exists in Confluent docs before adding it. After a rolling restart, `kafka-configs --describe` confirms whether the broker recognized and retained the property — if it shows up only as a custom/unknown property, it is a no-op. For JAAS configs with `${file:...}` references in YAML list items: plain (unquoted) YAML scalars handle embedded `"` characters fine and pass through verbatim — the file config provider (`config.providers=file`) must already be configured in the component (it is in both C3 and broker in this setup).

**Next-gen C3 metrics path vs legacy.** The next-gen C3 image (`cp-enterprise-control-center-next-gen`) does not use the `_confluent-metrics` topic or monitoring interceptors. It bundles Prometheus + Alertmanager as sidecars and ingests metrics each component publishes via `dependencies.metricsClient` (the OTLP push path to port 9090). The JMX Prometheus exporter on port 7778 feeds kube-prometheus-stack/Grafana, not C3. Image tags must match across all three images (`cp-enterprise-control-center-next-gen`, `cp-enterprise-prometheus`, `cp-enterprise-alertmanager`).

**KRaft controller node sizing.** Controllers are pinned to a dedicated m5.large node group (see `terraform/eks-edge.tf`). The CPU request on the KRaftController pod must stay below ~1930m (the m5.large allocatable after EKS kube/system reservation) — requesting the full "2" vCPU leaves the pod Pending. Schema Registry and Control Center are pinned to broker nodes (m5.xlarge), not controller nodes, because an m5.large cannot fit a controller and an SR/C3 pod simultaneously.

**Kafka cluster ID in KRaft.** The `spec.clusterID` in the KRaftController CRD must be a URL-safe base64-encoded 16-byte UUID (22 chars, no padding) — generate with `kafka-storage random-uuid`. An arbitrary string is rejected at format time. This ID is also the `clusterID` returned by the REST proxy v3 API, but the Kafka REST cluster ID is assigned by Kafka at format time and retrieved dynamically:

```bash
CLUSTER_ID=$(curl -sk --cacert certs/cacerts.pem -u admin:admin-secret \
    https://kafka.edge.kafka.demo:8090/kafka/v3/clusters | jq -r '.data[0].cluster_id')
```

**License installation.** Confluent Platform requires a license for production features. Install via `scripts/07-install-license.sh`. Without a license, clusters run in 30-day trial mode — some features (including SBC and Cluster Linking beyond trial limits) are time-gated. The license topic replication factor is set to 3 in both broker CRDs (`confluent.license.topic.replication.factor=3`).

**CONTROLLER listener port.** The KRaft CONTROLLER listener in this setup runs on port 9074 (SASL_PLAINTEXT). Verify the actual port from the controller pod's rendered `kafka.properties` or from connection logs before scripting anything that connects to it — documentation sometimes cites 9073.
