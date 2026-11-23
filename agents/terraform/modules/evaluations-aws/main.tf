# Evaluations on the AWS-managed path: AgentCore Evaluations.
#
# Evaluation grades an agent's output before it reaches whoever asked for it, and it runs on the
# traces the observability layer already collects rather than on a separate instrumentation path.
# So this module depends on ../observability-aws having run: the online evaluation config reads the
# CloudWatch log groups that module creates, and without Transaction Search the traces it reads are
# sampled rather than complete.
#
# Add it after observability, not before. A team with
# an internal agent and a small audience grades by hand at first. The harness earns its place when
# that output starts reaching people who did not ask for it, or when a drop in quality has to be
# found before a release instead of after one. A platform team standing this up on day one is
# provisioning a judge for an agent nobody is using yet.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# THE JUDGE'S MODEL GRANT FOLLOWS FROM THE EVALUATORS. A custom evaluator names its model by id --
# an inference profile in practice, since every Anthropic model in us-west-2 is profile-only -- and
# the evaluation role has to be allowed to invoke the profile and every foundation model it routes
# to. Left to judge_model_arns alone, CreateOnlineEvaluationConfig fails with "The provided
# execution role does not have permissions to invoke the specified Bedrock models". The profile's
# own model list is the source, so the Regions are never guessed.
locals {
  judge_model_ids      = distinct([for e in var.llm_judge_evaluators : e.model_id])
  judge_profile_ids    = [for id in local.judge_model_ids : id if can(regex("^(us|eu|apac|jp|au|ca|us-gov|global)\\.", id))]
  judge_foundation_ids = [for id in local.judge_model_ids : id if !contains(local.judge_profile_ids, id)]
}

data "aws_bedrock_inference_profile" "judge" {
  for_each             = toset(local.judge_profile_ids)
  inference_profile_id = each.key
}

locals {
  judge_model_arns = distinct(concat(
    var.judge_model_arns,
    [for p in data.aws_bedrock_inference_profile.judge : p.inference_profile_arn],
    flatten([for p in data.aws_bedrock_inference_profile.judge : [for mm in p.models : mm.model_arn]]),
    [for id in local.judge_foundation_ids : "arn:${local.partition}:bedrock:${local.region}::foundation-model/${id}"],
  ))
}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  tags = merge(var.tags, {
    "app.kubernetes.io/part-of" = "eks-agents-paved-paths"
    ManagedBy                   = "terraform/modules/evaluations-aws"
  })
}

# ---------------------------------------------------------------------------
# Execution role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "evaluation_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:*"]
    }
  }
}

resource "aws_iam_role" "evaluation" {
  name               = "${var.name}-agentcore-evaluation"
  assume_role_policy = data.aws_iam_policy_document.evaluation_assume_role.json
  description        = "Execution role for AgentCore Evaluations on cluster ${var.cluster_name}. Reads agent traces and calls the judge model."
  tags               = local.tags
}

