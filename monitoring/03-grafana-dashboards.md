# Grafana Dashboards for Confluent Platform

## Official Confluent JMX Monitoring Stack

Confluent maintains ready-made Grafana dashboards in:
https://github.com/confluentinc/jmx-monitoring-stacks

### Import dashboards

```bash
# Clone the repo
git clone https://github.com/confluentinc/jmx-monitoring-stacks.git
cd jmx-monitoring-stacks
```

The dashboards are in `jmxexporter-prometheus-grafana/assets/grafana/`.

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
GRAFANA_URL="http://<grafana-nlb-address>"
GRAFANA_CREDS="admin:prom-operator"
DASHBOARD_DIR="./jmx-monitoring-stacks/jmxexporter-prometheus-grafana/assets/grafana"

for f in "${DASHBOARD_DIR}"/*.json; do
  echo "Importing $(basename $f)..."
  curl -s -X POST \
    -H "Content-Type: application/json" \
    -u "${GRAFANA_CREDS}" \
    --data "{\"dashboard\": $(cat $f), \"overwrite\": true, \"folderId\": 0}" \
    "${GRAFANA_URL}/api/dashboards/import" | jq .status
done
```

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
