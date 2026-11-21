# Zabbix 8 HA on AWS and Docker Swarm

This project is being refactored for six EC2 instances in `us-east-1`: three
public Swarm managers and three private workers. Terraform provisions the VPC,
Network Load Balancer (NLB), instances and dedicated encrypted EBS volumes.
Ansible configures the Swarm and deploys Zabbix, Traefik, the data services and
exporters. The overlay networks, including ingress, use Swarm encryption.

**Status:** the infrastructure plan, image build, registry authentication and
selected component tests have passed. The complete AWS deployment, OIDC
workflows, APM ingestion and failover have not yet been validated end to end.
Do not treat this stack as production-ready until those checks pass.

The stack includes three Zabbix HA servers, a frontend, proxy 001, Selenium,
web service, three Patroni/TimescaleDB instances, etcd, ClickHouse and ClickHouse
Keeper, redundant HAProxy and PgBouncer, and per-component exporters. The
exporters expose metrics on the encrypted overlay. **No Prometheus server is
included.**

## Architecture

- [AWS infrastructure](docs/architecture-aws.svg) ([PNG](docs/architecture-aws.png))
- [Swarm services and data flow](docs/architecture-stack.svg) ([PNG](docs/architecture-stack.png))
- [GitHub Actions and deployment workflow](docs/architecture-deployment.svg) ([PNG](docs/architecture-deployment.png))

Diagrams describe the intended deployment. See [design and validation notes](docs/zabbix-8-design-notes.md)
for limitations and the checks still required.

## Prerequisites

Install Docker, Ansible, Terraform, AWS CLI and the AWS Session Manager plugin on
the controller. Install the collections and Python dependencies:

```bash
python3 -m pip install 'ansible-core>=2.17,<2.20' boto3 'botocore[crt]' cryptography
ansible-galaxy collection install -r ansible/requirements.yml -p ansible/collections
```

Copy `.env.example` to `.env`, review the pinned images and `ZBX_*` settings,
and export the variables before using Ansible:

```bash
cp .env.example .env # Only if .env does not already exist.
set -a; source .env; set +a
```

Ansible does not load `.env` automatically. GitHub Actions reads the committed
`.env.example` and the repository variables listed in [GitHub configuration](docs/github-secrets.md).
The memory and process defaults are starting values and must be sized for the
actual workload. Keep `.env` out of version control.

The Patroni image is built, tested and published to private ECR through
[the image playbook](docs/patroni-image.md). A revised image must be published
before a deployment that references its new tag.

## Deployment through GitHub Actions

The workflows are manual and independent; committing or pushing starts the
validation workflow but does not automatically apply infrastructure or deploy
the stack. The OIDC roles and repository variables have been configured, but a
real workflow run has not yet verified their permissions.

1. Commit and push the reviewed project changes. Run **AWS infrastructure plan
   and apply** with `apply` disabled, and inspect the plan. The S3 backend is
   `tf-states-whanada/zabbix-ha/aws/terraform.tfstate`.
2. Run the same workflow with `apply` enabled after reviewing its plan. It
   checks the Elastic IP quota before provisioning. The current design uses one
   shared NAT gateway and three fixed NLB addresses: four Elastic IPs in total.
3. Run **AWS prepare Swarm nodes**. Ansible joins three managers and three workers,
   creates encrypted ingress, assigns placement labels and prepares each EBS disk.
4. Run **AWS deploy monitoring stack**. Ansible prepares secrets, data services,
   database schemas, exporters and the application. This workflow still needs
   end-to-end validation before production use.
5. Run the validation and failover checks in [design notes](docs/zabbix-8-design-notes.md).

**Build and publish Patroni TimescaleDB image** publishes a new image tag to ECR.
**Refresh Swarm ECR credentials** refreshes the Patroni service credentials
periodically and can also be run manually. Scheduled refresh depends on the
cluster and the Ansible OIDC role being available.

A single NAT gateway reduces cost but makes worker outbound connectivity
dependent on one availability zone. EC2, EBS, NAT, NLB, public IPv4 addresses
and Secrets Manager are billable.

## Local name resolution and TLS

The intended name is `zabbix.wildeshanada.com`, resolved using the client's
`hosts` file rather than public DNS. After apply, Terraform output
`ingress_public_ips` contains the three fixed NLB addresses. Add the name and
an appropriate address to the client's `hosts` file. A client pinned to a single
address depends on that NLB zone; test how the client handles alternative IPs.

Ansible generates a private CA and a frontend certificate. The browser will
trust the certificate only after the public CA certificate is installed in the
client's trust store. Retrieve the public certificate without exposing the key:

```bash
aws secretsmanager get-secret-value --region us-east-1 \
  --secret-id zabbix-ha/zabbix_ca --query SecretString --output text > zabbix-ha-ca.crt
```

Protect the CA private key. Swarm secrets are immutable, and certificate
renewal and rotation are not yet automated.

## Local checks

```bash
set -a; source .env; set +a
ansible-playbook -i localhost, ansible/aws/preflight-images.yml
ansible-playbook -i localhost, --syntax-check ansible/aws/site.yml
python3 tests/validate_stack_templates.py
python3 tests/test_aws_certificates.py
tests/test-pgscv-integration.sh
tests/test-pgbouncer-integration.sh
# Use an existing encrypted test overlay for the ECR refresh test.
ZABBIX_TEST_ENCRYPTED_NETWORK=YOUR_TEST_NETWORK tests/test-ecr-auth-refresh.sh
```

The integration tests create and remove temporary test containers or services
and require their pinned images and Docker access. The node exporter runs on an
encrypted overlay, so its network-namespace metrics can differ from host network
metrics. cAdvisor mounts `/var/run` to inspect Docker; assess that privileged
access before deployment. Static checks and Ansible check mode do not replace a
real distributed deployment or failover test.

To regenerate the architecture diagrams, install ImageMagick and run `python3 docs/generate_architecture.py`.
