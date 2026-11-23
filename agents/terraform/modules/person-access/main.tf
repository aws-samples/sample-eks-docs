# An agent acting with a person's own authority.
#
# THE QUESTION THIS ANSWERS. Would the same request from two different people return different
# results, or be refused for one of them? If not, the agent's own identity is the whole answer and
# this module adds nothing. Where it does -- a person's own files, records or tickets -- the refusal
# must not depend on the model behaving. This module makes AWS do it: a person's token is exchanged
# for credentials that carry only that person's access, so a request for someone else's data is
# refused by IAM whatever the agent was asked to do.
#
# TWO HALVES, BECAUSE THE TWO TOKENS A PERSON CAN BRING ARE DIFFERENT.
#
#   An ID token (aud = a client of the pool) can be exchanged with STS AssumeRoleWithWebIdentity.
#   This module creates the client that issues one (`api`, for an application that signs the person
#   in itself), the IAM OIDC provider that lets STS validate it, and ONE ROLE PER AGENT that may act
#   for people (var.agents). Each role's permissions are scoped by the token's own `sub` AND by the
#   agent, so what a session reaches is what both the person and that agent may reach: person A's
#   credentials read A's object and are refused B's, and the reverse.
#
#   An access token -- what the load balancer forwards after the browser sign-in, in
#   x-amzn-oidc-accesstoken -- carries `client_id` and no `aud`. STS refuses it ("Missing a required
#   claim: aud") and so does a Cognito identity pool. A person signed in at the chat UI therefore has
#   no AWS credentials of their own; a tool that verifies the access token itself is what enforces
#   their authority there (agents/mcp-server, my_account and get_account).
#
# WHAT THIS DOES NOT CLOSE. Nothing here proves the agent did not reuse the token it was handed: the
# agent presents the person's token, and could present it again within its lifetime. What it cannot
# do is present a token for anyone else, because it cannot sign one. Keep token lifetimes short, and
# scope the role to what an agent acting for a person should do, not everything the person may do.

data "aws_partition" "current" {}

locals {
  issuer_url  = "https://cognito-idp.${var.region}.amazonaws.com/${var.user_pool_id}"
  issuer_host = "cognito-idp.${var.region}.amazonaws.com/${var.user_pool_id}"
  bucket_name = "${var.name}-person-data-${var.account_id}"
}

# The client an application uses to sign a person in and receive an ID token for them. Public (no
# secret): an application running on a person's device cannot keep one. Authorization code with PKCE
# through the hosted UI is the flow for a real application; USER_PASSWORD_AUTH is on so the test in
# scripts/exercise.sh can sign its test users in from the bastion, and is turned off with
# person_access_password_auth = false in the root (var.allow_password_auth here).
resource "aws_cognito_user_pool_client" "api" {
  name         = "${var.name}-api"
  user_pool_id = var.user_pool_id

  generate_secret = false
  explicit_auth_flows = concat(
    ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"],
    var.allow_password_auth ? ["ALLOW_USER_PASSWORD_AUTH"] : [],
  )
  allowed_oauth_flows_user_pool_client = length(var.callback_urls) > 0
  allowed_oauth_flows                  = length(var.callback_urls) > 0 ? ["code"] : []
  allowed_oauth_scopes                 = length(var.callback_urls) > 0 ? ["openid", "email", "profile"] : []
  callback_urls                        = var.callback_urls
  supported_identity_providers         = ["COGNITO"]

  # Short-lived, because an agent holding a person's token can use it until it expires.
  id_token_validity      = var.token_validity_minutes
  access_token_validity  = var.token_validity_minutes
  refresh_token_validity = 1
  token_validity_units {
    id_token      = "minutes"
    access_token  = "minutes"
    refresh_token = "days"
  }
  prevent_user_existence_errors = "ENABLED"
}

# The object that lets STS validate a token the pool issued to a PERSON. It names the pool, not the
# cluster's own OIDC issuer: registering the cluster's issuer here would let a workload's token be
# exchanged for a person's credentials, which is exactly the confusion this exists to avoid.
resource "aws_iam_openid_connect_provider" "people" {
  count = var.existing_oidc_provider_arn == "" ? 1 : 0

  url            = local.issuer_url
  client_id_list = [aws_cognito_user_pool_client.api.id]
  tags           = var.tags
}

