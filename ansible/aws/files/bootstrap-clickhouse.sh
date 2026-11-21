#!/bin/sh
set -eu
password=$(cat /run/secrets/clickhouse_zabbix_password)
url=http://zabbix_clickhouse_clickhouse-router:8123
for attempt in $(seq 1 90); do
  if curl -fsS "$url/ping" >/dev/null 2>&1; then break; fi
  if [ "$attempt" = 90 ]; then echo 'ClickHouse did not become ready' >&2; exit 1; fi
  sleep 2
done
curl -fsS -u "zabbix:$password" "$url/" --data-binary 'CREATE DATABASE IF NOT EXISTS otel ON CLUSTER zabbix_cluster'
exec /opt/zabbix-clickhouse/otel_all.sh \
  --server "$url" --db otel --user zabbix --password "$password" \
  --engine 'ReplicatedMergeTree()' --cluster zabbix_cluster
