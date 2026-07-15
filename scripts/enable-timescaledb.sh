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
: "${ZABBIX_SERVER_IMAGE:?ZABBIX_SERVER_IMAGE is required}"
: "${POSTGRES_DB:?POSTGRES_DB is required}"

assert_no_writers() {
  local service tasks
  for service in "${STACK_NAME}_server-ha1" "${STACK_NAME}_server-ha2" "${STACK_NAME}_front"; do
    docker service inspect "${service}" >/dev/null 2>&1 || continue
    tasks="$(docker service ps --filter desired-state=running --format '{{.ID}}' "${service}")"
    if [[ -n "${tasks}" ]]; then
      echo "Refusing to continue while ${service} has running tasks." >&2
      echo "Scale both Zabbix servers and the frontend to zero first." >&2
      exit 1
    fi
  done
}

assert_no_writers
read -r -p "PostgreSQL admin user [postgres]: " postgres_user
postgres_user="${postgres_user:-postgres}"
read -r -s -p "PostgreSQL admin password: " postgres_password
echo
[[ -n "${postgres_password}" ]] || { echo "The PostgreSQL password cannot be empty." >&2; exit 1; }

primary_host="${STACK_NAME}_timescaledb-primary"
docker run --rm \
  --network "${ZABBIX_NETWORK}" \
  --env PGHOST="${primary_host}" \
  --env PGUSER="${postgres_user}" \
  --env PGDATABASE="${POSTGRES_DB}" \
  --env PGPASSWORD="${postgres_password}" \
  --entrypoint /bin/bash \
  "${ZABBIX_SERVER_IMAGE}" \
  -ec 'test -r /usr/share/doc/zabbix-server-postgresql/timescaledb.sql; exec psql -X --set ON_ERROR_STOP=1 --file /usr/share/doc/zabbix-server-postgresql/timescaledb.sql'

unset postgres_password
echo "TimescaleDB conversion completed on ${primary_host}."
