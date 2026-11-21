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
python3 -m pip install 'ansible-core>=2.19,<2.20' 'ansible-lint==25.9.2' boto3 'botocore[crt]' cryptography
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

The single **Validate and deploy Zabbix HA** workflow runs Terraform and Ansible
validation, including ansible-lint, on pushes and pull requests. Deployment operations start only through
`workflow_dispatch` or the ECR refresh schedule. After both validations pass,
the `production` environment requires an explicit review by `whanada` before
any operational job starts. Configure and verify this protection rule in GitHub;
an environment name alone does not enforce approval.

1. Commit and push the changes; confirm the validation run passes.
2. Run the workflow manually and select `deploy`. Review the selected operation
   and approve the waiting production job in GitHub Actions.
3. After approval, the job checks the Elastic IP quota, creates a Terraform plan
   and immediately applies that same plan, then prepares the Swarm, EBS volumes
   and application stack. The plan is available in the job log, but there is no
   second approval between planning and applying. Review infrastructure changes
   separately before approving the job. State is stored at
   `tf-states-whanada/zabbix-ha/aws/terraform.tfstate`.
4. Run the validation and failover checks in [design notes](docs/zabbix-8-design-notes.md).

Select `publish-image` to build, test and publish a new ECR image tag, or
`refresh-ecr` to refresh Swarm registry credentials. Both require approval.
Scheduled ECR refresh runs are created every six hours but also wait for human
approval: without timely approval the 12-hour ECR token expires and replacement
tasks may be unable to pull their image. Scheduled runs can be delayed or skipped
by GitHub. Monitor approvals and refresh failures. The complete workflow still
requires end-to-end validation before production use.

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

## Host tuning

The deployment workflow runs `ansible/aws/tuning.yml` on all Swarm nodes before
deploying the stack. It applies the configured kernel values and persists PAM,
systemd and Docker resource limits. Docker and containerd configuration changes
require a planned rolling service restart; systemd manager defaults require a
manager reexecution or reboot. The playbook does not restart cluster services.
Review the tuning values against the available EC2 memory before applying them.

## Ansible log privacy

Deployment plays default to `no_log: true` and the GitHub workflow explicitly
enables it. Task names, host identifiers, play recap, and task timings can still
appear; Terraform output is separate and remains visible in public Actions logs.
Failures will be censored. For troubleshooting only on a trusted controller with
private logs, set `ZABBIX_ANSIBLE_NO_LOG=false`. Tasks that handle passwords,
join tokens, and registry credentials still enforce `no_log: true`.
Do not enable debug logging or print inventory variables in public workflows.

## Local checks

```bash
set -a; source .env; set +a
ansible-lint --offline -p ansible/*.yml ansible/aws/*.yml
ansible-playbook -i localhost, ansible/aws/preflight-images.yml
ansible-playbook -i localhost, --syntax-check ansible/aws/site.yml
python3 tests/validate_stack_templates.py
python3 tests/test_aws_certificates.py
tests/test-pgscv-integration.sh
tests/test-pgbouncer-integration.sh
# Use an existing encrypted test overlay for the ECR refresh test.
ZABBIX_TEST_ENCRYPTED_NETWORK=YOUR_TEST_NETWORK tests/test-ecr-auth-refresh.sh
```

Existing lint debt is listed in `.ansible-lint-ignore` and remains visible as
warnings. Ignores apply per file and rule, so additional findings of the same
rule in an ignored file are also suppressed. Remove entries as the debt is fixed.

The integration tests create and remove temporary test containers or services
and require their pinned images and Docker access. The node exporter runs on an
encrypted overlay, so its network-namespace metrics can differ from host network
metrics. cAdvisor mounts `/var/run` to inspect Docker; assess that privileged
access before deployment. Static checks and Ansible check mode do not replace a
real distributed deployment or failover test.

To regenerate the architecture diagrams, install ImageMagick and run `python3 docs/generate_architecture.py`.
