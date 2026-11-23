variable "name" {
  description = "Name prefix, normally the cluster name."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster the agents run on."
  type        = string
}

variable "cluster_arn" {
  description = "ARN of that cluster, for the Pod Identity condition on the collector's trust policy."
  type        = string
}

variable "enable_transaction_search" {
  description = <<-EOT
    Enable CloudWatch Transaction Search. This is the prerequisite for the GenAI Observability
    views; without it the agent's spans are sampled traces and the per-invocation token counts and
    tool-call outcomes do not appear.

    It is an account-and-Region setting. Enable it in exactly one root module per Region, or two
    applies will fight over it.
  EOT
  type        = bool
  default     = true
}

variable "transaction_search_indexing_percentage" {
  description = "How much of the span volume is indexed for search, 0 to 100. Indexing is billed on volume; below 100, a specific agent invocation may not be findable."
  type        = number
  default     = 100

  validation {
    condition     = var.transaction_search_indexing_percentage >= 0 && var.transaction_search_indexing_percentage <= 100
    error_message = "transaction_search_indexing_percentage must be between 0 and 100."
  }
}

variable "collector_namespace" {
  description = "Namespace the ADOT collector runs in."
  type        = string
  default     = "opentelemetry-operator-system"
}

variable "collector_service_account" {
  description = "Service account the ADOT collector runs as. Must match the collector manifest in gitops/platform/aws-services/, or the association delivers credentials to nothing."
  type        = string
  default     = "adot-collector"
}

variable "metric_namespaces" {
  description = "CloudWatch metric namespaces the collector may publish into. Scoped, so a collector misconfiguration cannot write into another team's namespace."
  type        = list(string)
  default     = ["EKSAgents", "EKSAgents/GenAI"]

  validation {
    condition     = length(var.metric_namespaces) > 0
    error_message = "Name at least one metric namespace. An empty list makes the condition unsatisfiable and the collector publishes nothing."
  }
}

variable "log_retention_days" {
  description = "Retention on the agent log groups. Agent traces carry prompts and tool arguments, which is content with its own retention question, so this is an input rather than a default of never expire."
  type        = number
  default     = 90
}

variable "log_kms_key_arn" {
  description = "KMS key for the agent log groups. Null uses the CloudWatch Logs service key. A customer-managed key is what lets a key policy decide who reads an agent's prompts."
  type        = string
  default     = null
}

variable "enable_cloudwatch_observability_addon" {
  description = "Install the amazon-cloudwatch-observability add-on, for Container Insights and the node-local X-Ray and OTLP receivers. This is the infrastructure half: it makes the pod an agent ran in visible next to the agent's own telemetry."
  type        = bool
  default     = true
}

variable "cloudwatch_observability_addon_version" {
  description = "Add-on version. Null takes the default for the cluster's Kubernetes version, which moves; pin it for a reproducible cluster."
  type        = string
  default     = null
}

variable "enable_container_logs" {
  description = "Send agent container logs to CloudWatch Logs through the add-on. Off by default: an agent's container log duplicates prompts and model output the OTLP pipeline already carries, into a second place with its own retention."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

# --- Dashboard ---------------------------------------------------------------

variable "create_dashboard" {
  description = "Create the out-of-box agent CloudWatch dashboard. The equivalent of gitops/charts/agent-dashboards on the open source path: estimated spend, tokens, call rate, latency and errors per agent."
  type        = bool
  default     = true
}

variable "token_prices" {
  description = <<-EOT
    Price table the dashboard's spend widgets multiply token counts by. USD per 1,000 tokens.

    THIS PRODUCES AN ESTIMATE, not billed cost. It does not know about provisioned throughput, batch
    pricing, prompt caching discounts or free tiers, and it drifts the moment a price changes.
    Billed cost is in the Cost and Usage Report once the root's activate_cost_allocation_tags has
    activated the cost allocation tags. On the AWS services path the gateway signs model calls with
    its own role, so the bill does not split model spend per agent.

    A model with no row here contributes nothing to the spend widgets and still appears in the token
    widgets, so a missing row shows up as tokens without spend rather than as silence.
  EOT
  type = list(object({
    model  = string
    input  = number
    output = number
  }))
  default = [
    # us-west-2 on-demand, cross-Region (us.) profile, from the AWS Price List:
    # $2.20 and $11.00 per million input and output tokens.
    { model = "anthropic.claude-sonnet-5-5", input = 0.0022, output = 0.011 },
    { model = "anthropic.claude-haiku-4-5-20251001-v1:0", input = 0.001, output = 0.005 },
    { model = "amazon.nova-pro-v1:0", input = 0.0008, output = 0.0032 },
    { model = "amazon.nova-lite-v1:0", input = 0.00006, output = 0.00024 },
  ]
}

variable "dashboard_metric_namespace" {
  description = "The CloudWatch metric namespace the dashboard reads. Must be the ADOT collector's metricNamespace (gitops/charts/adot-collector/values.yaml) and one of metric_namespaces."
  type        = string
  default     = "EKSAgents/GenAI"
}

variable "enable_network_policy_logs" {
  description = "Ship the nodes' network policy verdicts (every ACCEPT and DENY, per flow) to the /aws/eks/<cluster>/network-policy log group, through the CloudWatch Observability add-on's Fluent Bit, and add them to the policy-decisions dashboard. Needs the add-on, and networkPolicyEventLogs on the agents' NodeClass, which the base sets."
  type        = bool
  default     = true
}

variable "gateway_id" {
  description = "The AgentCore Gateway's id, for the dashboard's Cedar decision panels (the TargetResource dimension of AWS/Bedrock-AgentCore). Empty: no gateway panels."
  type        = string
  default     = ""
}

variable "cluster_log_types" {
  description = "The control plane log types the cluster sends. With \"audit\" in it, the dashboard and a saved query show admission refusals."
  type        = list(string)
  default     = []
}
