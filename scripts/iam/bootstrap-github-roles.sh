#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
export BOOTSTRAP_GITHUB_REPO="${BOOTSTRAP_GITHUB_REPO:-whanada/zabbix-swarm-stack}"
export BOOTSTRAP_PROJECT="${BOOTSTRAP_PROJECT:-zabbix-ha}"
export BOOTSTRAP_STATE_BUCKET="${BOOTSTRAP_STATE_BUCKET:-tf-states-whanada}"
export BOOTSTRAP_STATE_KEY="${BOOTSTRAP_STATE_KEY:-zabbix-ha/aws/terraform.tfstate}"
: "${EXPECTED_AWS_ACCOUNT:?Set EXPECTED_AWS_ACCOUNT to the expected AWS account number}"
export BOOTSTRAP_AWS_ACCOUNT
BOOTSTRAP_AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[[ "$BOOTSTRAP_AWS_ACCOUNT" == "$EXPECTED_AWS_ACCOUNT" ]] || { echo 'AWS account mismatch' >&2; exit 1; }
[[ "$AWS_REGION" == us-east-1 ]] || { echo 'Expected us-east-1' >&2; exit 1; }
aws s3api head-bucket --bucket "$BOOTSTRAP_STATE_BUCKET" --expected-bucket-owner "$BOOTSTRAP_AWS_ACCOUNT" >/dev/null
provider="arn:aws:iam::${BOOTSTRAP_AWS_ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"
aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$provider" --query 'ClientIDList' --output text | grep -qw sts.amazonaws.com
# Use GitHub's configured OIDC subject prefix, including immutable IDs when enabled.
export BOOTSTRAP_OIDC_SUBJECT_PREFIX
BOOTSTRAP_OIDC_SUBJECT_PREFIX=$(gh api "repos/${BOOTSTRAP_GITHUB_REPO}/actions/oidc/customization/sub" --jq .sub_claim_prefix)
[[ "$BOOTSTRAP_OIDC_SUBJECT_PREFIX" == repo:* && "$BOOTSTRAP_OIDC_SUBJECT_PREFIX" != *:*:* ]] || {
  echo 'GitHub did not return a supported OIDC subject prefix' >&2
  exit 1
}
export BOOTSTRAP_POLICY_DIR
BOOTSTRAP_POLICY_DIR=$(mktemp -d)
trap 'rm -rf "$BOOTSTRAP_POLICY_DIR"' EXIT
python3 "$(dirname "$0")/render-policies.py"
for kind in terraform ansible ecr; do
  role="${BOOTSTRAP_PROJECT}-${kind}-github"
  trust="$BOOTSTRAP_POLICY_DIR/${kind}-trust.json"
  policy="$BOOTSTRAP_POLICY_DIR/${kind}-policy.json"
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    owner=$(aws iam list-role-tags --role-name "$role" --query "Tags[?Key=='ManagedBy'].Value | [0]" --output text)
    project_tag=$(aws iam list-role-tags --role-name "$role" --query "Tags[?Key=='Project'].Value | [0]" --output text)
    [[ "$owner" == zabbix-iam-bootstrap && "$project_tag" == "$BOOTSTRAP_PROJECT" ]] || {
      echo "Refusing to update role $role: ownership tags do not match" >&2
      exit 1
    }
    aws iam update-assume-role-policy --role-name "$role" --policy-document "file://$trust"
  else
    aws iam create-role --role-name "$role" --assume-role-policy-document "file://$trust" \
      --description "GitHub Actions ${kind} for ${BOOTSTRAP_GITHUB_REPO}" \
      --tags "Key=Project,Value=$BOOTSTRAP_PROJECT" 'Key=ManagedBy,Value=zabbix-iam-bootstrap' >/dev/null
  fi
  aws iam put-role-policy --role-name "$role" --policy-name "${BOOTSTRAP_PROJECT}-${kind}" --policy-document "file://$policy"
  printf '%s role ARN: arn:aws:iam::%s:role/%s\n' "$kind" "$BOOTSTRAP_AWS_ACCOUNT" "$role"
done
