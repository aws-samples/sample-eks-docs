# Durable checkpoint storage, the same on both paths.
#
# This is where agent state goes that has to outlive the pod that produced it: a checkpoint an
# agent resumes from, the record of what it did, the staged files an execution-tier pod hands back.
# Object storage is the whole answer and both paths use Amazon S3.
#
# It is a separate layer from session state, not a cheaper version of it. An agent touches this
# once per session; it touches session state once per turn. A team running the split agent in
# gitops/examples/reasoning-execution-split reaches for this first, because a volume and a bucket
# are the only channel the execution tier has.

data "aws_caller_identity" "current" {}

locals {
  tags = merge(var.tags, {
    "app.kubernetes.io/part-of" = "eks-agents-paved-paths"
    ManagedBy                   = "terraform/modules/durable-storage"
  })
}

resource "aws_s3_bucket" "checkpoints" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy
  tags          = local.tags
}

resource "aws_s3_bucket_ownership_controls" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Agent checkpoints are not public under any circumstance. All four settings, so an account-level
# change or a later bucket policy edit cannot open this bucket by accident.
resource "aws_s3_bucket_public_access_block" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn == null ? "AES256" : "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }

    # Cuts KMS request cost and latency when an agent writes many objects under one prefix, which is
    # the access pattern a staging execution tier produces.
    bucket_key_enabled = var.kms_key_arn != null
  }
}

# An agent that resumes from a checkpoint reads the current version. Old versions are the audit
# trail and the recovery path, and they are not worth keeping forever.
resource "aws_s3_bucket_lifecycle_configuration" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  dynamic "rule" {
    for_each = var.current_version_expiration_days == null ? [] : [1]

    content {
      id     = "expire-checkpoints"
      status = "Enabled"

      filter {}

      expiration {
        days = var.current_version_expiration_days
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.checkpoints]
}

# Deny anything that is not TLS, and deny any principal outside this account. The second statement
# is the data-perimeter half: an agent's checkpoint bucket has no reason to be readable by a
# principal the organization does not control, and a bucket policy is the only place that can be
# said once rather than per agent role.
data "aws_iam_policy_document" "checkpoints" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.checkpoints.arn, "${aws_s3_bucket.checkpoints.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyPrincipalsOutsideThisOrganization"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.checkpoints.arn, "${aws_s3_bucket.checkpoints.arn}/*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = var.organization_id == null ? "StringNotEquals" : "StringNotEqualsIfExists"
      variable = var.organization_id == null ? "aws:PrincipalAccount" : "aws:PrincipalOrgID"
      values   = var.organization_id == null ? [data.aws_caller_identity.current.account_id] : [var.organization_id]
    }
  }
}

resource "aws_s3_bucket_policy" "checkpoints" {
  bucket = aws_s3_bucket.checkpoints.id
  policy = data.aws_iam_policy_document.checkpoints.json

  depends_on = [aws_s3_bucket_public_access_block.checkpoints]
}
