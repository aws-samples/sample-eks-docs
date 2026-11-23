# observability-aws

Observability on the AWS services path: CloudWatch Transaction Search, the agent log groups, the ADOT collector's IAM role, the CloudWatch Observability add-on, and a CloudWatch dashboard. The `aws-services` root calls it when `enable_observability` is on. The collector itself is the [`adot-collector`](../../../gitops/charts/adot-collector) chart, and the agent's instrumentation is the same on both paths.

## What it creates

| Resource | Notes |
|---|---|
| Transaction Search | With `enable_transaction_search` (default `true`): the X-Ray segment destination, an indexing rule, and the log resource policy. Without it, the GenAI Observability views show sampled traces. |
| Log groups | `/aws/eks/<cluster>/agents` for telemetry and `/aws/eks/<cluster>/agents/application`, with `log_retention_days` and `log_kms_key_arn`. |
| `aws_iam_role.collector` and its Pod Identity association | For `collector_namespace`/`collector_service_account`. May publish metrics only into `metric_namespaces`. |
| `amazon-cloudwatch-observability` add-on | With `enable_cloudwatch_observability_addon` (default `true`), for Container Insights. |
| `aws_cloudwatch_dashboard.agents` | With `create_dashboard` (default `true`): estimated spend, tokens, call rate, latency, and errors per agent. |
| Network policy verdicts | With `enable_network_policy_logs` (default `true`): the log group `/aws/eks/<cluster>/network-policy`, and the add-on's Fluent Bit configured to ship the verdict log alone from each node. The add-on's `cloudwatch-agent` service account gets a Pod Identity role with `CloudWatchAgentServerPolicy`. |
| `aws_cloudwatch_dashboard.policy_decisions` and saved queries | With `create_dashboard`: network policy denials, the gateway's Cedar decisions when `gateway_id` is set, and admission refusals when `cluster_log_types` includes `audit`. Queries are in the Logs Insights folder `<name>/policy-decisions`. See [Agent observability](https://docs.aws.amazon.com/eks/latest/userguide/agents-observability.html). |

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `name`, `cluster_name`, `cluster_arn` | | |
| `enable_transaction_search`, `transaction_search_indexing_percentage` | `true`, `100` | |
| `collector_namespace`, `collector_service_account` | `"opentelemetry-operator-system"`, `"adot-collector"` | Must match the collector chart. |
| `metric_namespaces` | `["EKSAgents", "EKSAgents/GenAI"]` | The dashboard reads the first. |
| `log_retention_days`, `log_kms_key_arn` | `90`, `null` | Traces carry prompts and tool arguments, so set both deliberately. |
| `cloudwatch_observability_addon_version`, `enable_container_logs` | `null`, `false` | |
| `create_dashboard`, `token_prices` | `true`, see `variables.tf` | USD per 1,000 tokens. |
| `enable_network_policy_logs`, `gateway_id`, `cluster_log_types` | `true`, `""`, `[]` | The policy decisions view. The root passes the gateway's id and its control plane log types. |

## Outputs

`collector_role_arn`, `collector_namespace`, `collector_service_account`, `telemetry_log_group_name`, `application_log_group_name`, `transaction_search_enabled`, `genai_observability_console_url`, `dashboard_url`.

## Constraints

* Transaction Search is an account and Region setting. Turn it on in one root per Region, or two applies fight over it.
* The dashboard's spend figures are token counts times `token_prices`, an estimate. Billed per-agent cost comes from the Cost and Usage Report once the cost allocation tags are active. See [Agent observability](https://docs.aws.amazon.com/eks/latest/userguide/agents-observability.html).
* The dashboard searches the metric names the EMF exporter publishes, such as `strands.event_loop.input.tokens`. If a widget is empty, list the metrics in the namespace with `aws cloudwatch list-metrics` and compare.
