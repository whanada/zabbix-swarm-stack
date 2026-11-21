# GitHub variables and AWS secrets

The AWS workflow uses GitHub OIDC, not permanent AWS access keys. The three IAM
roles have been created and their ARNs configured as repository variables. The
`production` environment is restricted to `main` and requires approval by
`whanada`. All operational steps, including scheduled ECR refresh, wait for
that review. Principal policy simulations passed, but a real approved OIDC run
has not yet been verified. Keep role ARNs and `ZABBIX_*` values as repository
variables.

The reproducible IAM bootstrap is `scripts/iam/bootstrap-github-roles.sh`; it
queries the repository OIDC subject prefix using the GitHub CLI and renders
policies with `scripts/iam/render-policies.py`. Immutable subject IDs are
required when enabled for the repository. The approved Terraform
role can manage EC2 and load balancers in `us-east-1`, the specified state path,
the dedicated SSM bucket, and project node IAM profiles. The Ansible role limits
SSM sessions to instances tagged `Project=zabbix-ha` and the default
`SSM-SessionManagerRunShell` document, secrets to `zabbix-ha/`,
and ECR access to pull. The ECR publisher role can push only to the selected ECR
repository, plus the registry-wide `ecr:GetAuthorizationToken` action.

| Type | Name | Purpose |
| --- | --- | --- |
| Variable | `AWS_TERRAFORM_ROLE_ARN` | Terraform OIDC role. |
| Variable | `AWS_ANSIBLE_ROLE_ARN` | Inventory, SSM, S3, Secrets Manager and ECR pull role. |
| Variable | `AWS_ECR_PUBLISH_ROLE_ARN` | ECR image publication role. |
| Variable | `ZABBIX_FRONTEND_HOST` | Frontend hostname. |
| Variable | `ZABBIX_FRONTEND_CERTIFICATE_ARN` | ARN of the issued ACM certificate used by the HTTPS NLB listener. |
| Variable | `ZABBIX_TCP_HOST` | Zabbix TCP hostname used for SNI. |
| Variable | `ZABBIX_APM_ENABLED` | Enables optional APM when `true`. |
| Variable | `ZABBIX_AMI_ID` | Ubuntu 24.04 LTS AMI in `us-east-1`. |
| Variable | `ZABBIX_MANAGER_INSTANCE_TYPE` | Manager EC2 instance type. |
| Variable | `ZABBIX_WORKER_INSTANCE_TYPE` | Worker EC2 instance type. |
| Variable | `ZABBIX_VOLUME_SIZES_GB` | HCL/JSON map for `postgres`, `etcd`, `clickhouse`, `keeper` and `proxy` disks. |
| Variable | `ZABBIX_ALLOWED_WEB_CIDRS` | HCL/JSON list of CIDRs permitted to reach ingress. |

No Docker Hub token or long-lived AWS secret is required for the ECR operation.

## AWS Secrets Manager

`ansible/aws/bootstrap-aws-secrets.yml` runs the controller-side bootstrap script
to create or recover application passwords, the internal CA, server and proxy
certificates, and a Traefik certificate for `ZABBIX_FRONTEND_HOST`.
`create-secrets.yml` then copies missing values into Swarm secrets before service
startup. An existing valid Traefik certificate and key are preserved; changing
its hostname requires a deliberate coordinated rotation.

The public HTTPS listener uses the ACM certificate identified by
`ZABBIX_FRONTEND_CERTIFICATE_ARN`. The Traefik certificate encrypts the
NLB-to-Traefik connection, although the NLB does not verify that certificate.
The private CA also protects internal Zabbix communication.
The three Zabbix servers share a server certificate; the proxy has a separate
certificate and key.

As requested, the bootstrap appends base64-encoded values to
`.secrets-temp.txt` with mode 0600. Base64 is not encryption: protect this file.
On GitHub Actions the file is on the ephemeral runner and is not published as an
artifact; Secrets Manager remains the persistent source. Local runs retain the
file in the working directory. Swarm secrets are immutable and automatic
credential or certificate rotation is not implemented.