locals {
  oidc_provider_arn = var.existing_oidc_provider_arn != "" ? var.existing_oidc_provider_arn : aws_iam_openid_connect_provider.people[0].arn
}

# Where a person's own data lives in the example: s3://<bucket>/people/<sub>/. Private, encrypted,
# and reachable only through the role below or an administrator.
resource "aws_s3_bucket" "people" {
  bucket        = local.bucket_name
  force_destroy = var.force_destroy
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "people" {
  bucket                  = aws_s3_bucket.people.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "people" {
  bucket = aws_s3_bucket.people.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "people" {
  bucket = aws_s3_bucket.people.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# TLS only: the bucket refuses a request over plain HTTP from anyone.
data "aws_iam_policy_document" "bucket" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.people.arn, "${aws_s3_bucket.people.arn}/*"]
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

resource "aws_s3_bucket_policy" "people" {
  bucket     = aws_s3_bucket.people.id
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.people]
}

# ONE ROLE PER AGENT THAT MAY ACT FOR PEOPLE, NOT ONE FOR EVERY AGENT. Three things follow from
# the role being the agent's own:
#
#   THE AGENT IS ON THE RECORD. The trust admits a session only when its name starts with
#   "<agent>-" (sts:RoleSessionName), and the agent names it "<agent>-<sub prefix>-<epoch>", so
#   CloudTrail's AssumeRoleWithWebIdentity event names the agent twice (role and session) and the
#   person once (userIdentity.userName, the token's sub). AssumeRoleWithWebIdentity takes no
#   SourceIdentity parameter (only AssumeRole does); for web identity it would have to be a claim
#   in the person's token, which the pool does not issue without a pre-token-generation trigger.
#
#   ACCESS IS THE INTERSECTION. The permissions name the token's own subject AND this agent:
#   people/<sub>/<agent>/*. A session reaches only what the person may reach and this agent may
#   reach; the same person's data under another agent's part is refused, by IAM.
#
#   ONE AGENT CAN BE REVOKED. Removing an agent from var.agents deletes its role; the agent's pod
#   then gets an empty AGENT_PERSON_ROLE_ARN, and an exchange for the deleted role is refused.
#   Every other agent's role, and every person, is unaffected.
data "aws_iam_policy_document" "trust" {
  for_each = toset(var.agents)

  # THE AGENT'S OWN EXCHANGE, only without the gateway. With gateway_role_arn set the gateway is the
  # only way to the person's authority: the agents' egress can still reach STS (the checkpoint store
  # opens it), so a web-identity statement left here would let an agent exchange the person's ID
  # token itself and go around the gateway (with checkpoints on).
  dynamic "statement" {
    for_each = var.gateway_role_arn == "" ? [1] : []
    content {
      effect  = "Allow"
      actions = ["sts:AssumeRoleWithWebIdentity"]
      principals {
        type        = "Federated"
        identifiers = [local.oidc_provider_arn]
      }
      condition {
        test     = "StringEquals"
        variable = "${local.issuer_host}:aud"
        values   = [aws_cognito_user_pool_client.api.id]
      }
      condition {
        test     = "StringLike"
        variable = "sts:RoleSessionName"
        values   = ["${each.value}-*"]
      }
    }
  }

  # THROUGH THE GATEWAY (var.gateway_role_arn): the egress gateway assumes this role ITSELF, with
  # AssumeRole, after verifying the person's token -- AgentGateway cannot pass a request's token to
  # STS (AssumeRoleWithWebIdentity), so STS does not see the person's token on this path. What
  # it sees instead is the gateway's assertion: session tag `person` = the verified token's sub, and
  # `agent` = this agent. So the trust admits ONLY the gateway's role, requires both tags, requires
  # the agent tag to be this agent and the session to be named for it, and the permissions below
  # read the person from the tag. Trust moves from the IdP's signature at STS to the gateway's own
  # verification; the agents-identity-on-behalf-of page of the EKS User Guide says so.
  # TWO STATEMENTS, BECAUSE STS EVALUATES THE TAGS AS A SEPARATE ACTION. An AssumeRole that carries
  # tags is authorized as sts:AssumeRole AND sts:TagSession, and the sts:RoleSessionName key is
  # present only for the first: one statement holding both actions with a session-name condition
  # refuses every request with AccessDenied on sts:TagSession.
  # So the session name is required on AssumeRole, and both tag conditions are required on both.
  #
  # NO aws:TagKeys LIMIT either: the gateway's own session (EKS Pod Identity) carries transitive
  # session tags into the chained call. The permissions read only the person tag.
  dynamic "statement" {
    for_each = var.gateway_role_arn != "" ? [1] : []
    content {
      sid     = "GatewayActsForAVerifiedPerson"
      effect  = "Allow"
      actions = ["sts:AssumeRole"]
      principals {
        type        = "AWS"
        identifiers = [var.gateway_role_arn]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:RequestTag/agent"
        values   = [each.value]
      }
      condition {
        test     = "StringLike"
        variable = "aws:RequestTag/person"
        values   = ["?*"]
      }
      condition {
        test     = "StringLike"
        variable = "sts:RoleSessionName"
        values   = ["${each.value}-*"]
      }
    }
  }
  dynamic "statement" {
    for_each = var.gateway_role_arn != "" ? [1] : []
    content {
      sid     = "GatewayTagsThePersonAndThisAgent"
      effect  = "Allow"
      actions = ["sts:TagSession"]
      principals {
        type        = "AWS"
        identifiers = [var.gateway_role_arn]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:RequestTag/agent"
        values   = [each.value]
      }
      condition {
        test     = "StringLike"
        variable = "aws:RequestTag/person"
        values   = ["?*"]
      }
    }
  }
}

resource "aws_iam_role" "person" {
  for_each = toset(var.agents)

  name                 = "${var.name}-${each.value}-person-data"
  path                 = var.role_path
  assume_role_policy   = data.aws_iam_policy_document.trust[each.value].json
  max_session_duration = 3600
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = merge(var.tags, { "eks-agents/agent" = each.value })
}

data "aws_iam_policy_document" "person" {
  for_each = toset(var.agents)

  # The person in an IAM condition key differs by who assumed the role: the token's sub for a
  # web-identity session (the agent's own exchange), the `person` session tag for the gateway's
  # AssumeRole. A policy variable that is absent from a session matches nothing, so each statement
  # serves only its own kind of session.
  statement {
    sid       = "OwnObjectsForThisAgent"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.people.arn}/people/$${${local.issuer_host}:sub}/${each.value}/*"]
  }
  statement {
    sid       = "ListOwnPrefixForThisAgent"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.people.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["people/$${${local.issuer_host}:sub}/${each.value}/*"]
    }
  }
  dynamic "statement" {
    for_each = var.gateway_role_arn != "" ? [1] : []
    content {
      sid       = "OwnObjectsForThisAgentViaGateway"
      actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
      resources = ["${aws_s3_bucket.people.arn}/people/$${aws:PrincipalTag/person}/${each.value}/*"]
    }
  }
  # Other AWS services through the gateway (var.gateway_services): the platform team's statements,
  # with {agent} replaced by this agent. They should key every resource or condition on
  # $${aws:PrincipalTag/person}, which only the gateway's tagged session carries.
  dynamic "statement" {
    for_each = var.gateway_role_arn != "" ? flatten([for svc, cfg in var.gateway_services : [for i, st in cfg.statements : merge(st, { sid = "${replace(title(replace(svc, "-", " ")), " ", "")}ViaGateway${i}" })]]) : []
    content {
      sid       = statement.value.sid
      actions   = statement.value.actions
      resources = [for r in statement.value.resources : replace(r, "{agent}", each.value)]
      dynamic "condition" {
        for_each = statement.value.conditions
        content {
          test     = condition.value.test
          variable = condition.value.variable
          values   = [for v in condition.value.values : replace(v, "{agent}", each.value)]
        }
      }
    }
  }
  dynamic "statement" {
    for_each = var.gateway_role_arn != "" ? [1] : []
    content {
      sid       = "ListOwnPrefixForThisAgentViaGateway"
      actions   = ["s3:ListBucket"]
      resources = [aws_s3_bucket.people.arn]
      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = ["people/$${aws:PrincipalTag/person}/${each.value}/*"]
      }
    }
  }
}

resource "aws_iam_role_policy" "person" {
  for_each = toset(var.agents)

  name   = "own-prefix-for-this-agent"
  role   = aws_iam_role.person[each.value].id
  policy = data.aws_iam_policy_document.person[each.value].json
}
