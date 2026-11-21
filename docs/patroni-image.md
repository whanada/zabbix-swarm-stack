# Patroni and TimescaleDB image in ECR

The custom image combines TimescaleDB/PostgreSQL, Patroni, and the official
PostgreSQL and ClickHouse schema scripts for the selected Zabbix version.
Ansible builds and tests it before publication. Configure the image versions,
`ECR_REGISTRY`, `ECR_REPOSITORY` and `PATRONI_IMAGE` in `.env`.

```bash
cp .env.example .env # Only if .env does not already exist.
set -a; source .env; set +a
ansible-playbook -i localhost, ansible/publish-patroni-image.yml --check
ansible-playbook -i localhost, ansible/publish-patroni-image.yml
```

A valid AWS session with ECR read and push access, Docker and Ansible are
required. The preflight verifies the account, repository and versions, and
refuses to overwrite an existing tag even if the repository is mutable. The
tests initialize PostgreSQL, enable TimescaleDB, apply the Zabbix schema and
verify ten hypertables. The playbook logs in with a short-lived token and
removes its temporary Docker configuration afterward.

The manual GitHub workflow **Build and publish Patroni TimescaleDB image** uses
OIDC through `AWS_ECR_PUBLISH_ROLE_ARN`; it does not require a Docker Hub token.
The workflow itself remains to be tested after the code is pushed.

ECR authentication tokens expire after 12 hours. Ansible passes a fresh token
to Swarm during deployment. **Refresh Swarm ECR credentials** refreshes the
three Patroni services every six hours and can be run manually. A running task
does not stop when the token expires, but a later image pull can fail. Monitor
workflow failures and scheduling delays: GitHub does not guarantee an exact
schedule. The refresh playbook was tested on a temporary local Swarm service,
not yet on the AWS cluster.
