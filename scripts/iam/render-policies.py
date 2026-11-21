#!/usr/bin/env python3
"""Render IAM documents for the dedicated Zabbix GitHub Actions roles."""
import json
import os
from pathlib import Path

account = os.environ['BOOTSTRAP_AWS_ACCOUNT']
repo = os.environ.get('BOOTSTRAP_GITHUB_REPO', 'whanada/zabbix-swarm-stack')
region = os.environ.get('AWS_REGION', 'us-east-1')
bucket = os.environ.get('BOOTSTRAP_STATE_BUCKET', 'tf-states-whanada')
state = os.environ.get('BOOTSTRAP_STATE_KEY', 'zabbix-ha/aws/terraform.tfstate')
project = os.environ.get('BOOTSTRAP_PROJECT', 'zabbix-ha')
out = Path(os.environ['BOOTSTRAP_POLICY_DIR'])
provider = f'arn:aws:iam::{account}:oidc-provider/token.actions.githubusercontent.com'
transfer = f'{project}-{account}-{region}-ssm'
role_prefix = f'arn:aws:iam::{account}:role/{project}-node-*'
profile_prefix = f'arn:aws:iam::{account}:instance-profile/{project}-node-*'
managed_ssm = 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'
ecr_repository = os.environ.get('BOOTSTRAP_ECR_REPOSITORY', 'whanada/zabbix-ha-stack')
ecr_arn = f'arn:aws:ecr:{region}:{account}:repository/{ecr_repository}'


def statement(actions, resources, **extra):
    return {'Effect': 'Allow', 'Action': actions, 'Resource': resources, **extra}


def trust(subjects):
    return {'Version': '2012-10-17', 'Statement': [{
        'Effect': 'Allow', 'Principal': {'Federated': provider}, 'Action': 'sts:AssumeRoleWithWebIdentity',
        'Condition': {'StringEquals': {'token.actions.githubusercontent.com:aud': 'sts.amazonaws.com',
                                      'token.actions.githubusercontent.com:sub': subjects}}
    }]}


def policy(statements):
    return {'Version': '2012-10-17', 'Statement': statements}


state_bucket = f'arn:aws:s3:::{bucket}'
state_object = f'{state_bucket}/{state}'
transfer_bucket = f'arn:aws:s3:::{transfer}'
state_read = [
    statement(['s3:GetBucketLocation'], state_bucket),
    statement(['s3:ListBucket'], state_bucket, Condition={'StringLike': {'s3:prefix': [state, state + '.tflock']}}),
    statement(['s3:GetObject'], [state_object, state_object + '.tflock']),
]
terraform = policy(state_read + [
    statement(['s3:PutObject'], [state_object, state_object + '.tflock']),
    statement(['s3:DeleteObject'], state_object + '.tflock'),
    statement(['s3:*'], [transfer_bucket, transfer_bucket + '/*']),
    statement(['ec2:*', 'elasticloadbalancing:*'], '*', Condition={'StringEquals': {'aws:RequestedRegion': region}}),
    statement(['servicequotas:GetServiceQuota'], '*', Condition={'StringEquals': {'aws:RequestedRegion': region}}),
    statement(['iam:CreateRole', 'iam:DeleteRole', 'iam:GetRole', 'iam:TagRole', 'iam:UntagRole',
               'iam:ListRoleTags', 'iam:ListRolePolicies', 'iam:ListAttachedRolePolicies',
               'iam:ListInstanceProfilesForRole'], role_prefix),
    statement(['iam:AttachRolePolicy', 'iam:DetachRolePolicy'], role_prefix,
              Condition={'ArnEquals': {'iam:PolicyARN': managed_ssm}}),
    statement(['iam:CreateInstanceProfile', 'iam:DeleteInstanceProfile', 'iam:GetInstanceProfile',
               'iam:TagInstanceProfile', 'iam:UntagInstanceProfile', 'iam:ListInstanceProfileTags',
               'iam:AddRoleToInstanceProfile', 'iam:RemoveRoleFromInstanceProfile'], profile_prefix),
    statement(['iam:PassRole'], role_prefix, Condition={'StringEquals': {'iam:PassedToService': 'ec2.amazonaws.com'}}),
    statement(['iam:CreateServiceLinkedRole'], f'arn:aws:iam::{account}:role/aws-service-role/elasticloadbalancing.amazonaws.com/AWSServiceRoleForElasticLoadBalancing',
              Condition={'StringEquals': {'iam:AWSServiceName': 'elasticloadbalancing.amazonaws.com'}}),
    statement(['iam:GetPolicy', 'iam:GetPolicyVersion'], managed_ssm),
])
ansible = policy(state_read + [
    statement(['ecr:GetAuthorizationToken'], '*'),
    statement(['ecr:BatchCheckLayerAvailability', 'ecr:BatchGetImage', 'ecr:GetDownloadUrlForLayer'], ecr_arn),
    statement(['ec2:DescribeInstances', 'ec2:DescribeVolumes', 'ec2:DescribeRegions',
               'ssm:DescribeInstanceInformation'], '*', Condition={'StringEquals': {'aws:RequestedRegion': region}}),
    statement(['ssm:StartSession'], f'arn:aws:ec2:{region}:{account}:instance/*',
              Condition={'StringEquals': {'ssm:resourceTag/Project': project}}),
    statement(['ssm:TerminateSession', 'ssm:ResumeSession', 'ssmmessages:OpenDataChannel'],
              f'arn:aws:ssm:{region}:{account}:session/*'),
    statement(['s3:GetBucketLocation', 's3:ListBucket'], transfer_bucket),
    statement(['s3:GetObject', 's3:PutObject', 's3:DeleteObject'], transfer_bucket + '/*'),
    statement(['secretsmanager:CreateSecret', 'secretsmanager:GetSecretValue', 'secretsmanager:DescribeSecret',
               'secretsmanager:PutSecretValue', 'secretsmanager:TagResource'],
              f'arn:aws:secretsmanager:{region}:{account}:secret:{project}/*'),
])
publisher = policy([
    statement(['ecr:GetAuthorizationToken'], '*'),
    statement(['ecr:DescribeRepositories', 'ecr:DescribeImages', 'ecr:BatchCheckLayerAvailability',
               'ecr:BatchGetImage', 'ecr:GetDownloadUrlForLayer', 'ecr:InitiateLayerUpload',
               'ecr:UploadLayerPart', 'ecr:CompleteLayerUpload', 'ecr:PutImage'], ecr_arn),
])
files = {
    'terraform-trust.json': trust([f'repo:{repo}:ref:refs/heads/main', f'repo:{repo}:environment:production']),
    'ansible-trust.json': trust([f'repo:{repo}:environment:production']),
    'terraform-policy.json': terraform,
    'ansible-policy.json': ansible,
    'ecr-trust.json': trust([f'repo:{repo}:environment:production']),
    'ecr-policy.json': publisher,
}
for name, data in files.items():
    (out / name).write_text(json.dumps(data, indent=2) + '\n')
