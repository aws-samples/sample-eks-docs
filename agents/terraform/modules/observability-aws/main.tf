# Observability on the AWS-managed path.
#
# The instrumentation is the same on both paths: the agent emits OpenTelemetry with the GenAI
# semantic conventions. What differs is the backend it lands in, so the choice stays reversible and
# does not reach the agent's code.
#
# Two things are worth knowing about this option on EKS, and both are the reason this module exists
# rather than a sentence in a README.
#
#   1. AgentCore Observability is not a separate backend from CloudWatch. The telemetry lands in
#      CloudWatch Logs and X-Ray and is read through the GenAI Observability views, which carry the
#      agent's trajectory, per-invocation token counts and tool-call outcomes.
#   2. Reaching those views takes enabling CloudWatch Transaction Search and instrumenting with the
#      ADOT distro. It does not arrive automatically the way it does for an agent hosted on
#      AgentCore Runtime. That is the step a platform team misses.
#
# What this module does not close: per-agent cost is still two numbers. Compute is allocatable down
# to the pod through split cost allocation data; model spend is attributed by IAM principal,
# inference profile tag or project, and none of those carries a Kubernetes dimension. No AWS-side
# dimension links the two.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  tags = merge(var.tags, {
    "app.kubernetes.io/part-of" = "eks-agents-paved-paths"
    ManagedBy                   = "terraform/modules/observability-aws"
  })
}

# ---------------------------------------------------------------------------
# Transaction Search
# ---------------------------------------------------------------------------

# This is the prerequisite for the GenAI Observability views. Without it the spans an agent emits
# are sampled traces rather than searchable transactions, and the per-invocation token counts and
# tool-call outcomes the views are for do not appear.
#
# It is three objects rather than one switch, which is part of why a platform team misses it:
#
#   1. A resource policy on the aws/spans log group, so X-Ray may write spans there.
#   2. The trace segment destination set to CloudWatchLogs.
#   3. An indexing rule, which is what decides how much of it is searchable.
#
# All three are account-and-Region settings, not per-cluster ones. Two clusters in one Region share
# them, so enable this in one place: a second root module applying it would fight the first. That is
# what the enable_transaction_search guard is for.
resource "aws_cloudwatch_log_resource_policy" "transaction_search" {
  count = var.enable_transaction_search ? 1 : 0

  policy_name     = "${var.name}-xray-spans"
  policy_document = data.aws_iam_policy_document.transaction_search[0].json
}

data "aws_iam_policy_document" "transaction_search" {
  count = var.enable_transaction_search ? 1 : 0

  statement {
    sid    = "TransactionSearchSpansAccess"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["xray.amazonaws.com"]
    }

    actions = ["logs:PutLogEvents", "logs:CreateLogStream"]

    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:aws/spans:*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/application-signals/data:*",
    ]

    # Confused-deputy guards. Without them this policy lets the X-Ray service principal write here
    # on behalf of any account.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:xray:${local.region}:${local.account_id}:*"]
    }
  }
}

# AN ACCOUNT SETTING, AND `terraform destroy` DOES NOT PUT IT BACK.
#
# After a full destroy, this resource is gone from state and
# `aws xray get-trace-segment-destination` still reports `CloudWatchLogs / ACTIVE`. The delete is a
# no-op against the API, so state claims a revert that did not happen -- which is worse than not
# owning the setting at all, because nothing contradicts the state file.
#
# It is not a charge on an idle account (Transaction Search bills on indexed spans), so the cost of
# the leak is a changed account default rather than a bill. `scripts/teardown.sh` reverts it, and
# only when no OTHER cluster carrying this stack's tag is left in the account -- because flipping it
# takes their GenAI observability views with it.
resource "aws_xray_trace_segment_destination" "this" {
  count = var.enable_transaction_search ? 1 : 0

  destination = "CloudWatchLogs"

  depends_on = [aws_cloudwatch_log_resource_policy.transaction_search]
}

