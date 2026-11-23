# AN ALERT WHEN WHAT ASSERTS THE PERSON CHANGES.
#
# With person_access_via_gateway, IAM does not see the person's token: it trusts the egress
# gateway's role to assume an agent's person role with the person's session tag, and scopes the call
# by that tag. Whoever can change that role, its policies, a person role's trust, the Pod Identity
# association that gives the gateway its role, or the user pool that issues the person's tokens can
# change who an agent acts for. Each such change is published to one SNS topic:
#
#   IAM        the gateway's role and every person role: trust, inline and attached policies,
#              permissions boundary, deletion.
#   EKS        a Pod Identity association created, changed or deleted on this cluster.
#   Cognito    the pool's app clients, identity providers, resource servers and the pool itself.
#
# CloudTrail delivers these to EventBridge only from an active trail; IAM's arrive in us-east-1
# alone, so that rule is there and forwards to this region's default bus. An organization trail or a
# multi-region trail with global service events covers both.

data "aws_partition" "current" {}

locals {
  topic_name = "${var.name}-identity-changes"
  iam_events = ["UpdateAssumeRolePolicy", "PutRolePolicy", "DeleteRolePolicy", "AttachRolePolicy", "DetachRolePolicy",
  "PutRolePermissionsBoundary", "DeleteRolePermissionsBoundary", "UpdateRole", "DeleteRole"]
  regional = {
    iam = {
      source     = "aws.iam"
      eventNames = local.iam_events
      match      = { roleName = var.role_names }
    }
    eks = {
      source     = "aws.eks"
      eventNames = ["CreatePodIdentityAssociation", "UpdatePodIdentityAssociation", "DeletePodIdentityAssociation"]
      match      = { name = [var.cluster_name] }
    }
    cognito = {
      source = "aws.cognito-idp"
      eventNames = ["CreateUserPoolClient", "UpdateUserPoolClient", "DeleteUserPoolClient", "CreateIdentityProvider",
      "UpdateIdentityProvider", "DeleteIdentityProvider", "CreateResourceServer", "UpdateResourceServer", "DeleteResourceServer", "UpdateUserPool"]
      match = { userPoolId = [var.user_pool_id] }
    }
  }
  forward = var.region != "us-east-1"
}

# A key of its own, because EventBridge can publish to an encrypted topic only with a key whose
# policy lets it: the AWS managed SNS key's policy does not.
data "aws_iam_policy_document" "key" {
  statement {
    sid       = "Account"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${var.account_id}:root"]
    }
  }
  statement {
    sid       = "EventBridgePublishes"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_kms_key" "changes" {
  description             = "${local.topic_name}: the SNS topic of identity changes"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.key.json
  tags                    = var.tags
}

resource "aws_sns_topic" "changes" {
  name              = local.topic_name
  kms_master_key_id = aws_kms_key.changes.arn
  tags              = var.tags
}

data "aws_iam_policy_document" "topic" {
  statement {
    sid       = "TheRulesPublish"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.changes.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [for r in aws_cloudwatch_event_rule.regional : r.arn]
    }
  }
}

resource "aws_sns_topic_policy" "changes" {
  arn    = aws_sns_topic.changes.arn
  policy = data.aws_iam_policy_document.topic.json
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.emails)
  topic_arn = aws_sns_topic.changes.arn
  protocol  = "email"
  endpoint  = each.value
}

resource "aws_cloudwatch_event_rule" "regional" {
  for_each    = local.regional
  name        = "${var.name}-identity-${each.key}"
  description = "Report a change to what decides who an agent acts for: ${each.key}"
  event_pattern = jsonencode({
    source        = [each.value.source]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName         = each.value.eventNames
      requestParameters = each.value.match
    }
  })
  tags = var.tags
}

resource "aws_cloudwatch_event_target" "regional" {
  for_each = local.regional
  rule     = aws_cloudwatch_event_rule.regional[each.key].name
  arn      = aws_sns_topic.changes.arn

  input_transformer {
    input_paths = {
      event = "$.detail.eventName", source = "$.detail.eventSource", who = "$.detail.userIdentity.arn"
      at    = "$.detail.eventTime", role = "$.detail.requestParameters.roleName", error = "$.detail.errorCode"
      pool  = "$.detail.requestParameters.userPoolId", cluster = "$.detail.requestParameters.name"
    }
    # Plain text, from scalar fields only: a JSON object inside a quoted template would break it.
    input_template = "\"${var.name}: <event> (<source>) by <who> at <at>. Role <role>, user pool <pool>, cluster <cluster>, error <error>. This changes what decides who an agent acts for.\""
  }
}

# IAM's events arrive in us-east-1 only: matched there and sent to this region's default bus, where
# the iam rule above publishes them.
resource "aws_cloudwatch_event_rule" "iam_forward" {
  count       = local.forward ? 1 : 0
  provider    = aws.us_east_1
  name        = "${var.name}-identity-iam-forward"
  description = "Forward IAM changes to ${var.name}'s gateway and person roles to ${var.region}"
  event_pattern = jsonencode({
    source        = ["aws.iam"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventName         = local.iam_events
      requestParameters = { roleName = var.role_names }
    }
  })
  tags = var.tags
}

data "aws_iam_policy_document" "forward_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.account_id]
    }
  }
}

resource "aws_iam_role" "forward" {
  count              = local.forward ? 1 : 0
  name               = "${var.name}-identity-iam-forward"
  assume_role_policy = data.aws_iam_policy_document.forward_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "forward" {
  count = local.forward ? 1 : 0
  name  = "put-events-to-${var.region}"
  role  = aws_iam_role.forward[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = "arn:${data.aws_partition.current.partition}:events:${var.region}:${var.account_id}:event-bus/default"
    }]
  })
}

resource "aws_cloudwatch_event_target" "iam_forward" {
  count    = local.forward ? 1 : 0
  provider = aws.us_east_1
  rule     = aws_cloudwatch_event_rule.iam_forward[0].name
  arn      = "arn:${data.aws_partition.current.partition}:events:${var.region}:${var.account_id}:event-bus/default"
  role_arn = aws_iam_role.forward[0].arn
}
