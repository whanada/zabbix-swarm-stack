#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
[[ -f "${ENV_FILE}" ]] || { echo "Missing ${ENV_FILE}." >&2; exit 1; }

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

: "${STACK_NAME:?STACK_NAME is required}"
: "${ZABBIX_NETWORK:?ZABBIX_NETWORK is required}"
: "${TIMESCALE_IMAGE:?TIMESCALE_IMAGE is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${REPLICATION_PUBLICATION:?REPLICATION_PUBLICATION is required}"
: "${REPLICATION_SUBSCRIPTION:?REPLICATION_SUBSCRIPTION is required}"

[[ "${REPLICATION_ENABLED:-false}" == "true" ]] || { echo "REPLICATION_ENABLED is not true; nothing to do."; exit 0; }

assert_no_writers() {
  local service tasks
  for service in "${STACK_NAME}_server-ha1" "${STACK_NAME}_server-ha2" "${STACK_NAME}_front"; do
    docker service inspect "${service}" >/dev/null 2>&1 || continue
    tasks="$(docker service ps --filter desired-state=running --format '{{.ID}}' "${service}")"
    if [[ -n "${tasks}" ]]; then
      echo "Refusing to reset the subscriber while ${service} has running tasks." >&2
      exit 1
    fi
  done
}

assert_no_writers
[[ "$(docker network inspect --format '{{.Attachable}}' "${ZABBIX_NETWORK}")" == "true" ]] || {
  echo "${ZABBIX_NETWORK} must be an attachable overlay network." >&2
  exit 1
}

read -r -p "PostgreSQL admin user [postgres]: " postgres_user
postgres_user="${postgres_user:-postgres}"
read -r -s -p "PostgreSQL admin password: " postgres_password
echo
read -r -p "Zabbix database user [zabbixpg]: " application_user
application_user="${application_user:-zabbixpg}"
read -r -p "Logical replication user [zabbix_repl]: " replication_user
replication_user="${replication_user:-zabbix_repl}"
read -r -s -p "Logical replication password: " replication_password
echo
read -r -p "Type RESET-SUBSCRIBER to erase and rebuild the subscriber database: " confirmation

[[ -n "${postgres_password}" && -n "${replication_password}" ]] || { echo "Passwords cannot be empty." >&2; exit 1; }
[[ "${confirmation}" == "RESET-SUBSCRIBER" ]] || { echo "Confirmation did not match; no changes made." >&2; exit 1; }

primary_host="${STACK_NAME}_timescaledb-primary"
subscriber_host="${STACK_NAME}_timescaledb-subscriber"
dump_dir="${ROOT_DIR}/.replication"
dump_file="${dump_dir}/${POSTGRES_DB}-bootstrap.dump"
restore_mode=0
mkdir -p "${dump_dir}"
chmod 700 "${dump_dir}"

cleanup() {
  local status=$?
  if [[ "${restore_mode}" -eq 1 ]]; then
    docker run --rm --network "${ZABBIX_NETWORK}" --env PGPASSWORD="${postgres_password}" \
      "${TIMESCALE_IMAGE}" psql -X --host "${subscriber_host}" --username "${postgres_user}" \
      --dbname "${POSTGRES_DB}" --command 'SELECT timescaledb_post_restore();' >/dev/null 2>&1 || true
  fi
  [[ "${KEEP_REPLICATION_DUMP:-false}" == "true" ]] || rm -f "${dump_file}"
  unset postgres_password replication_password
  exit "${status}"
}
trap cleanup EXIT

client_base=(docker run --rm --network "${ZABBIX_NETWORK}" --env PGPASSWORD="${postgres_password}")

echo "Checking both database services..."
"${client_base[@]}" "${TIMESCALE_IMAGE}" pg_isready --host "${primary_host}" --dbname "${POSTGRES_DB}"
"${client_base[@]}" "${TIMESCALE_IMAGE}" pg_isready --host "${subscriber_host}" --dbname "${POSTGRES_DB}"

echo "Removing an old subscription, if present..."
"${client_base[@]}" --volume "${ROOT_DIR}/scripts/replication/drop-subscription.sql:/work/drop-subscription.sql:ro" \
  "${TIMESCALE_IMAGE}" psql -X --host "${subscriber_host}" --username "${postgres_user}" --dbname "${POSTGRES_DB}" \
  --set "subscription_name=${REPLICATION_SUBSCRIPTION}" --file /work/drop-subscription.sql