resource "aws_xray_indexing_rule" "default" {
  count = var.enable_transaction_search ? 1 : 0

  name = "Default"

  rule {
    probabilistic {
      # 100 means every span is indexed for search. Indexing is billed on the volume, so a
      # high-traffic agent fleet should measure before leaving it here. Below 100, a specific agent
      # invocation may not be findable, which is the thing a platform team wanted the views for.
      desired_sampling_percentage = var.transaction_search_indexing_percentage
    }
  }

  depends_on = [aws_xray_trace_segment_destination.this]
}

# ---------------------------------------------------------------------------
# Log destinations
# ---------------------------------------------------------------------------

# The log group the agent's OTLP logs land in. Named for the cluster and the service, so the
# GenAI Observability views and an operator both find one place per agent platform.
resource "aws_cloudwatch_log_group" "agent_telemetry" {
  name              = "/aws/eks/${var.cluster_name}/agents"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn

  tags = local.tags
}

# Agent traces carry prompts and tool arguments. That is content, and it should not sit in a log
# group with no retention and the service default key, which is the shape a log group gets when
# nobody set it. Both are inputs here for that reason.
resource "aws_cloudwatch_log_group" "agent_application" {
  name              = "/aws/eks/${var.cluster_name}/agents/application"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn

  tags = local.tags
}

# NETWORK POLICY VERDICTS, one record per flow decision. The agents' NodeClass sets
# networkPolicyEventLogs: Enabled, and the node's network policy agent then writes every ACCEPT and
# DENY to /var/log/aws-routed-eni/network-policy-agent.log -- on the node, where nobody reads it.
# Fluent Bit from the CloudWatch Observability add-on ships those lines alone to this group (see the
# add-on's configuration below). A sandboxed agent's refused connection is recorded as
# "Verdict DENY Direction egress, Tier NETWORK_POLICY", next to its accepted flows. The records
# name IP addresses, not pods.
resource "aws_cloudwatch_log_group" "network_policy" {
  count = var.enable_network_policy_logs ? 1 : 0

  name              = "/aws/eks/${var.cluster_name}/network-policy"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn

  tags = local.tags
}

