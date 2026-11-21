# Separate non-versioned transfer bucket: SSM Ansible modules can contain
# transient credentials; do not use the versioned Terraform state bucket.
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "ansible_transfer" {
  bucket        = "${var.project_name}-${data.aws_caller_identity.current.account_id}-${var.aws_region}-ssm"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "ansible_transfer" {
  bucket                  = aws_s3_bucket.ansible_transfer.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ansible_transfer" {
  bucket = aws_s3_bucket.ansible_transfer.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "ansible_transfer" {
  bucket = aws_s3_bucket.ansible_transfer.id
  rule {
    id     = "expire-transient-ansible-files"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
  }
}

output "ansible_transfer_bucket" {
  value = aws_s3_bucket.ansible_transfer.id
}
