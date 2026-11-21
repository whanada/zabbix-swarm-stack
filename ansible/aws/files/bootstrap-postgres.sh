#!/bin/sh
set -eu
set -o pipefail
export PGPASSWORD="$(cat /run/secrets/patroni_superuser_password)"
dbuser=$(cat /run/secrets/zabbix_db_user)
dbpass=$(cat /run/secrets/zabbix_db_password)
metricspass=$(cat /run/secrets/metrics_pg_password)
for attempt in $(seq 1 90); do
  if psql -h zabbix_data_db-haproxy -U postgres -d postgres -c 'SELECT 1' >/dev/null 2>&1; then break; fi
  if [ "$attempt" = 90 ]; then echo 'PostgreSQL primary did not become available' >&2; exit 1; fi
  sleep 2
done
psql -h zabbix_data_db-haproxy -U postgres -d postgres -v ON_ERROR_STOP=1 -v dbuser="$dbuser" -v dbpass="$dbpass" -v metricspass="$metricspass" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'dbuser', :'dbpass') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'dbuser')
\gexec
SELECT format('CREATE DATABASE zabbix OWNER %I', :'dbuser') WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'zabbix')
\gexec
SELECT format('CREATE ROLE zbx_monitor LOGIN PASSWORD %L', :'metricspass') WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'zbx_monitor')
\gexec
GRANT pg_monitor TO zbx_monitor;
SQL
psql -h zabbix_data_db-haproxy -U postgres -d zabbix -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS timescaledb'

export PGPASSWORD="$dbpass"
schema_exists=$(psql -h zabbix_data_db-haproxy -U "$dbuser" -d zabbix -Atc "SELECT to_regclass('public.dbversion') IS NOT NULL")
if [ "$schema_exists" = f ]; then
  gzip -dc /opt/zabbix-schema/create.sql.gz | psql -h zabbix_data_db-haproxy -U "$dbuser" -d zabbix -v ON_ERROR_STOP=1 --single-transaction
fi
hypertables=$(psql -h zabbix_data_db-haproxy -U "$dbuser" -d zabbix -Atc "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_schema='public' AND hypertable_name IN ('history','history_uint','history_log','history_text','history_str','history_bin','history_json','auditlog','trends','trends_uint')")
if [ "$hypertables" -lt 10 ]; then
  psql -h zabbix_data_db-haproxy -U "$dbuser" -d zabbix -v ON_ERROR_STOP=1 -f /opt/zabbix-schema/timescaledb.sql
fi
