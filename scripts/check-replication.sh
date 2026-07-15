#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

read -r -p "PostgreSQL admin user [postgres]: " postgres_user
postgres_user="${postgres_user:-postgres}"
read -r -s -p "PostgreSQL admin password: " postgres_password
echo

primary_host="${STACK_NAME}_timescaledb-primary"
subscriber_host="${STACK_NAME}_timescaledb-subscriber"
client=(docker run --rm --network "${ZABBIX_NETWORK}" --env PGPASSWORD="${postgres_password}" "${TIMESCALE_IMAGE}")

echo "Publisher slots"
"${client[@]}" psql -X --host "${primary_host}" --username "${postgres_user}" --dbname "${POSTGRES_DB}" \
  --command "SELECT slot_name, active, confirmed_flush_lsn, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS retained_wal FROM pg_replication_slots;"
echo "Subscriber workers"
"${client[@]}" psql -X --host "${subscriber_host}" --username "${postgres_user}" --dbname "${POSTGRES_DB}" \
  --command "SELECT subname, pid, received_lsn, latest_end_lsn, latest_end_time FROM pg_stat_subscription;"
echo "Subscriber hypertables"
"${client[@]}" psql -X --host "${subscriber_host}" --username "${postgres_user}" --dbname "${POSTGRES_DB}" \
  --command "SELECT hypertable_schema, hypertable_name, num_chunks FROM timescaledb_information.hypertables ORDER BY 1, 2;"
echo "WARNING: this status does not prove that TimescaleDB hypertable changes are replicated."
echo "Native logical PUB/SUB is scoped to ordinary tables; use physical replication for a complete standby."

unset postgres_password
