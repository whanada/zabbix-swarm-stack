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

The single GitHub workflow supports the `publish-image` operation using OIDC
through `AWS_ECR_PUBLISH_ROLE_ARN`. It requires approval in `production` and does
not require a Docker Hub token. The approved workflow has not yet been tested.

ECR tokens expire after 12 hours. The six-hour scheduled refresh also requires
human approval; monitor pending approvals and failures so replacement tasks can
pull the image. GitHub does not guarantee an exact schedule. The refresh playbook
was tested on a temporary local Swarm service, not yet on the AWS cluster.
