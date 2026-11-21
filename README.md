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

## Public DNS and TLS

Point the frontend hostname to the NLB DNS name using a DNS-only CNAME. The
GitHub repository variable `ZABBIX_FRONTEND_CERTIFICATE_ARN` identifies an
issued AWS Certificate Manager public certificate in `us-east-1` for that
hostname. The certificate is managed outside this Terraform state: retain its
ACM DNS-validation CNAME with the DNS provider for managed renewal.

When the ARN is set, the NLB terminates public HTTPS using the ACM certificate
and establishes a separate TLS connection to Traefik on port 443. AWS NLB does
not validate the certificate presented by TLS targets; the existing Traefik
certificate is signed by the private CA. Zabbix port 10051 remains TCP
passthrough. The private CA and certificates are still used for internal Zabbix
connections. The legacy TCP HTTPS passthrough is retained only when the ACM ARN
is empty; browsers do not trust the private CA unless it is installed locally.

The ACM certificate must already be issued before applying Terraform. The NLB
HTTPS target group and listener transition can temporarily interrupt frontend
connections while targets become healthy. Do not remove the DNS-validation
record after issuance; ACM needs it for renewal.

## Host tuning

The deployment workflow runs `ansible/aws/tuning.yml` on all Swarm nodes before
deploying the stack. It applies the configured kernel values and persists PAM,
systemd and Docker resource limits. Docker and containerd configuration changes
require a planned rolling service restart; systemd manager defaults require a
manager reexecution or reboot. The playbook does not restart cluster services.
Review the tuning values against the available EC2 memory before applying them.

Immediately afterward, `ansible/aws/host-logging.yml` installs and starts
auditd, ensures journald is running with persistent storage, and masks
`systemd-journald-audit.socket`. It also disables the audit syslog plugin if
present. Raw audit records are collected from the audit log instead of being
duplicated in the journal; auditd service messages can still appear there.
The play does not add audit rules. Run it separately with the AWS inventory
to prepare existing nodes before updating the logging Collector.

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

### OpenTelemetry exporter metrics

When `ZABBIX_APM_ENABLED=true`, the metrics stack deploys a single
OpenTelemetry Collector with the image pinned by `OTEL_COLLECTOR_IMAGE`. The
upstream Collector has no LTS image tag; its pinned version is an explicit
exception to the LTS image preference. It scrapes PostgreSQL exporters, pgSCV,
PgBouncer exporters, Patroni, etcd and ClickHouse, plus individual global
node-exporter, process-exporter and cAdvisor tasks discovered via Swarm DNS.
The Collector forwards OTLP/gRPC metrics to the Zabbix proxy over the encrypted
backend overlay. It does not require a Prometheus server or the Docker socket.
One replica prevents duplicate scrapes; Collector failover is not high
availability while that single task is being replaced. Scrape status is exposed
through Prometheus receiver metrics such as `up`; alerting requires separate
Zabbix telemetry query items and triggers.

Register the active proxy in **Administration → Proxies**, enable **Data
collection enabled** on its APM tab, and ensure it synchronizes with the
server. The per-component telemetry provider and its password are configured
via environment variables and a Swarm secret. The global data source in
**Administration → Data source → APM** is separate from per-component provider
overrides and is not automatically populated by those environment variables.
See [Zabbix data source documentation](https://www.zabbix.com/documentation/8.0/en/manual/web_interface/frontend_sections/administration/data_source).
The pipeline uses a memory limiter, a bounded queue, and an allowlist of core
metric families to reduce cardinality. Review the selected metrics, exporter
labels, ingestion volume, and retention for the capacity of the deployment.
When the Collector itself is down, `up` stops arriving; use a no-data alert to
detect that condition.

### Container logs in APM

With APM enabled, the standard metrics deployment also installs an
`otel-logs` global Swarm service: one task per node. Each task reads local
Docker `json-file` container logs through a read-only bind mount, parses the
Docker timestamp and stream, and discovers container, image, Swarm stack,
service and task metadata through the local Docker API. For Swarm containers,
`service.name` is `stack/swarm-service-name`, without the task slot and ID;
for standalone containers it is the
container name. It exports OTLP/gRPC logs to the Zabbix proxy. Its local Docker volume holds file offsets
for that node across task restarts. New deployments start at the end of
existing files; earlier console logs are not automatically imported. File
rotation and finite exporter retry queues mean this is not a guarantee against
log loss during prolonged outages. The reader excludes its own container log
to avoid a feedback loop when exporting fails. The metrics Collector and all
other containers are included. For this configuration, Docker must use its
`json-file` logging driver and retain readable logs under
`/var/lib/docker/containers`.
Recognized explicit severity levels in structured `level`, `severity` or
`log_level` fields and common console prefixes are mapped to OpenTelemetry
severity. Lines without an explicit recognized level retain an unspecified
severity; the stream name or HTTP status alone does not determine severity.

The same global Collector reads each node's persistent journal and
`/var/log/audit/audit.log`. In APM → Logs, filter by `service.name=hosts-swarm`;
the resource `host.name` identifies the node and `job` is `journal` or
`auditd`. Collection starts at the end of existing files or the journal on the
first deployment and resumes from local checkpoints afterward. The host root is
mounted read-only to let the journald receiver run the host's `journalctl` and
read journal and audit files. Journal and audit records may include sensitive
information. Access and retention should be configured accordingly.

Log messages can contain credentials or personal data: review application log
content, access to APM data, and ClickHouse retention before relying on this
pipeline. The tasks require root to read Docker's log files. The log directory is
mounted read-only. The Docker socket is also mounted for discovery; even a
read-only bind mount of the socket grants powerful Docker API access, so treat
the Collector as a privileged component.
