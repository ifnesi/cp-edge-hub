# Grafana Dashboards for Confluent Platform

## Confluent dashboards (CfK-adapted, vendored)

Confluent maintains Grafana dashboards in
[confluentinc/jmx-monitoring-stacks](https://github.com/confluentinc/jmx-monitoring-stacks).
The **stock** dashboards do **not** work as-is with Confluent for Kubernetes —
see "Why CfK needs adapted dashboards" below. This repo vendors the CfK-adapted
versions in **`monitoring/grafana-dashboards/`** and imports them with a script.

### Import

There is **one** Grafana (on Hub); its Prometheus holds both clusters (Edge
remote-writes to it), so a single import covers everything:

```bash
CTX=hub bash monitoring/04-import-dashboards.sh
```

Then in Grafana open **Kafka cluster**, set the **`Namespace`** variable
(`cp-edge` / `cp-hub`), Pod = `All`, and time range = *Last 15 minutes*.

| Dashboard | What it shows |
|-----------|---------------|
| `kafka-cluster.json` | Broker throughput, partition health, replication lag |
| `cluster-linking.json` | Cluster Link replication lag, mirror topic offsets |
| `schema-registry-cluster.json` | Schema Registry request rates, latency |
| `kafka-topics.json` | Per-topic size / throughput |
| `kafka-connect-cluster.json` | Connect workers + connector tasks |
| `kafka-producer.json` / `kafka-consumer.json` | Client metrics (once apps run) |

### Why CfK needs adapted dashboards

CfK's JMX exporter emits metrics as
`kafka_server_replicamanager_value{name="UnderReplicatedPartitions"}` (the MBean
attribute is a **label**), while the stock dashboards query *flattened* names like
`kafka_server_replicamanager_underreplicatedpartitions`, filtered by an `env`
label. Two things bridge the gap, both already in this repo:

1. **JMX-exporter rules** under `spec.metrics.prometheus` in `edge/01-kraftcontroller.yaml`,
   `edge/02-kafka.yaml` (and hub equivalents) flatten the metric names.
2. **CfK-converted dashboards** in `monitoring/grafana-dashboards/` key on
   `namespace`/`pod` (regenerated via the upstream repo's
   `jmxexporter-prometheus-grafana/cfk/update-dashboards.sh`).

### Regenerating the vendored dashboards (optional)

```bash
git clone https://github.com/confluentinc/jmx-monitoring-stacks.git
cd jmx-monitoring-stacks/jmxexporter-prometheus-grafana/cfk
bash update-dashboards.sh        # writes dashboards/
cp dashboards/*.json <repo>/monitoring/grafana-dashboards/
```

### Troubleshooting: panels show "N/A" / "No data"

Run these against the **Hub** Prometheus (the single source for both clusters):

1. **Both clusters present?** The `Namespace` dropdown should list `cp-edge` and
   `cp-hub`. If `cp-edge` is missing, Edge's remote-write isn't landing:
   ```bash
   kubectl --context=hub exec -n monitoring \
     prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     wget -qO- 'http://localhost:9090/api/v1/label/namespace/values' | jq -c '.data'
   ```
2. **Metric names flattened?** Panels query flattened names like
   `kafka_server_kafkaserver_brokerstate`. If this returns 0, the JMX `rules` in
   `edge/02-kafka.yaml` / `edge/01-kraftcontroller.yaml` (or hub) aren't applied —
   re-apply those CRDs and let the pods roll:
   ```bash
   kubectl --context=hub exec -n monitoring \
     prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     wget -qO- 'http://localhost:9090/api/v1/query?query=kafka_server_kafkaserver_brokerstate' | jq -c '.data.result|length'
   ```
3. **`job` label.** Dashboards filter `job="kafka"` (etc.) — `monitoring/02-podmonitors.yaml`
   sets that via `jobLabel: platform.confluent.io/type`. If `job` looks like
   `cp-edge/kafka-brokers`, re-apply the PodMonitor.
4. **Widen the time range** to *Last 15 minutes*; producer/consumer panels stay
   empty until apps are running.

## Key Metrics to Watch

### Cluster Health
- `kafka_server_replicamanager_underreplicatedpartitions` — should be 0
- `kafka_server_replicamanager_offlinereplicacount` — should be 0
- `kafka_controller_kafkacontroller_activecontrollercount` — should be 1

### Cluster Link
- `kafka_server_clusterlinkreplicamanager_linkreplicationbytesinpersec` — replication throughput
- `kafka_server_clusterlinkreplicamanager_linkmirrorpercentlagged` — mirror lag (should approach 0)

### Schema Registry
- `confluent_kafka_schema_registry_registered_count` — total schemas registered
- `confluent_kafka_schema_registry_request_error_rate` — error rate

### Producer/Consumer (once apps are connected)
- `kafka_producer_producer_metrics_record_send_rate`
- `kafka_consumer_consumer_fetch_manager_metrics_records_lag_max`
