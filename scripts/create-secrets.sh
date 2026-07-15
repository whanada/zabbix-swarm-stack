#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

: "${POSTGRES_ADMIN_USER_SECRET:?POSTGRES_ADMIN_USER_SECRET is required}"
: "${POSTGRES_ADMIN_PASSWORD_SECRET:?POSTGRES_ADMIN_PASSWORD_SECRET is required}"
: "${ZABBIX_DB_USER_SECRET:?ZABBIX_DB_USER_SECRET is required}"
: "${ZABBIX_DB_PASSWORD_SECRET:?ZABBIX_DB_PASSWORD_SECRET is required}"
command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }

create_secret() {
  local name="$1"
  local value="$2"
  if docker secret inspect "${name}" >/dev/null 2>&1; then
    echo "Secret already exists; leaving it unchanged: ${name}"
    return
  fi
  printf '%s' "${value}" | docker secret create "${name}" - >/dev/null
  echo "Created secret: ${name}"
}

read -r -p "PostgreSQL admin user [postgres]: " postgres_admin_user
postgres_admin_user="${postgres_admin_user:-postgres}"
read -r -s -p "PostgreSQL admin password: " postgres_admin_password
echo
read -r -p "Zabbix database user [zabbixpg]: " zabbix_db_user
zabbix_db_user="${zabbix_db_user:-zabbixpg}"
read -r -s -p "Zabbix database password: " zabbix_db_password
echo
[[ -n "${postgres_admin_password}" && -n "${zabbix_db_password}" ]] || { echo "Passwords cannot be empty." >&2; exit 1; }

create_secret "${POSTGRES_ADMIN_USER_SECRET}" "${postgres_admin_user}"
create_secret "${POSTGRES_ADMIN_PASSWORD_SECRET}" "${postgres_admin_password}"
create_secret "${ZABBIX_DB_USER_SECRET}" "${zabbix_db_user}"
create_secret "${ZABBIX_DB_PASSWORD_SECRET}" "${zabbix_db_password}"
unset postgres_admin_password zabbix_db_password

