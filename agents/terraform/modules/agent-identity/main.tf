# One agent's AWS identity: an IAM role, its trust policy, its permission policy, and the EKS Pod
# Identity association that delivers it to the pod.
#
# This is the per-agent half of the stack in Terraform. A platform team that drives agents from the
# cluster instead gets the same four objects composed by kro through ACK from one agent-shaped
# resource; see gitops/base/templates/. The two are alternatives, not layers: pick the one that matches
# where the team wants the agent declared, and do not run both against the same agent.
#
# What makes this per-agent rather than per-cluster is the condition in the permission policy. Pod
# Identity attaches the cluster name, cluster ARN, namespace, service account, pod name and pod UID
# to every session it issues, with nothing to configure. A policy that reads those as conditions
# scopes an agent even where several agents share one role.

# ---------------------------------------------------------------------------
# Deriving every ARN a model call can touch
# ---------------------------------------------------------------------------

# An inference profile is one ARN that fans out to a foundation model in several regions, and
# Bedrock authorizes against whichever one it routed to. Reading the profile means the policy covers
# every region it can route to without anyone maintaining that list by hand -- and when AWS adds a
# region to a profile, the next apply picks it up instead of producing an intermittent 403.
data "aws_bedrock_inference_profile" "granted" {
  for_each = toset(var.bedrock_inference_profile_ids)

  inference_profile_id = each.value
}

locals {
  # The profile ARNs themselves, which is what the model id resolves to on the call.
  inference_profile_arns = [
    for p in data.aws_bedrock_inference_profile.granted : p.inference_profile_arn
  ]

  # Every foundation model each profile can route to, in every region it covers.
  inference_profile_model_arns = flatten([
    for p in data.aws_bedrock_inference_profile.granted : [for m in p.models : m.model_arn]
  ])

  # Explicit ARNs still work, for a model invoked in-region or an ARN a profile does not cover.
  all_model_arns = distinct(concat(
    var.bedrock_model_arns,
    local.inference_profile_arns,
    local.inference_profile_model_arns,
  ))
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  service_account   = coalesce(var.service_account, var.agent_name)
  checkpoint_prefix = coalesce(var.checkpoint_prefix, "agents/${var.agent_name}/")

  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  # A guardrail is only required if both the ARN and the version are given. Requiring an ARN with
  # no version would deny every call, because the condition could never be satisfied.
  require_guardrail = var.bedrock_guardrail_arn != null && var.bedrock_guardrail_version != null

  tags = merge(var.tags, {
    "app.kubernetes.io/part-of" = "eks-agents-paved-paths"
    "eks-agents/agent"          = var.agent_name
    "eks-agents/cluster"        = var.cluster_name
    ManagedBy                   = "terraform/modules/agent-identity"
  })
}

