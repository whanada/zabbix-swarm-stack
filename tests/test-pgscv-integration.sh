#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${PATRONI_IMAGE:?Load .env before testing}"
name=zbx-pgscv-check-$$
collector=zbx-pgscv-exporter-$$
cleanup() { docker rm -f "$collector" "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM
cleanup
docker run -d --name "$name" --network none --entrypoint /bin/sh "$PATRONI_IMAGE" -ec '
 initdb -D /tmp/pgdata -U postgres --no-instructions >/dev/null
 exec postgres -D /tmp/pgdata -c listen_addresses=127.0.0.1 -c shared_preload_libraries=timescaledb' >/dev/null
for i in $(seq 1 30); do
  if docker exec "$name" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec "$name" psql -h 127.0.0.1 -U postgres -c "CREATE ROLE zbx_monitor LOGIN PASSWORD 'test';" >/dev/null
docker exec "$name" psql -h 127.0.0.1 -U postgres -c 'GRANT pg_monitor TO zbx_monitor;' >/dev/null
docker exec "$name" psql -h 127.0.0.1 -U postgres -c 'CREATE DATABASE zabbix;' >/dev/null
docker exec "$name" psql -h 127.0.0.1 -U postgres -d zabbix -c 'CREATE EXTENSION timescaledb;' >/dev/null
docker exec "$name" psql -h 127.0.0.1 -U postgres -d zabbix -c "CREATE TABLE test_hypertable (clock bigint NOT NULL, value integer); SELECT create_hypertable('test_hypertable','clock');" >/dev/null
docker run -d --name "$collector" --network "container:$name" --mount type=bind,"src=$project_dir/ansible/aws/files/pgscv.yml,dst=/tmp/pgscv.yml,readonly" -e PGSCV_LISTEN_ADDRESS=127.0.0.1:9890 -e PGSCV_DISABLE_COLLECTORS=system -e 'DATABASE_DSN=host=127.0.0.1 port=5432 dbname=zabbix user=zbx_monitor password=test sslmode=disable' "${PGSCV_IMAGE:?Load .env before testing}" --config-file=/tmp/pgscv.yml >/dev/null
for i in $(seq 1 20); do
  if docker exec "$name" wget -qO /tmp/metrics http://127.0.0.1:9890/metrics 2>/dev/null && docker exec "$name" grep -q 'postgres_timescale_hypertable_chunks' /tmp/metrics; then
    echo 'pgSCV successfully exported a TimescaleDB hypertable metric'
    exit 0
  fi
  sleep 1
done
docker logs "$collector" 2>&1 | tail -30
exit 1
