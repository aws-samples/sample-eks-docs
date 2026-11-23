# The out-of-box agent dashboard on the AWS services path.
#
# The equivalent of gitops/charts/agent-dashboards on the other path, over the same metrics: the
# ADOT collector publishes the OpenTelemetry GenAI metrics as EMF into its metricNamespace
# (gitops/charts/adot-collector/values.yaml, EKSAgents/GenAI), and these widgets read them from
# var.dashboard_metric_namespace, which has to name the same one. metric_namespaces[0] is
# EKSAgents, a namespace nothing writes to, so a widget that read it would always be empty.
#
# The metric names below and the eks.agent dimension are what the collector publishes, and the
# input-token widget returns the agent's tokens. The series
# carry eks.agent and not the cluster name, so in an account with several clusters each dashboard
# also shows the other clusters' agents.
#
# WHY A DASHBOARD WHEN GENAI OBSERVABILITY EXISTS. The curated views answer "what did this
# invocation do" -- per-invocation token counts, the trajectory, tool-call outcomes. They do not
# answer "what are all my agents costing me per hour and which one changed", which is the question a
# platform team has at the start of the week. This is that view, and the two are complements rather
# than alternatives.
#
# THE COST FIGURE IS AN ESTIMATE, AND ON THIS PATH IT HAS TO BE. Every spend widget below is a
# token count multiplied by var.token_prices, a price table in Git. It does not know about
# provisioned throughput, batch pricing, caching discounts or free tiers.
#
# THE OPEN SOURCE PATH DOES NOT NEED A PRICE TABLE and this one does, which is worth understanding
# before copying either. AgentGateway emits `agentgateway_gen_ai_client_cost_usd` -- dollars it
# resolved itself from a model cost catalogue, per model and per agent -- so the Prometheus
# dashboard in gitops/charts/agent-dashboards carries no prices at all. There is no equivalent
# here: AWS/Bedrock publishes token counts, invocations and latency with ModelId as the dimension,
# so CloudWatch offers per-model tokens with no per-agent dimension, and no dollars. Hence the
# table.
#
# Billed cost is in the Cost and Usage Report once the root's activate_cost_allocation_tags has
# activated the cost allocation tags. On this path the model call is signed by the gateway's role,
# so the bill splits an agent's own AWS calls (iamPrincipal/agent) and not its model spend.
#
# IF A WIDGET IS EMPTY, check the dimension names first. The metric names below are the ones the
# agent emits (see the note on local.metric_* ), and whether the EMF exporter renders them with
# these exact dimension names is the thing most likely to differ.

locals {
  dashboard_namespace = var.dashboard_metric_namespace

  # Metric names as the EMF exporter publishes them: the OpenTelemetry name with dots replaced.
  # Verify against what is actually there rather than trusting this list, because a renamed metric
  # produces an empty widget rather than an error:
  #
  #   aws cloudwatch list-metrics --namespace '<namespace>' \
  #     --query 'Metrics[].MetricName' --output text | tr '\t' '\n' | sort -u
  # THE AGENT DOES NOT EMIT THE GenAI CONVENTIONS AS METRICS, which is the fact every widget below
  # depends on. The Strands SDK emits its own family,
  # strands_event_loop_*, and no gen_ai_* metric ever appears. Naming
  # `gen_ai.client.token.usage` or `gen_ai.client.operation.duration` here leaves every widget
  # permanently empty.
  #
  # The GenAI conventions DO arrive as span attributes, and on the open source path the gateway
  # emits them as metrics. Neither helps here: AgentCore Gateway publishes no in-cluster metrics,
  # so this dashboard has only the agent's own series to work with.
  #
  # WHAT THAT COSTS: these carry no model dimension, so the per-model widgets below search on a
  # dimension the series do not have. They are left in place and marked, rather than deleted,
  # because AWS/Bedrock does carry ModelId.
  #
  # A PER-AGENT view IS available. The agent resource definition sets `eks.agent` through
  # OTEL_RESOURCE_ATTRIBUTES and the collector publishes it as a dimension, so the SEARCH
  # expressions below group by it correctly.
  #
  # THE NAMES ARE THE EXPORTER'S, NOT PROMETHEUS'S. The Prometheus rendering flattens dots to
  # underscores and appends a unit suffix (strands_event_loop_input_tokens_token). The awsemf
  # exporter publishes the raw OpenTelemetry names, dots and all, so a widget searching for the
  # Prometheus name stays empty while the metrics arrive. The namespace carries:
  #
  #   strands.event_loop.input.tokens        strands.event_loop.output.tokens
  #   strands.event_loop.latency             strands.event_loop.cycle_duration
  #   strands.event_loop.cycle_count         strands.model.time_to_first_token
  #
  # Read them off the namespace rather than deriving them from the SDK's source, because the
  # exporter is what decides the final name:
  #
  #   aws cloudwatch list-metrics --namespace EKSAgents/GenAI
  metric_input_tokens  = "strands.event_loop.input.tokens"
  metric_output_tokens = "strands.event_loop.output.tokens"
  metric_duration      = "strands.event_loop.latency"

  # ONE expression per direction, priced from ONE row of var.token_prices.
  #
  # Not one per priced model. The agent's token metrics carry no model dimension, so an expression
  # built per price row would search the same series every time: with N rows the dashboard would
  # add the same token count N times, each at a different price, and overstate spend by roughly N.
  # A per-model loop needs a model dimension on these series and the `gen_ai.request.model` filter
  # together, never one without the other.
  #
  # So this is a BLENDED price across models. Set var.token_prices[0] from the model your agents
  # actually use and read the result as "which agent changed this week", not as an allocation. The
  # open source path needs none of this: AgentGateway resolves real dollars per model and per agent.
  blended_price = length(var.token_prices) > 0 ? var.token_prices[0] : { model = "none", input = 0, output = 0 }

  cost_expressions = length(var.token_prices) == 0 ? [] : [
    {
      id         = "ci0"
      expression = "SUM(SEARCH('{${local.dashboard_namespace},eks.agent} MetricName=\"${local.metric_input_tokens}\"', 'Sum', 3600)) * ${local.blended_price.input} / 1000"
      label      = "input @ ${local.blended_price.model}"
    },
    {
      id         = "co0"
      expression = "SUM(SEARCH('{${local.dashboard_namespace},eks.agent} MetricName=\"${local.metric_output_tokens}\"', 'Sum', 3600)) * ${local.blended_price.output} / 1000"
      label      = "output @ ${local.blended_price.model}"
    },
  ]
}

