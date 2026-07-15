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

read -r -p "PostgreSQL admin user [postgres]: " postgres_admin_user
postgres_admin_user="${postgres_admin_user:-postgres}"
read -r -s -p "PostgreSQL admin password: " postgres_admin_password
echo
read -r -p "Zabbix database user [zabbixpg]: " zabbix_db_user
zabbix_db_user="${zabbix_db_user:-zabbixpg}"
read -r -s -p "Zabbix database password: " zabbix_db_password
echo

[[ -n "${postgres_admin_password}" && -n "${zabbix_db_password}" ]] || { echo "Passwords cannot be empty." >&2; exit 1; }

for host in "${STACK_NAME}_timescaledb-primary" "${STACK_NAME}_timescaledb-subscriber"; do
  echo "Creating/updating the non-superuser Zabbix role on ${host}..."
  docker run --rm --network "${ZABBIX_NETWORK}" \
    --env PGPASSWORD="${postgres_admin_password}" \
    --volume "${ROOT_DIR}/scripts/initialize/application-role.sql:/work/application-role.sql:ro" \
    "${TIMESCALE_IMAGE}" \
    psql -X --host "${host}" --username "${postgres_admin_user}" --dbname "${POSTGRES_DB}" \
      --set "database_name=${POSTGRES_DB}" --set "application_user=${zabbix_db_user}" \
      --set "application_password=${zabbix_db_password}" --file /work/application-role.sql
done

unset postgres_admin_password zabbix_db_password
echo "Database roles initialized on both TimescaleDB instances."

