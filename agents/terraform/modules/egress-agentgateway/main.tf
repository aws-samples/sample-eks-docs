# The AWS-side footprint of the open source egress path.
#
# AgentGateway itself runs on the cluster and is reconciled from Git: the GatewayClass, the Gateway,
# the AgentgatewayBackends, the HTTPRoutes and the AgentgatewayPolicies all live in
# gitops/platform/open-source/. What is in AWS is this:
#
#   1. The gateway's own IAM role, which holds nothing except permission to assume the per-agent
#      roles. That mapping -- from a verified in-cluster identity to an IAM role -- is where
#      per-agent AWS authority comes from on this stack.
#   2. Secrets Manager secrets for the third-party credentials the gateway holds so that the pod
#      does not. This is the half of the credential story carrying most of the security value,
#      because these are the long-lived secrets.
#   3. A Private CA, optionally, for the mesh's own certificate authority.
#
# Read the concentration this creates. Brokering puts every agent's credential for every
# destination into one process, which the base layer did not have at all. The gateway is the
# highest-value target in this architecture and should be defended as such: its namespace is not a
# tenant namespace, its role is not reusable, and the secrets below are readable by it alone.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  tags = merge(var.tags, {
    "app.kubernetes.io/part-of" = "eks-agents-paved-paths"
    ManagedBy                   = "terraform/modules/egress-agentgateway"
  })

  secret_prefix = "${var.name}/agentgateway"
}

# ---------------------------------------------------------------------------
# The gateway's own identity
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "gateway_assume_role" {
  statement {
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
}

resource "aws_iam_role" "gateway" {
  name               = "${var.name}-agentgateway"
  assume_role_policy = data.aws_iam_policy_document.gateway_assume_role.json
  description        = "AgentGateway on cluster ${var.cluster_name}. Holds no model or data permission of its own: it assumes the calling agent's role and signs that agent's requests."
  tags               = local.tags
}

locals {
  # The enumerated roles when Terraform declares the agents, the role path when the cluster composes
  # them. Concatenating rather than choosing means a deployment that somehow has both still works.
  gateway_assumable_roles = concat(
    var.agent_role_arns,
    var.agent_role_path_arn != "" ? [var.agent_role_path_arn] : [],
    # Named even when the path grant above already covers it, so a configuration that declares its
    # agents in Terraform -- and so grants no path -- still lets the gateway sign the judge's calls.
    aws_iam_role.judge[*].arn,
  )
}

# ---------------------------------------------------------------------------
# The judge's identity (gitops/charts/agent-evals)
# ---------------------------------------------------------------------------
#
# THE EVALUATION JUDGE IS A GATEWAY PRINCIPAL, so it gets the same shape of identity an agent does:
# a role the gateway assumes to sign its model calls, scoped to the judge's models and capped by the
# agents' permissions boundary. Not an agent role -- no Pod Identity principal, no checkpoint prefix,
# no memory -- because the judge reads traces and grades them and does nothing else in AWS. The
# runner pod itself holds no AWS credential on this path.
#
# At the agent role path, so the gateway's existing path-scoped grant and the ACK capability's
# boundary conditions treat it like the roles beside it.

data "aws_iam_policy_document" "judge_assume_role" {
  count = var.judge != null ? 1 : 0

  statement {
    effect = "Allow"
    # TagSession as well: the gateway stamps agent/cluster session tags on every call it signs,
    # and AssumeRole alone is refused on them.
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.gateway.arn]
    }
  }
}

resource "aws_iam_role" "judge" {
  count = var.judge != null ? 1 : 0

  name                 = "${var.name}-evals-judge"
  path                 = var.judge.role_path
  permissions_boundary = var.judge.permissions_boundary_arn
  assume_role_policy   = data.aws_iam_policy_document.judge_assume_role[0].json
  description          = "The evaluation judge on cluster ${var.cluster_name}. Assumed by the gateway to sign the judge's model calls; can invoke the judge models and nothing else."
  tags                 = local.tags
}

