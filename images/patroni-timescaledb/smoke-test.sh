#!/bin/sh
set -eu
test "$(id -u)" != 0
test -s /opt/zabbix-schema/create.sql.gz
test -s /opt/zabbix-schema/timescaledb.sql
test -x /opt/zabbix-clickhouse/otel_all.sh
command -v bash >/dev/null
command -v curl >/dev/null
patroni --version
patronictl version
python -c 'import patroni.dcs.etcd3, psycopg; print("Patroni etcd3 and psycopg imports OK")'
postgres --version
pg_ctl --version
data_dir=$(mktemp -d /tmp/pg-smoke.XXXXXX)
cleanup() {
  pg_ctl -D "$data_dir" -m fast stop >/dev/null 2>&1 || true
  rm -rf "$data_dir"
}
trap cleanup EXIT INT TERM
initdb -D "$data_dir" -U postgres --no-instructions >/dev/null
pg_ctl -D "$data_dir" -o "-c listen_addresses='' -c unix_socket_directories=/tmp -c shared_preload_libraries=timescaledb" -w start >/dev/null
psql -h /tmp -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION timescaledb;' >/dev/null
psql -h /tmp -U postgres -d postgres -v ON_ERROR_STOP=1 -Atc "SELECT extversion FROM pg_extension WHERE extname='timescaledb'"
psql -h /tmp -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'CREATE ROLE zabbix LOGIN' >/dev/null
psql -h /tmp -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'CREATE DATABASE zabbix OWNER zabbix' >/dev/null
psql -h /tmp -U postgres -d zabbix -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION timescaledb' >/dev/null
set -o pipefail
gzip -dc /opt/zabbix-schema/create.sql.gz | psql -h /tmp -U zabbix -d zabbix -v ON_ERROR_STOP=1 --single-transaction >/dev/null
psql -h /tmp -U zabbix -d zabbix -v ON_ERROR_STOP=1 -f /opt/zabbix-schema/timescaledb.sql >/dev/null
count=$(psql -h /tmp -U zabbix -d zabbix -Atc "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_schema='public' AND hypertable_name IN ('history','history_uint','history_log','history_text','history_str','history_bin','history_json','auditlog','trends','trends_uint')")
test "$count" = 10
echo 'Zabbix schema and 10 TimescaleDB hypertables verified'