resource "aws_cloudwatch_dashboard" "agents" {
  count = var.create_dashboard ? 1 : 0

  dashboard_name = "${var.name}-agents"

  dashboard_body = jsonencode({
    widgets = concat(
      [
        {
          type   = "text"
          x      = 0
          y      = 0
          width  = 24
          height = 3
          properties = {
            markdown = join("\n", [
              "## Agents · ${var.cluster_name}",
              "",
              "**Spend below is estimated** -- token counts multiplied by the price table in Terraform, not billed cost. Authoritative per-agent cost is in the Cost and Usage Report, keyed on the gateway's `agent` session tag.",
              "",
              "Not shown here: egress refusals (the network policy has no metric), and tool-call outcomes and trajectories (those are spans -- see the GenAI Observability views).",
            ])
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 3
          width  = 12
          height = 6
          properties = {
            title   = "Estimated spend per hour, by direction (blended across models)"
            region  = local.region
            view    = "timeSeries"
            stacked = true
            period  = 3600
            yAxis   = { left = { label = "USD/hour", showUnits = false } }
            metrics = [
              for e in local.cost_expressions : [{ expression = e.expression, label = e.label, id = e.id }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 12
          y      = 3
          width  = 12
          height = 6
          properties = {
            title  = "Input tokens per hour, by agent"
            region = local.region
            view   = "timeSeries"
            period = 3600
            metrics = [
              [{
                expression = "SEARCH('{${local.dashboard_namespace},eks.agent} MetricName=\"${local.metric_input_tokens}\"', 'Sum', 3600)"
                label      = ""
                id         = "tokens"
              }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 0
          y      = 9
          width  = 8
          height = 6
          properties = {
            title  = "Model calls per hour, by agent"
            region = local.region
            view   = "timeSeries"
            period = 3600
            metrics = [
              [{
                expression = "SEARCH('{${local.dashboard_namespace},eks.agent} MetricName=\"${local.metric_duration}\"', 'SampleCount', 3600)"
                label      = ""
                id         = "calls"
              }]
            ]
          }
        },
        {
          type   = "metric"
          x      = 8
          y      = 9
          width  = 8
          height = 6
          properties = {
            title  = "Model call latency, p50 and p95"
            region = local.region
            view   = "timeSeries"
            period = 300
            yAxis  = { left = { label = "seconds", showUnits = false } }
            metrics = [
              [{
                expression = "SEARCH('{${local.dashboard_namespace},eks.agent} MetricName=\"${local.metric_duration}\"', 'p50', 300)"
                label      = "p50"
                id         = "p50"
              }],
              [{
                expression = "SEARCH('{${local.dashboard_namespace},eks.agent} MetricName=\"${local.metric_duration}\"', 'p95', 300)"
                label      = "p95"
                id         = "p95"
              }],
            ]
          }
        },
        {
          type   = "log"
          x      = 16
          y      = 9
          width  = 8
          height = 6
          properties = {
            title  = "Model call errors, last 3h"
            region = local.region
            view   = "table"
            # Reads the telemetry log group the EMF exporter writes to, because an error TYPE is a
            # dimension the metric does not carry usefully -- a throttle and a refusal are the same
            # count and different causes.
            query = join(" | ", [
              "SOURCE '${aws_cloudwatch_log_group.agent_telemetry.name}'",
              "fields @timestamp, `eks.agent` as agent, `error.type` as error",
              "filter ispresent(`error.type`)",
              "stats count() by agent, error",
              "sort by count() desc",
              "limit 20",
            ])
          }
        },
      ],
      var.enable_transaction_search ? [
        {
          type   = "text"
          x      = 0
          y      = 15
          width  = 24
          height = 2
          properties = {
            markdown = "Per-invocation token counts, trajectories and tool-call outcomes are in the **GenAI Observability** views, which Transaction Search populates: https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#gen-ai-observability"
          }
        },
      ] : []
    )
  })
}

check "dashboard_namespace_is_permitted" {
  assert {
    condition     = contains(var.metric_namespaces, var.dashboard_metric_namespace)
    error_message = "dashboard_metric_namespace must be one of metric_namespaces, the namespaces the collector may publish into."
  }
}
