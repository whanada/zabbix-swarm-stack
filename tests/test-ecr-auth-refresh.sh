#!/bin/bash
set -Eeuo pipefail
: "${PATRONI_IMAGE:?Load .env before testing}"
: "${ECR_REGISTRY:?Load .env before testing}"
: "${AWS_REGION:?Load .env before testing}"
: "${ZABBIX_TEST_ENCRYPTED_NETWORK:?Set an existing encrypted overlay network}"
export AWS_DEFAULT_REGION="$AWS_REGION"
# Docker renders the encrypted option as an empty string; check its presence.
docker network inspect "$ZABBIX_TEST_ENCRYPTED_NETWORK" --format '{{json .Options}}' | grep -q '"encrypted"'
name="zbx-ecr-test-$$"
docker_config=$(mktemp -d)
cleanup() { docker service rm "$name" >/dev/null 2>&1 || true; rm -rf "$docker_config"; }
trap cleanup EXIT
export DOCKER_CONFIG="$docker_config"
printf '[swarm_manager_primary]\nlocalhost ansible_connection=local\n' > "$docker_config/inventory"
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY" >/dev/null 2>&1
docker service create --no-resolve-image --detach=true --with-registry-auth --network "$ZABBIX_TEST_ENCRYPTED_NETWORK" --name "$name" --entrypoint /bin/sh "$PATRONI_IMAGE" -c 'sleep 300' >/dev/null
for i in $(seq 1 30); do
  id=$(docker service ps --no-trunc --filter desired-state=running --format '{{.ID}} {{.CurrentState}}' "$name" | awk '$2=="Running"{print $1; exit}')
  if [ -n "$id" ]; then break; fi
  sleep 1
done
test -n "${id:-}"
ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/ansible-zabbix}" \
  ansible-playbook -i "$docker_config/inventory" ansible/aws/refresh-ecr-auth.yml \
  -e "{\"ansible_become\":false,\"ecr_auth_temp_path\":\"/tmp\",\"patroni_services\":[\"$name\"]}" >/dev/null
sleep 5
new_id=$(docker service ps --no-trunc --filter desired-state=running --format '{{.ID}} {{.CurrentState}}' "$name" | awk '$2=="Running"{print $1; exit}')
[ "$id" = "$new_id" ] || { echo 'Registry refresh changed the running task' >&2; exit 1; }
echo 'ECR login and Swarm credential refresh retained the running task'