echo "Creating the publisher role and publication..."
"${client_base[@]}" --volume "${ROOT_DIR}/scripts/replication/publisher.sql:/work/publisher.sql:ro" \
  "${TIMESCALE_IMAGE}" psql -X --host "${primary_host}" --username "${postgres_user}" --dbname "${POSTGRES_DB}" \
  --set "database_name=${POSTGRES_DB}" --set "application_user=${application_user}" \
  --set "replication_user=${replication_user}" \
  --set "replication_password=${replication_password}" --set "publication_name=${REPLICATION_PUBLICATION}" \
  --set "subscription_name=${REPLICATION_SUBSCRIPTION}" --file /work/publisher.sql

echo "Creating a consistent TimescaleDB dump..."
"${client_base[@]}" "${TIMESCALE_IMAGE}" pg_dump --host "${primary_host}" --username "${postgres_user}" \
  --dbname "${POSTGRES_DB}" --format custom --no-owner --no-privileges --no-publications --no-subscriptions \
  >"${dump_file}"
chmod 600 "${dump_file}"

echo "Resetting the subscriber database..."
"${client_base[@]}" --volume "${ROOT_DIR}/scripts/replication/reset-subscriber.sql:/work/reset-subscriber.sql:ro" \
  "${TIMESCALE_IMAGE}" psql -X --host "${subscriber_host}" --username "${postgres_user}" --dbname postgres \
  --set "database_name=${POSTGRES_DB}" --set "database_owner=${application_user}" --file /work/reset-subscriber.sql

"${client_base[@]}" "${TIMESCALE_IMAGE}" psql -X --host "${subscriber_host}" --username "${postgres_user}" \
  --dbname "${POSTGRES_DB}" --set ON_ERROR_STOP=1 \
  --command 'CREATE EXTENSION IF NOT EXISTS timescaledb; SELECT timescaledb_pre_restore();'
restore_mode=1

echo "Restoring the primary snapshot to the subscriber..."
"${client_base[@]}" --interactive "${TIMESCALE_IMAGE}" pg_restore --host "${subscriber_host}" \
  --username "${postgres_user}" --dbname "${POSTGRES_DB}" --format custom --no-owner --no-privileges --exit-on-error \
  <"${dump_file}"

"${client_base[@]}" "${TIMESCALE_IMAGE}" psql -X --host "${subscriber_host}" --username "${postgres_user}" \
  --dbname "${POSTGRES_DB}" --set ON_ERROR_STOP=1 --command 'SELECT timescaledb_post_restore();'
restore_mode=0

replication_password_conn="${replication_password//\\/\\\\}"
replication_password_conn="${replication_password_conn//\'/\\\'}"
subscription_connection="host=${primary_host} port=5432 dbname=${POSTGRES_DB} user=${replication_user} password='${replication_password_conn}' connect_timeout=10 application_name=${REPLICATION_SUBSCRIPTION}"

echo "Creating and enabling the subscription..."
"${client_base[@]}" --volume "${ROOT_DIR}/scripts/replication/subscriber.sql:/work/subscriber.sql:ro" \
  "${TIMESCALE_IMAGE}" psql -X --host "${subscriber_host}" --username "${postgres_user}" --dbname "${POSTGRES_DB}" \
  --set "subscription_name=${REPLICATION_SUBSCRIPTION}" --set "subscription_connection=${subscription_connection}" \
  --set "publication_name=${REPLICATION_PUBLICATION}" --file /work/subscriber.sql

"${client_base[@]}" "${TIMESCALE_IMAGE}" psql -X --host "${subscriber_host}" --username "${postgres_user}" \
  --dbname "${POSTGRES_DB}" --command 'SELECT subname, pid, received_lsn, latest_end_lsn, latest_end_time FROM pg_stat_subscription;'

echo "Subscriber bootstrap completed. Keep application writes stopped until you verify replication status."
echo "WARNING: native logical PUB/SUB does not provide complete TimescaleDB hypertable replication."
echo "Use physical streaming replication when the subscriber must be a promotable standby."
