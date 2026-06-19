# Grafana Dashboards for Confluent Platform

## Official Confluent JMX Monitoring Stack

Confluent maintains ready-made Grafana dashboards in:
https://github.com/confluentinc/jmx-monitoring-stacks

### Import dashboards

```bash
# Clone the repo
git clone https://github.com/confluentinc/jmx-monitoring-stacks.git
```

The dashboards are in `jmx-monitoring-stacks/jmxexporter-prometheus-grafana/assets/grafana/`.

Relevant dashboards for this PoC:

| Dashboard file | What it shows |
|---------------|---------------|
| `kafka-cluster.json` | Broker throughput, partition health, replication lag |
| `kafka-kraft.json` | KRaft controller quorum, metadata log |
| `kafka-schema-registry.json` | Schema Registry request rates, latency |
| `kafka-cluster-linking.json` | Cluster Link replication lag, mirror topic offsets |
| `kafka-producer.json` | Producer metrics (batch size, request latency) |
| `kafka-consumer.json` | Consumer lag, fetch latency |

### Import via Grafana UI

1. Open Grafana (get the NLB address from `kubectl get svc -n monitoring`)
2. Go to **Dashboards → Import**
3. Upload the `.json` file or paste the JSON content
4. Select the Prometheus datasource provisioned by kube-prometheus-stack

### Import via API (scripted)

```bash
# Pick the cluster whose Grafana you want to load (edge or hub):
CTX="${EDGE_CTX:-edge}"

# Resolve the Grafana NLB address straight from the cluster:
GRAFANA_URL="http://$(kubectl --context="${CTX}" get svc \
  -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
GRAFANA_CREDS="admin:prom-operator"
# Use the current-exporter dashboards (not the dashboards-old-exporter copies):
DASHBOARD_DIR="./jmx-monitoring-stacks/jmxexporter-prometheus-grafana/assets/grafana/provisioning/dashboards"

# Clone the dashboards repo if it isn't here yet:
[ -d ./jmx-monitoring-stacks ] || \
  git clone https://github.com/confluentinc/jmx-monitoring-stacks.git

# These dashboards declare an `__inputs` Prometheus datasource placeholder, so the
# import must bind it to the real datasource via `inputs` — otherwise it silently
# fails. kube-prometheus-stack provisions a Prometheus datasource with uid "prometheus".
DS_UID="prometheus"

find "${DASHBOARD_DIR}" -name '*.json' | while read -r f; do
  echo "Importing $(basename "$f")..."
  jq --arg ds "${DS_UID}" \
    '{dashboard: ., overwrite: true, folderId: 0,
      inputs: [(.__inputs // [])[] | select(.type=="datasource")
               | {name: .name, type: "datasource", pluginId: .pluginId, value: $ds}]}' "$f" \
  | curl -s -X POST -H "Content-Type: application/json" -u "${GRAFANA_CREDS}" \
      --data @- "${GRAFANA_URL}/api/dashboards/import" \
  | jq -r '"  imported=\(.imported)  title=\(.title)"'
done
```

> The response field that signals success is **`imported: true`** (`status` is
> always `null` for this endpoint — ignore it).

### Troubleshooting: panels show "N/A" / "No data"

1. **No targets scraped.** The PodMonitors must scrape the CfK metrics port,
   which is **named `prometheus` (7778)** — not `jmx-metrics`. Confirm Prometheus
   has live targets:
   ```bash
   kubectl --context="${EDGE_CTX:-edge}" exec -n monitoring \
     prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- \
     wget -qO- 'http://localhost:9090/api/v1/query?query=count(up{namespace="cp-edge"})' | jq -c '.data.result'
   ```
   A non-zero count means scraping works. If zero, re-check `monitoring/02-podmonitors.yaml`
   uses `port: prometheus`.
2. **Dashboard template variables.** At the top of the dashboard, set the
   **`Environment`** variable (it defaults to `None`) to the available value, and
   widen the **time range** (top-right) to *Last 15 minutes* so scraped points fall
   in-window.
3. **No traffic yet.** Producer/consumer panels stay empty until apps are running.

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
