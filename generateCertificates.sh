#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-${ROOT_DIR}/.env}"
CREATE_SECRETS=false
FORCE=false

for arg in "$@"; do
  case "${arg}" in
    --create-secrets) CREATE_SECRETS=true ;;
    --force) FORCE=true ;;
    *) echo "Usage: $0 [--force] [--create-secrets]" >&2; exit 2 ;;
  esac
done

[[ -f "${ENV_FILE}" ]] || { echo "Missing ${ENV_FILE}." >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a
command -v openssl >/dev/null 2>&1 || { echo "openssl is required" >&2; exit 1; }

output_dir="${CERT_OUTPUT_DIR:-${ROOT_DIR}/certs}"
[[ "${output_dir}" == /* ]] || output_dir="${ROOT_DIR}/${output_dir#./}"

if [[ -e "${output_dir}/ca/ca.key" && "${FORCE}" != "true" ]]; then
  echo "Certificates already exist in ${output_dir}; use --force to rotate them." >&2
  exit 1
fi

mkdir -p "${output_dir}/ca" "${output_dir}/server" "${output_dir}/proxy"
if [[ "${FORCE}" == "true" ]]; then
  rm -f \
    "${output_dir}/ca/ca.key" "${output_dir}/ca/ca.crt" "${output_dir}/ca/ca.srl" \
    "${output_dir}/server/zabbix_server.key" "${output_dir}/server/zabbix_server.csr" "${output_dir}/server/zabbix_server.crt" \
    "${output_dir}/proxy/zabbix_proxy.key" "${output_dir}/proxy/zabbix_proxy.csr" "${output_dir}/proxy/zabbix_proxy.crt"
fi

subject_base="/C=${CERT_COUNTRY:-BR}/ST=${CERT_STATE:-Goias}/L=${CERT_LOCALITY:-Goiania}/O=${CERT_ORGANIZATION:-ExampleOrg}/OU=${CERT_ORGANIZATIONAL_UNIT:-IT}"
server_ext="${output_dir}/server/server.ext"
proxy_ext="${output_dir}/proxy/proxy.ext"

printf '%s\n' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' \
  'extendedKeyUsage=serverAuth,clientAuth' \
  "subjectAltName=${CERT_SERVER_SAN:?CERT_SERVER_SAN is required}" >"${server_ext}"
printf '%s\n' \
  'basicConstraints=critical,CA:FALSE' \
  'keyUsage=critical,digitalSignature,keyEncipherment' \
  'extendedKeyUsage=clientAuth' \
  "subjectAltName=${CERT_PROXY_SAN:?CERT_PROXY_SAN is required}" >"${proxy_ext}"

openssl genrsa -out "${output_dir}/ca/ca.key" 4096
openssl req -x509 -new -sha256 -key "${output_dir}/ca/ca.key" \
  -days "${CERT_DAYS:-3650}" -subj "${subject_base}/CN=${CERT_CA_CN:-Zabbix-CA}" \
  -out "${output_dir}/ca/ca.crt"

openssl genrsa -out "${output_dir}/server/zabbix_server.key" 3072
openssl req -new -sha256 -key "${output_dir}/server/zabbix_server.key" \
  -subj "${subject_base}/CN=${CERT_SERVER_CN:?CERT_SERVER_CN is required}" \
  -out "${output_dir}/server/zabbix_server.csr"
openssl x509 -req -sha256 -in "${output_dir}/server/zabbix_server.csr" \
  -CA "${output_dir}/ca/ca.crt" -CAkey "${output_dir}/ca/ca.key" -CAcreateserial \
  -days "${CERT_DAYS:-3650}" -extfile "${server_ext}" \
  -out "${output_dir}/server/zabbix_server.crt"

openssl genrsa -out "${output_dir}/proxy/zabbix_proxy.key" 3072
openssl req -new -sha256 -key "${output_dir}/proxy/zabbix_proxy.key" \
  -subj "${subject_base}/CN=${CERT_PROXY_CN:?CERT_PROXY_CN is required}" \
  -out "${output_dir}/proxy/zabbix_proxy.csr"
openssl x509 -req -sha256 -in "${output_dir}/proxy/zabbix_proxy.csr" \
  -CA "${output_dir}/ca/ca.crt" -CAkey "${output_dir}/ca/ca.key" -CAcreateserial \
  -days "${CERT_DAYS:-3650}" -extfile "${proxy_ext}" \
  -out "${output_dir}/proxy/zabbix_proxy.crt"

chmod 600 "${output_dir}/ca/ca.key" "${output_dir}/server/zabbix_server.key" "${output_dir}/proxy/zabbix_proxy.key"
chmod 644 "${output_dir}/ca/ca.crt" "${output_dir}/server/zabbix_server.crt" "${output_dir}/proxy/zabbix_proxy.crt"
rm -f "${server_ext}" "${proxy_ext}"

if [[ "${CREATE_SECRETS}" == "true" ]]; then
  command -v docker >/dev/null 2>&1 || { echo "docker is required to create Swarm secrets" >&2; exit 1; }
  create_secret_file() {
    local name="$1" file="$2"
    if docker secret inspect "${name}" >/dev/null 2>&1; then
      echo "Secret already exists; leaving it unchanged: ${name}"
    else
      docker secret create "${name}" "${file}" >/dev/null
      echo "Created secret: ${name}"
    fi
  }
  create_secret_file "${ZABBIX_CA_SECRET:?ZABBIX_CA_SECRET is required}" "${output_dir}/ca/ca.crt"
  create_secret_file "${ZABBIX_SERVER_CERT_SECRET:?ZABBIX_SERVER_CERT_SECRET is required}" "${output_dir}/server/zabbix_server.crt"
  create_secret_file "${ZABBIX_SERVER_KEY_SECRET:?ZABBIX_SERVER_KEY_SECRET is required}" "${output_dir}/server/zabbix_server.key"
  create_secret_file "${ZABBIX_PROXY_CERT_SECRET:?ZABBIX_PROXY_CERT_SECRET is required}" "${output_dir}/proxy/zabbix_proxy.crt"
  create_secret_file "${ZABBIX_PROXY_KEY_SECRET:?ZABBIX_PROXY_KEY_SECRET is required}" "${output_dir}/proxy/zabbix_proxy.key"
fi

echo "Certificates generated in ${output_dir}."
