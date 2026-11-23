# agent-dashboards chart

The Prometheus scrape targets, recording rules, and Grafana dashboard for agents on the open source path. Read this when a dashboard panel is empty or you want to change what it shows.

The `agent-dashboards` Application in [`gitops/platform/open-source/templates/50-observability.yaml`](../../platform/open-source/templates/50-observability.yaml) installs it at sync wave 2, after kube-prometheus-stack and the collector, when `enable_observability` is on. Each value is documented in [`values.yaml`](values.yaml). [Observability for agents](https://docs.aws.amazon.com/eks/latest/userguide/agents-observability.html) describes the panels.

## What it renders

| Template | Objects | Rendered when |
|---|---|---|
| `templates/00-servicemonitor.yaml` | A ServiceMonitor for the collector's Prometheus exporter: the agents' own event-loop metrics | Always |
| `templates/05-podmonitor.yaml` | A PodMonitor, `agent-gateway-genai`, for AgentGateway's data plane: per-model tokens and cost in dollars | `gateway.enabled` |
| `templates/10-cost-rules.yaml` | A PrometheusRule with spend, token, and budget recording rules | `cost.enabled` |
| `templates/20-dashboard.yaml` | The Grafana dashboard ConfigMap, picked up by the Grafana sidecar | Always |

## Values you set

| Key | Effect |
|---|---|
| `ruleSelectorLabels` | Labels the PrometheusRule carries. They must match your Prometheus's `ruleSelector`, or the rules are created and never loaded. |
| `budgets` | Hourly token budgets, the default and per agent, for the budget panel. Copy them from the gateway's token-budget policy; the gateway enforces and the panel only reports. |
| `agentMetrics` | The agent metric names and labels the dashboard queries. |
| `collector`, `gateway`, `namespaces` | Where the scrape targets are. |

The chart has no price table: the gateway prices each call from its own model catalogue. Without the gateway, the per-model and spend panels are empty and nothing reports a fault.
