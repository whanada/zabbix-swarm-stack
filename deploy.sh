#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
TARGET="${1:-all}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env and edit it first." >&2
  exit 1
fi

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 1; }
docker compose version >/dev/null

set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a

: "${STACK_NAME:?STACK_NAME is required}"
files=()
stack_name="${STACK_NAME}"

case "${TARGET}" in
  database) files=(database.yml) ;;
  bootstrap)
    export ZABBIX_HA2_REPLICAS=0
    files=(database.yml ha_server.yml)
    ;;
  server) files=(database.yml ha_server.yml) ;;
  all) files=(database.yml ha_server.yml selenium.yml webservice.yml front.yml) ;;
  proxy)
    files=(proxy_sqlite001.yml)
    stack_name="${STACK_NAME}-proxy"
    ;;
  *)
    echo "Usage: $0 {database|bootstrap|server|all|proxy}" >&2
    exit 2
    ;;
esac

compose_args=(docker compose --env-file "${ENV_FILE}")
for file in "${files[@]}"; do
  compose_args+=(--file "${ROOT_DIR}/${file}")
done

rendered="${ROOT_DIR}/.rendered-${TARGET}.yml"
"${compose_args[@]}" config >"${rendered}"
docker stack config --compose-file "${rendered}" >/dev/null
docker stack deploy --with-registry-auth --compose-file "${rendered}" "${stack_name}"

echo "Rendered configuration: ${rendered}"
echo "Stack deployed: ${stack_name}"

