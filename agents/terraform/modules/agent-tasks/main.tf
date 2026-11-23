# Agents that run as tasks (enable_agent_tasks): an agent's work arrives on a queue rather than as
# a request, and each task runs in its own short-lived sandboxed pod (Agent runtime: tasks).
#
# PER AGENT, three queues, named for the cluster and the agent so the base chart can derive them:
#
#   <cluster>-<agent>-tasks        where a producer sends a task. KEDA starts one pod per waiting
#                                  message; the pod keeps the message invisible while it works.
#   <cluster>-<agent>-tasks-dlq    where a task goes after max_receive_count failed attempts, so a
#                                  task that always fails stops consuming pods and stays inspectable.
#   <cluster>-<agent>-results      where the pod sends the answer, keyed by the task id.
#
# The agent's own role uses them through a permission set, tasks-<agent> (see outputs), which the
# root adds to agent_permission_sets: receive, delete and extend visibility on its task queue, send
# to its result queue, and nothing on any other agent's. KEDA reads queue depth with its own role.
#
# WHO MAY SEND A TASK is the producer's IAM, not anything here: grant sqs:SendMessage on the task
# queue to the services that should be able to start this agent's work. Every task runs with the
# agent's permissions, so treat send access to a task queue as access to the agent.

locals {
  queues = { for a in var.agents : a => {
    tasks   = "${var.name}-${a}-tasks"
    dlq     = "${var.name}-${a}-tasks-dlq"
    results = "${var.name}-${a}-results"
  } }
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.queues

  name                      = each.value.dlq
  message_retention_seconds = 1209600 # 14 days, the maximum, to inspect what failed
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue" "tasks" {
  for_each = local.queues

  name                       = each.value.tasks
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })
  tags = var.tags
}

resource "aws_sqs_queue" "results" {
  for_each = local.queues

  name                      = each.value.results
  message_retention_seconds = var.message_retention_seconds
  receive_wait_time_seconds = 20
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

# Only TLS, for every principal, on all three.
locals {
  all_queues = merge(
    { for a, _ in local.queues : "${a}-tasks" => aws_sqs_queue.tasks[a] },
    { for a, _ in local.queues : "${a}-dlq" => aws_sqs_queue.dlq[a] },
    { for a, _ in local.queues : "${a}-results" => aws_sqs_queue.results[a] },
  )
}

resource "aws_sqs_queue_policy" "tls_only" {
  for_each  = local.all_queues
  queue_url = each.value.url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "sqs:*"
      Resource  = each.value.arn
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# KEDA's own identity: queue depth on the task queues, nothing else. It never touches a message.
data "aws_iam_policy_document" "keda_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keda" {
  name               = "${var.name}-keda-operator"
  path               = var.role_path
  assume_role_policy = data.aws_iam_policy_document.keda_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "keda" {
  statement {
    sid       = "TaskQueueDepth"
    actions   = ["sqs:GetQueueAttributes"]
    resources = [for a, _ in local.queues : aws_sqs_queue.tasks[a].arn]
  }
}

resource "aws_iam_role_policy" "keda" {
  name   = "task-queue-depth"
  role   = aws_iam_role.keda.id
  policy = data.aws_iam_policy_document.keda.json
}

resource "aws_eks_pod_identity_association" "keda" {
  cluster_name    = var.cluster_name
  namespace       = var.keda_namespace
  service_account = var.keda_service_account
  role_arn        = aws_iam_role.keda.arn
  tags            = var.tags
}