# ---------------------------------------------------------------------------
# The collector's identity
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "collector_assume_role" {
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

resource "aws_iam_role" "collector" {
  name               = "${var.name}-adot-collector"
  assume_role_policy = data.aws_iam_policy_document.collector_assume_role.json
  description        = "ADOT collector for agents on cluster ${var.cluster_name}. Writes telemetry; reads nothing."
  tags               = local.tags
}

data "aws_iam_policy_document" "collector" {
  statement {
    sid    = "WriteAgentTelemetry"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]

    resources = [
      "${aws_cloudwatch_log_group.agent_telemetry.arn}:*",
      "${aws_cloudwatch_log_group.agent_application.arn}:*",
    ]
  }

  statement {
    sid    = "WriteTraces"
    effect = "Allow"

    actions = [
      "xray:PutTraceSegments",
      "xray:PutSpans",
      "xray:PutSpansForIndexing",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]

    resources = ["*"]
  }

  # EMF metrics from the agent's own OTEL pipeline. Scoped to the namespace so a collector
  # misconfiguration cannot publish into another team's metric namespace.
  statement {
    sid       = "PublishAgentMetrics"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = var.metric_namespaces
    }
  }

  # A collector reads nothing. Without this, a collector role is a read path into every log group
  # in the account for anything that gets code execution in the collector pod.
  statement {
    sid    = "NeverRead"
    effect = "Deny"

    actions = [
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:StartQuery",
      "xray:BatchGetTraces",
      "xray:GetTraceSummaries",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "collector" {
  name   = "adot-collector"
  role   = aws_iam_role.collector.id
  policy = data.aws_iam_policy_document.collector.json
}

resource "aws_eks_pod_identity_association" "collector" {
  cluster_name    = var.cluster_name
  namespace       = var.collector_namespace
  service_account = var.collector_service_account
  role_arn        = aws_iam_role.collector.arn

  tags = local.tags
}

# ---------------------------------------------------------------------------
# CloudWatch Observability add-on
# ---------------------------------------------------------------------------

# Container Insights and the CloudWatch agent, for the infrastructure half. The agent's own GenAI
# telemetry comes from the collector above; this is what makes the pod it ran in visible next to it.
# THE ADD-ON'S OWN IDENTITY. Without it the CloudWatch agent and Fluent Bit fall back to the node
# role, which on EKS Auto Mode carries only the minimal worker and ECR pull policies: the add-on is
# installed and publishes nothing, and no Container Insights log group appears.
data "aws_iam_policy_document" "cloudwatch_agent_trust" {
  statement {
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

resource "aws_iam_role" "cloudwatch_agent" {
  count = var.enable_cloudwatch_observability_addon ? 1 : 0

  name               = "${var.name}-cloudwatch-agent"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_agent_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  count = var.enable_cloudwatch_observability_addon ? 1 : 0

  role       = aws_iam_role.cloudwatch_agent[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

locals {
  # Fluent Bit's inputs, one file each. With container logs off, the application and host inputs are
  # replaced by files that read nothing, so turning on the verdicts does not start shipping agent
  # logs (no Container Insights application group appears). The dataplane file carries
  # the verdicts alone. The node agent writes each line as JSON; the parser unwraps it from Fluent
  # Bit's `log` field so Logs Insights sees msg, ts and level as fields.
  netpol_dataplane_conf = <<-EOT
    [INPUT]
        Name                tail
        Tag                 netpol.verdicts
        Path                /var/log/aws-routed-eni/network-policy-agent.log
        DB                  /var/fluent-bit/state/flb_netpol.db
        Mem_Buf_Limit       10MB
        Skip_Long_Lines     On
        Refresh_Interval    10
        Read_from_Head      Off

    [FILTER]
        Name                grep
        Match               netpol.*
        Regex               log Flow Info

    [FILTER]
        Name                parser
        Match               netpol.*
        Key_Name            log
        Parser              netpol_json

    [OUTPUT]
        Name                cloudwatch_logs
        Match               netpol.*
        region              ${local.region}
        log_group_name      /aws/eks/${var.cluster_name}/network-policy
        log_stream_prefix   $${HOST_NAME}-
        auto_create_group   false
  EOT
  fluent_bit_files = merge(
    var.enable_container_logs ? {} : {
      "application-log.conf" = "# Agent container logs are off (enable_container_logs): they carry prompts and model output.\n"
      "host-log.conf"        = "# Host logs are off.\n"
    },
    var.enable_network_policy_logs ? { "dataplane-log.conf" = local.netpol_dataplane_conf } : {},
  )
}

resource "aws_eks_addon" "cloudwatch_observability" {
  count = var.enable_cloudwatch_observability_addon ? 1 : 0

  cluster_name  = var.cluster_name
  addon_name    = "amazon-cloudwatch-observability"
  addon_version = var.cloudwatch_observability_addon_version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  pod_identity_association {
    role_arn        = aws_iam_role.cloudwatch_agent[0].arn
    service_account = "cloudwatch-agent"
  }

  configuration_values = jsonencode({
    containerLogs = merge({
      # Agent container logs carry prompts and model output. Sending them to CloudWatch Logs by
      # default duplicates content the OTLP pipeline already carries, into a second place with its
      # own retention. Off here; turn it on deliberately. Fluent Bit still runs for the network
      # policy verdicts, with the application and host inputs replaced by files that read nothing.
      enabled = var.enable_container_logs || var.enable_network_policy_logs
      }, length(local.fluent_bit_files) > 0 ? {
      fluentBit = {
        config = {
          customParsers = "[PARSER]\n    Name   netpol_json\n    Format json\n"
          extraFiles    = local.fluent_bit_files
        }
      }
    } : {})
    agent = {
      config = {
        traces = {
          traces_collected = {
            # The X-Ray and OTLP receivers, which is what lets a sidecar-free agent emit spans to
            # the node-local agent rather than needing the collector addressable.
            xray = {}
            otlp = {}
          }
        }
      }
    }
  })

  tags = local.tags

  depends_on = [aws_iam_role_policy_attachment.cloudwatch_agent, aws_cloudwatch_log_group.network_policy]
}