data "aws_iam_policy_document" "judge" {
  count = var.judge != null ? 1 : 0

  statement {
    sid    = "InvokeJudgeModelsOnly"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:Converse",
      "bedrock:ConverseStream",
    ]
    resources = var.judge.model_arns
  }
}

resource "aws_iam_role_policy" "judge" {
  count = var.judge != null ? 1 : 0

  name   = "invoke-judge-models"
  role   = aws_iam_role.judge[0].id
  policy = data.aws_iam_policy_document.judge[0].json
}

data "aws_iam_policy_document" "gateway" {
  # The whole of the gateway's AWS authority. Note what is absent: no bedrock:InvokeModel, no
  # s3:GetObject, nothing an agent would want. A gateway that could call a model as itself would
  # make every agent's model scope advisory, because an agent's calls would be attributed to the
  # gateway rather than refused.
  # Either the enumerated agent roles, or the role path when agents are composed in the cluster and
  # no list can exist at apply time. One or the other -- never neither: with `var.agents` empty and
  # this statement omitted, the gateway can assume nothing and every model call returns 403 from
  # Bedrock.
  dynamic "statement" {
    for_each = length(local.gateway_assumable_roles) > 0 ? [1] : []

    content {
      sid       = "AssumeAgentRolesOnly"
      effect    = "Allow"
      actions   = ["sts:AssumeRole", "sts:TagSession"]
      resources = local.gateway_assumable_roles
    }
  }

  # The guardrail the gateway runs on each model request and response (guardrail_arn). The
  # gateway calls ApplyGuardrail as itself, so this is the one Bedrock action its own role holds,
  # scoped to that one guardrail.
  dynamic "statement" {
    for_each = var.guardrail_arn != "" ? [1] : []

    content {
      sid       = "ApplyThePlatformGuardrail"
      effect    = "Allow"
      actions   = ["bedrock:ApplyGuardrail"]
      resources = [var.guardrail_arn]
    }
  }

  # The third-party credentials the gateway attaches per caller. Read-only, and scoped by name
  # prefix so a secret added later for a different purpose is not readable by the gateway by
  # default.
  dynamic "statement" {
    for_each = length(var.third_party_credentials) > 0 ? [1] : []

    content {
      sid       = "ReadBrokeredCredentials"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      resources = [for k, v in aws_secretsmanager_secret.third_party : v.arn]
    }
  }

  dynamic "statement" {
    for_each = var.credential_kms_key_arn != null ? [1] : []

    content {
      sid       = "DecryptBrokeredCredentials"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.credential_kms_key_arn]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${local.region}.amazonaws.com"]
      }
    }
  }

  # Anthropic models on Bedrock are AWS Marketplace models, and a Marketplace model becomes usable
  # only after its CALLER completes a one-time, account-wide subscription on first invoke. The
  # Bedrock console's "Model access" page is retired, so there is no out-of-band way to pre-accept
  # it.
  #
  # That caller is this gateway, because the gateway is what signs the model call. Without these
  # actions the first Claude invocation on a fresh account fails with "not authorized to perform the
  # required AWS Marketplace actions" while Amazon-owned models (Nova) and any self-hosted model
  # keep working -- so it looks like a problem with Anthropic access rather than with the caller's
  # permissions.
  #
  # The subscription is account-wide and takes a few minutes to propagate, so the first invoke
  # inside that window can still 403 with "try again after 2 minutes". Warm it at provisioning time
  # if the first real request must not be the one that pays for it. Two ways: a one-token converse
  # call, or creating the agreement explicitly -- `aws bedrock list-foundation-model-agreement-offers`
  # then `create-foundation-model-agreement` per model, in every Region a us.* inference profile
  # routes to (us-east-1, us-east-2, us-west-2). The second is idempotent, so it is safe on every
  # apply.
  #
  # Without the Marketplace actions, every path that reaches an Anthropic model on a fresh account
  # fails on its first call.
  dynamic "statement" {
    for_each = var.enable_bedrock_marketplace_subscribe ? [1] : []

    content {
      sid    = "BedrockMarketplaceSubscribe"
      effect = "Allow"

      actions = [
        "aws-marketplace:Subscribe",
        "aws-marketplace:ViewSubscriptions",
      ]

      resources = ["*"]
    }
  }

  # An explicit denial of the one thing that would collapse the per-agent story: the gateway must
  # never be able to create or alter identity. A gateway with iam:PutRolePolicy could widen any
  # agent's role it already assumes.
  statement {
    sid       = "NeverAlterIdentity"
    effect    = "Deny"
    actions   = ["iam:*", "eks:*", "organizations:*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gateway" {
  name   = "agentgateway"
  role   = aws_iam_role.gateway.id
  policy = data.aws_iam_policy_document.gateway.json
}

resource "aws_eks_pod_identity_association" "gateway" {
  cluster_name    = var.cluster_name
  namespace       = var.gateway_namespace
  service_account = var.gateway_service_account
  role_arn        = aws_iam_role.gateway.arn

  tags = local.tags
}

# NO CLOUDWATCH LOG GROUP. The gateway's per-call record is its access log, on the data plane pods'
# stdout (one line per request: route, caller, status, duration). Nothing writes to a log group
# from here, so creating one and a PutLogEvents grant would leave both empty. Ship the access log
# with the cluster's own log collection if it must outlive the pods.

# ---------------------------------------------------------------------------
# Third-party credentials the gateway holds
# ---------------------------------------------------------------------------

# One secret per destination per caller. The gateway attaches the right one per caller, so two
# agents reaching the same service carry different authority to it and neither holds the token.
#
# This module creates the secret and its access path, never its value. The value is set out of
# band -- an API key directly, or a token a consent flow wrote. The open source gateway runs no
# consent flow of its own. Terraform cannot hold the value, and a secret value in state is a secret
# in a state file.
resource "aws_secretsmanager_secret" "third_party" {
  for_each = var.third_party_credentials

  name        = "${local.secret_prefix}/${each.key}"
  description = "Credential the gateway attaches for ${each.value.destination}, on behalf of ${each.value.caller}. Set the value out of band; Terraform never holds it."
  kms_key_id  = var.credential_kms_key_arn

  recovery_window_in_days = var.secret_recovery_window_days

  tags = merge(local.tags, {
    "eks-agents/destination" = each.value.destination
    "eks-agents/caller"      = each.value.caller
  })
}

# Only the gateway reads these. A resource policy says it at the secret rather than relying on
# every future role's own policy being written narrowly.
data "aws_iam_policy_document" "third_party" {
  for_each = var.third_party_credentials

  statement {
    sid       = "OnlyTheGateway"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = concat([aws_iam_role.gateway.arn], var.credential_admin_principal_arns)
    }
  }
}

resource "aws_secretsmanager_secret_policy" "third_party" {
  for_each = var.third_party_credentials

  secret_arn = aws_secretsmanager_secret.third_party[each.key].arn
  policy     = data.aws_iam_policy_document.third_party[each.key].json
}

# ---------------------------------------------------------------------------
# Private CA for the mesh
# ---------------------------------------------------------------------------

# Optional, and off by default. This stack takes the mesh's own certificate authority, which
# costs nothing and issues under a per-cluster trust domain. A Private CA here is what a team wants
# if its own policy requires a certificate authority it controls.
#
# Note the cost. A Private CA is billed per month plus per certificate, and on this stack it signs
# a certificate every time an agent presents its identity as mTLS. Turn it on deliberately.
resource "aws_acmpca_certificate_authority" "mesh" {
  count = var.enable_mesh_private_ca ? 1 : 0

  type                            = "ROOT"
  usage_mode                      = "SHORT_LIVED_CERTIFICATE"
  permanent_deletion_time_in_days = var.private_ca_deletion_window_days

  certificate_authority_configuration {
    key_algorithm     = "EC_prime256v1"
    signing_algorithm = "SHA256WITHECDSA"

    subject {
      common_name  = var.mesh_trust_domain
      organization = var.mesh_ca_organization
    }
  }

  tags = local.tags
}
