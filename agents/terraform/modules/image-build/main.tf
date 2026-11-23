################################################################################
# Agent image builds in AWS CodeBuild
#
# scripts/build-images.sh --root uploads the working tree here and starts one build, which runs the
# same script inside CodeBuild with Docker: native for the node architecture, next to ECR, and with
# nothing to install on the workstation. Terraform creates only the project, so `apply` builds
# nothing and is no slower. With agent_image_registry set to a registry that already holds the
# images, there is nothing to build.
################################################################################

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  project = "${var.name}-agent-images"
  image   = var.architecture == "arm64" ? "aws/codebuild/amazonlinux-aarch64-standard:4.0" : "aws/codebuild/amazonlinux-x86_64-standard:6.0"
  type    = var.architecture == "arm64" ? "ARM_CONTAINER" : "LINUX_CONTAINER"
}

# ---------------------------------------------------------------------------
# Where the working tree is staged for a build
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "source" {
  bucket        = "${var.name}-image-build-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "source" {
  bucket                  = aws_s3_bucket.source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "source" {
  bucket = aws_s3_bucket.source.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "source" {
  bucket = aws_s3_bucket.source.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# A staged tree is used once, by the build it was uploaded for.
resource "aws_s3_bucket_lifecycle_configuration" "source" {
  bucket = aws_s3_bucket.source.id
  rule {
    id     = "expire-build-contexts"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "source_tls_only" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.source.arn, "${aws_s3_bucket.source.arn}/*"]
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
}

resource "aws_s3_bucket_policy" "source" {
  bucket     = aws_s3_bucket.source.id
  policy     = data.aws_iam_policy_document.source_tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.source]
}

# ---------------------------------------------------------------------------
# The build's role: read its source, write its log, push to this stack's repositories
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "builds" {
  name              = "/aws/codebuild/${local.project}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
    # Only this account's project, so no other account's build can use the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${data.aws_partition.current.partition}:codebuild:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:project/${local.project}"]
    }
  }
}

resource "aws_iam_role" "build" {
  name               = "${var.name}-image-build"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  description        = "Builds ${var.name}'s agent images in CodeBuild and pushes them to its ECR repositories."
  tags               = var.tags
}

data "aws_iam_policy_document" "build" {
  statement {
    sid       = "ReadTheStagedTree"
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.source.arn}/*"]
  }
  statement {
    sid       = "WriteTheBuildLog"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.builds.arn}:*"]
  }
  statement {
    sid       = "LogInToECR"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    sid = "PushToThisStacksRepositories"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "build" {
  name   = "image-build"
  role   = aws_iam_role.build.id
  policy = data.aws_iam_policy_document.build.json
}

# ---------------------------------------------------------------------------
# The project
# ---------------------------------------------------------------------------

resource "aws_codebuild_project" "images" {
  name          = local.project
  description   = "Builds ${var.name}'s agent images from a staged working tree (scripts/build-images.sh --root)."
  service_role  = aws_iam_role.build.arn
  build_timeout = 60

  # build-images.sh overrides the object key per build; this is only the project's default.
  source {
    type      = "S3"
    location  = "${aws_s3_bucket.source.bucket}/build-context/latest.zip"
    buildspec = <<-YAML
      version: 0.2
      phases:
        build:
          commands:
            # RUN_STACK: already where the build belongs, so the script builds here.
            - RUN_STACK=1 bash ./scripts/build-images.sh --urls ecr-urls.json --tag "$TAG" --platform "$PLATFORM"
    YAML
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type         = local.type
    image        = local.image
    compute_type = var.compute_type
    # Docker inside the build container. The build runs only this stack's own Dockerfiles.
    privileged_mode = true

    environment_variable {
      name  = "TAG"
      value = "v1"
    }
    environment_variable {
      name  = "PLATFORM"
      value = var.architecture == "arm64" ? "linux/arm64" : "linux/amd64"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.builds.name
    }
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy.build]
}