# ---------------------------------------------------------------------------
# Trust policy
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  # The EKS Pod Identity service, restricted to this cluster. Without the condition, this role could
  # be delivered to a service account of the same name on any cluster in the account.
  statement {
    sid     = "EksPodIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.cluster_arn]
    }
  }

  # The egress gateway, on this stack. The gateway holds nothing beyond permission to assume
  # the set of agent roles; what it may do as any one agent is that agent's own policy below.
  dynamic "statement" {
    for_each = length(var.assumable_by_role_arns) > 0 ? [1] : []

    content {
      sid     = "EgressGatewayActingAsThisAgent"
      effect  = "Allow"
      actions = ["sts:AssumeRole", "sts:TagSession"]

      principals {
        type        = "AWS"
        identifiers = var.assumable_by_role_arns
      }

      # Bind the session to this agent's identity. Without it, the gateway's role can assume any
      # agent role it is listed on, so a routing mistake becomes an authorization mistake.
      dynamic "condition" {
        for_each = var.gateway_identity_claim != null ? [1] : []

        content {
          test     = "StringEquals"
          variable = "sts:ExternalId"
          values   = [var.gateway_identity_claim]
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Permission policy
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "permissions" {
  # Model inference, scoped to the model ARNs this agent is granted.
  dynamic "statement" {
    for_each = length(local.all_model_arns) > 0 ? [1] : []

    content {
      sid    = "InvokeGrantedModels"
      effect = "Allow"

      actions = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:Converse",
        "bedrock:ConverseStream",
      ]

      resources = local.all_model_arns

      # Require the guardrail on every request. This is an authorization condition rather than a
      # default, so an agent that omits the guardrail gets AccessDenied instead of an ungoverned
      # response.
      dynamic "condition" {
        for_each = local.require_guardrail ? [1] : []

        content {
          test     = "StringEquals"
          variable = "bedrock:GuardrailIdentifier"
          values   = ["${var.bedrock_guardrail_arn}:${var.bedrock_guardrail_version}"]
        }
      }
    }
  }

  dynamic "statement" {
    for_each = local.require_guardrail ? [1] : []

    content {
      sid       = "ApplyGuardrail"
      effect    = "Allow"
      actions   = ["bedrock:ApplyGuardrail"]
      resources = [var.bedrock_guardrail_arn]
    }
  }

  # Durable checkpoint storage, scoped to this agent's prefix. Two statements: the object actions on
  # the prefix, and a ListBucket restricted to it, because ListBucket is a bucket-level action and a
  # resource ARN alone would let this agent enumerate every other agent's checkpoints.
  dynamic "statement" {
    for_each = var.checkpoint_bucket_arn != null ? [1] : []

    content {
      sid    = "AgentCheckpointObjects"
      effect = "Allow"

      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:AbortMultipartUpload",
      ]

      resources = ["${var.checkpoint_bucket_arn}/${local.checkpoint_prefix}*"]
    }
  }

  dynamic "statement" {
    for_each = var.checkpoint_bucket_arn != null ? [1] : []

    content {
      sid       = "AgentCheckpointList"
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = [var.checkpoint_bucket_arn]

      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = ["${local.checkpoint_prefix}*"]
      }
    }
  }

  dynamic "statement" {
    for_each = var.checkpoint_kms_key_arn != null ? [1] : []

    content {
      sid       = "AgentCheckpointEncryption"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [var.checkpoint_kms_key_arn]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["s3.${data.aws_region.current.region}.amazonaws.com"]
      }
    }
  }
}

data "aws_region" "current" {}

data "aws_iam_policy_document" "combined" {
  source_policy_documents = compact([
    data.aws_iam_policy_document.permissions.json,
    var.extra_policy_json,
  ])
}

resource "aws_iam_role" "agent" {
  name                 = "${var.cluster_name}-agent-${var.agent_name}"
  path                 = var.role_path
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  permissions_boundary = var.permissions_boundary_arn
  description          = "Agent ${var.agent_name} in namespace ${var.namespace} on cluster ${var.cluster_name}."
  tags                 = local.tags
}

# Inline, not a managed policy. An agent's permissions are part of the agent and should be deleted
# with it; a managed policy outlives the role and accumulates.
resource "aws_iam_role_policy" "agent" {
  name   = "agent-permissions"
  role   = aws_iam_role.agent.id
  policy = data.aws_iam_policy_document.combined.json
}

# ---------------------------------------------------------------------------
# Pod Identity association
# ---------------------------------------------------------------------------

resource "aws_eks_pod_identity_association" "agent" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = local.service_account
  role_arn        = aws_iam_role.agent.arn

  # A session policy and the session tags are exclusive. Taking the policy means every condition an
  # IAM policy wrote against those tags stops matching, so the session policy has to express that
  # scoping itself. The module couples the two fields rather than leaving them to be set
  # independently, because setting one without the other is the failure that looks like it worked.
  policy               = var.session_policy_json
  disable_session_tags = var.session_policy_json != null

  tags = local.tags
}
