# agentgateway-config chart

AgentGateway's configuration on the open source path: its GatewayClass and Gateway, a backend per destination, the routes, and the policies. Read this before you add a destination, an MCP server, or a gateway policy.

The `agentgateway-config` Application in [`gitops/platform/open-source/templates/31-agentgateway-config.yaml`](../../platform/open-source/templates/31-agentgateway-config.yaml) installs it at sync wave 1, after the gateway itself, when `enable_gateway` is on. Each value is documented in [`values.yaml`](values.yaml).

## What it renders

| Template | Objects | Rendered when |
|---|---|---|
| `templates/00-gateway.yaml` | The GatewayClass, the Gateway, and the inbound authentication policy | Always |
| `templates/05-capture.yaml` | The transparent-capture parameters and ServiceEntry | `capture.enabled`, off by default |
| `templates/10-backends.yaml` | `AgentgatewayBackend`s for Bedrock, MCP servers, other destinations, and the evaluation judge | Per entry |
| `templates/20-routes.yaml` | The HTTPRoutes: `/llm`, `/mcp`, the judge's route, and one per destination | Per entry |
| `templates/30-policies.yaml` | Tool policy, token budgets, model failover, and transparent egress | Per value |

## Values you set

| Key | Effect |
|---|---|
| `destinations` | Third-party APIs the gateway brokers a credential for, keyed to `third_party_credentials` in Terraform, and which agents may call each. |
| `mcpServers` | MCP servers, in-cluster by label selector or remote by host. |
| `toolPolicy`, `promptGuard` | CEL authorization per tool call, and an Amazon Bedrock guardrail on prompts. |
| `budgets` | Per-agent token budgets. |
| `model` | The Bedrock model, its fallbacks, and whether each agent's calls use its own role. |
| `agents` | The agents allowed to use the gateway, derived from Terraform's `agents` map, with one model backend and route each. |

`region`, `cluster`, `oidcIssuerUrl`, `agentResource`, and `evals` come from `terraform-values.yaml`, and the chart refuses to render without the Region or the OIDC issuer.

## Constraints

* `agents` and the `Agent` resource are alternatives. With `agentResource.enabled`, `agents` is empty and each `Agent` composes its own model backend and route.
* An in-cluster MCP Service must set `appProtocol: agentgateway.dev/mcp` on its port, and its selector must name the Service's namespace. Either mistake returns 503 with `mcp: no backends configured`.