data "aws_iam_policy_document" "evaluation" {
  # Reading the traces is the whole input to an evaluation. Scoped to the log groups the
  # observability module created, so the judge sees the agent's trajectory and not every log in the
  # account.
  statement {
    sid    = "ReadAgentTraces"
    effect = "Allow"

    actions = [
      "logs:GetLogEvents",
      "logs:FilterLogEvents",
      "logs:StartQuery",
      "logs:GetQueryResults",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]

    # THE SPANS AS WELL AS THE SOURCE GROUPS, AND BOTH ARN FORMS. The service runs one Logs Insights
    # query across aws/spans and the configured groups together, and without both that call is
    # refused:
    #   StartQuery AccessDenied ... not authorized to perform StartQuery on resources
    #   aws/spans,/aws/eks/<cluster>/agents
    # every five minutes (in CloudTrail), while a query over the source group alone succeeds -- so
    # the configuration reads ACTIVE and grades nothing. A multi-group query is authorized against
    # the bare log-group ARN, not the `:*` form, which is why the source group is refused there
    # too.
    resources = flatten([
      for g in concat(var.source_log_group_names, ["aws/spans"]) : [
        "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${g}",
        "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${g}:*",
      ]
    ])
  }

  # DescribeLogGroups CANNOT BE SCOPED, and the service checks it before the config is created.
  #
  # CreateOnlineEvaluationConfig validates the role against the log groups you named and refuses
  # with a message that says nothing about which action was missing:
  #
  #   ValidationException: The provided execution role does not have permissions to access the
  #   specified log groups
  #
  # That happens with every read action above already granted on exactly those log groups.
  # DescribeLogGroups is a LIST operation -- the service calls it with a name prefix across the
  # account -- so a resource-scoped grant does not satisfy it. The read actions above stay scoped;
  # this one is a discovery call that returns names and no log content.
  statement {
    sid       = "ListLogGroups"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "RunQueries"
    effect    = "Allow"
    actions   = ["logs:StopQuery", "logs:DescribeQueries"]
    resources = ["*"]
  }

  # Where the grades go. Without this the config is created and every evaluation then fails to
  # record its result, which is the shape of failure that looks like the judge never ran.
  statement {
    sid    = "WriteEvaluationResultLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/evaluations/*"]
  }

  # Trace analysis reads the Transaction Search span log group, and the service manages a field
  # index on it so a query over spans is not a full scan. Scoped to `aws/spans` -- this is the only
  # log group either statement touches, and it is the one Transaction Search owns.
  statement {
    sid    = "IndexSpansForTraceAnalysis"
    effect = "Allow"

    actions = [
      "logs:DescribeIndexPolicies",
      "logs:PutIndexPolicy",
    ]

    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:aws/spans",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:aws/spans:*",
    ]
  }

  # The judge model. Scoped, so the grading an agent's output receives comes from a model the team
  # named rather than whatever the config asks for.
  dynamic "statement" {
    for_each = length(local.judge_model_arns) > 0 ? [1] : []

    content {
      sid    = "InvokeJudgeModels"
      effect = "Allow"

      actions = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:Converse",
      ]

      resources = local.judge_model_arns
    }
  }

  dynamic "statement" {
    for_each = var.results_bucket_arn != null ? [1] : []

    content {
      sid    = "WriteEvaluationResults"
      effect = "Allow"

      actions = [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket",
      ]

      resources = [var.results_bucket_arn, "${var.results_bucket_arn}/*"]
    }
  }

  dynamic "statement" {
    for_each = var.kms_key_arn != null ? [1] : []

    content {
      sid       = "EvaluationEncryption"
      effect    = "Allow"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = [var.kms_key_arn]
    }
  }

  # An evaluator reads and grades. It never acts on what it read.
  statement {
    sid       = "NeverWriteAgentState"
    effect    = "Deny"
    actions   = ["iam:*", "eks:*", "bedrock-agentcore:CreateEvent", "bedrock-agentcore:DeleteMemoryRecord"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "evaluation" {
  name   = "agentcore-evaluation"
  role   = aws_iam_role.evaluation.id
  policy = data.aws_iam_policy_document.evaluation.json
}

# ---------------------------------------------------------------------------
# Evaluators
# ---------------------------------------------------------------------------

# An evaluator is a graded dimension: one judge, one rating scale, one set of instructions. A team
# ships a handful rather than one, because a single aggregate score tells nobody which release
# regressed.
resource "aws_bedrockagentcore_evaluator" "llm_judge" {
  for_each = var.llm_judge_evaluators

  # REMOVED ONLY AFTER THE ONLINE CONFIG STOPS NAMING IT. AgentCore refuses to delete an evaluator an
  # active online evaluation config uses ("Cannot delete a locked evaluator"), and without this
  # Terraform deletes the evaluators in parallel with updating the config away from them.
  # create_before_destroy orders the destroy after the config's update.
  lifecycle {
    create_before_destroy = true
  }

  # AgentCore evaluator names take letters, digits and underscores only, so a map key written in
  # kebab-case is converted here rather than constraining how the input is written.
  evaluator_name = replace(each.key, "-", "_")
  description    = each.value.description

  # The grain the evaluator runs at. A trajectory-level evaluator grades how the agent got there; a
  # response-level one grades only what it said. An agent whose failure mode is taking a wrong
  # action does not show up when only its final answer is graded.
  level = each.value.level

  evaluator_config {
    llm_as_a_judge {
      instructions = each.value.instructions

      model_config {
        bedrock_evaluator_model_config {
          model_id = each.value.model_id

          inference_config {
            # No temperature. Zero is what a judge wants -- one that is not reproducible cannot tell
            # a team whether a release regressed or the judge changed its mind -- but Claude Sonnet
            # 5.5 refuses any temperature ("`temperature` is deprecated for this model"), and the
            # rubric's numerical scale is what keeps two runs comparable.
            max_tokens = each.value.judge_max_tokens
          }
        }
      }

      # A numerical scale with a definition per point, not a bare number. The definitions are what
      # make two runs comparable and what a reviewer reads to know what a 3 meant.
      rating_scale {
        dynamic "numerical" {
          for_each = each.value.rating_scale

          content {
            label      = numerical.value.label
            definition = numerical.value.definition
            value      = numerical.value.score
          }
        }
      }
    }
  }

  kms_key_arn = var.kms_key_arn
  tags        = local.tags

  depends_on = [aws_iam_role_policy.evaluation]
}

# ---------------------------------------------------------------------------
# Online evaluation
# ---------------------------------------------------------------------------

# Grading live traffic as it happens, sampled. The sampling percentage is the cost control: every
# sampled session is a judge model call, so 100 means the evaluation harness costs about as much per
# session as the agent did.
# THE ROLE'S GRANT HAS TO HAVE PROPAGATED before the config names a judge that needs it. Create or
# update checks that the execution role may invoke every evaluator's model, and in the same apply as
# a new grant it fails with "The provided execution role does not have permissions to invoke the
# specified Bedrock models"; a second apply passes. Re-armed whenever the
# role's policy changes, as the capabilities' roles are in modules/agent-cluster.
resource "time_sleep" "evaluation_role_propagation" {
  count           = var.enable_online_evaluation ? 1 : 0
  create_duration = "30s"
  triggers = {
    policy = aws_iam_role_policy.evaluation.policy
  }
}

resource "aws_bedrockagentcore_online_evaluation_config" "this" {
  count = var.enable_online_evaluation ? 1 : 0

  depends_on = [time_sleep.evaluation_role_propagation]

  online_evaluation_config_name = replace("${var.name}-agents", "-", "_")
  description                   = "Online evaluation for agents on cluster ${var.cluster_name}."

  evaluation_execution_role_arn = aws_iam_role.evaluation.arn
  enable_on_create              = var.enable_on_create
  # enable_on_create is read only when the configuration is created, so on its own, turning the
  # variable on later changes nothing: the configuration stays DISABLED and grades nothing.
  # execution_status follows the same variable on every apply.
  execution_status = var.enable_on_create ? "ENABLED" : "DISABLED"

  data_source_config {
    cloudwatch_logs {
      log_group_names = var.source_log_group_names
      service_names   = var.source_service_names
    }
  }

  dynamic "evaluator" {
    for_each = concat(var.builtin_evaluators, [for e in aws_bedrockagentcore_evaluator.llm_judge : e.evaluator_id])

    content {
      evaluator_id = evaluator.value
    }
  }

  rule {
    sampling_config {
      sampling_percentage = var.sampling_percentage
    }

    session_config {
      session_timeout_minutes = var.session_timeout_minutes
    }
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# The Strands Evals runner (gitops/charts/agent-evals)
# ---------------------------------------------------------------------------
#
# The release gate on this path: declared test cases run against a deployed agent, graded, and
# written to the same result log group family AgentCore Evaluations uses, so they appear in the
# CloudWatch GenAI Observability dashboard beside the online evaluation's.
#
# Its judge calls go through the AgentCore Gateway on the runner's projected token, so this role
# carries NO model permission. It reads one session's trajectory -- a Logs Insights query over the
# agents' telemetry log group, and over aws/spans for the span hierarchy -- and writes results.
# Nothing else.

data "aws_iam_policy_document" "runner_assume_role" {
  count = var.runner != null ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    # This cluster only. Without it the role could be delivered to a service account of the same
    # name on any cluster in the account.
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.runner.cluster_arn]
    }
  }
}

resource "aws_iam_role" "runner" {
  count = var.runner != null ? 1 : 0

  name               = "${var.name}-evals-runner"
  assume_role_policy = data.aws_iam_policy_document.runner_assume_role[0].json
  description        = "The Strands Evals runner on cluster ${var.cluster_name}: reads agent traces from CloudWatch Logs and writes evaluation results. No model permission -- its judge calls go through the AgentCore Gateway."
  tags               = local.tags
}

data "aws_iam_policy_document" "runner" {
  count = var.runner != null ? 1 : 0

  statement {
    sid     = "QueryAgentTraces"
    effect  = "Allow"
    actions = ["logs:StartQuery"]
    resources = concat(
      [for g in var.source_log_group_names : "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:${g}:*"],
      ["arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:aws/spans:*"],
    )
  }

  # Query results and cancellation are addressed by query id, not by log group, so neither can be
  # resource-scoped.
  statement {
    sid       = "ReadQueryResults"
    effect    = "Allow"
    actions   = ["logs:GetQueryResults", "logs:StopQuery"]
    resources = ["*"]
  }

  # Strands Evals' result writer creates its log group and stream on first use, then appends.
  statement {
    sid    = "WriteEvaluationResults"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/evaluations/results/*",
      "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/bedrock-agentcore/evaluations/results/*:*",
    ]
  }

  # A customer key on the log groups means the QUERYING principal needs kms:Decrypt too: CloudWatch
  # Logs calls KMS on the caller's behalf for StartQuery against an encrypted group (CloudWatch Logs
  # User Guide, "Permissions for reading and writing encrypted log data"). Scoped to calls made
  # through CloudWatch Logs, so the role cannot decrypt with this key directly.
  dynamic "statement" {
    for_each = var.kms_key_arn != null ? [1] : []

    content {
      sid       = "DecryptTraceLogsViaCloudWatchLogs"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.kms_key_arn]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["logs.${local.region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "runner" {
  count = var.runner != null ? 1 : 0

  name   = "agent-evals-runner"
  role   = aws_iam_role.runner[0].id
  policy = data.aws_iam_policy_document.runner[0].json
}

resource "aws_eks_pod_identity_association" "runner" {
  count = var.runner != null ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.runner.namespace
  service_account = var.runner.service_account
  role_arn        = aws_iam_role.runner[0].arn

  tags = local.tags
}
