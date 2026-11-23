# egress-agentcore

The egress gateway on the AWS services path: an Amazon Bedrock AgentCore Gateway with its targets, credential providers, and Cedar policy engine. The `aws-services` root calls it when `enable_gateway` is on. The header of [`main.tf`](main.tf) sets out what the gateway does and doesn't enforce.

The gateway doesn't force traffic to reach it. The egress network policy in [`gitops/base`](../../../gitops/base) does that, by making the gateway the only destination an agent can reach.

## What it creates

| Resource | Notes |
|---|---|
| `aws_bedrockagentcore_gateway.this` and its IAM role | Inbound JWT authorizer against the cluster's OIDC issuer. |
| Gateway targets | `inference_targets` (default: one `bedrock` target on the `bedrock-mantle` connector), `mcp_server_targets`, `open_api_targets`, `lambda_targets`. |
| Credential providers | One per entry in `api_key_providers` and `oauth2_providers`. |
| Policy engine and Cedar policies | With `enable_policy_engine` (default `true`). Temporal (Dogwood) policies in `dogwood_policies` are created through the AWS CLI. |
| Application log delivery to CloudWatch Logs | With `enable_gateway_logs` (default `true`). |

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `name`, `cluster_name`, `oidc_issuer_url` | | |
| `allowed_agent_subjects` | | At most one `system:serviceaccount:<ns>:<name>`. Leave it empty for more than one agent. |
| `allowed_audiences` | `[]` | Token audiences the gateway accepts. |
| `inference_model_arns` | `[]` | Models the gateway's own role may invoke, for semantic tool search and a gateway-applied guardrail. |
| `enable_policy_engine`, `policy_engine_mode` | `true`, `"ENFORCE"` | `LOG_ONLY` records decisions and denies nothing. |
| `cedar_policies` | `{}` | Write `{{gateway_arn}}` where the gateway's ARN goes; it's substituted at apply. A policy may set `validation_mode` to override `policy_validation_mode` for itself; only the AWS services root's generated baseline forbid does. |
| `dogwood_policies`, `dogwood_enforcement_mode`, `enable_temporal_policies` | `{}`, `"LOG_ONLY"`, `false` | Temporal policies. With them on, every request must carry the `x-amzn-bedrock-agentcore-policy-session-id` header. |
| `guardrail_policies` | `{}` | Statements whose conditions call a guardrail, created ACTIVE through the AWS CLI with `IGNORE_ALL_FINDINGS`. Any of them grants the gateway's role `bedrock:InvokeGuardrailChecks`. The AWS services root generates them from `gateway_guardrails`. |
| `*_kms_key_arn` | `null` | Customer managed keys for the gateway, policy engine, and credentials. |

## Outputs

`gateway_url`, `gateway_arn`, `gateway_hostname`, `gateway_role_arn`, `model_endpoint` (the OpenAI-compatible `/inference/v1`), `mcp_endpoint`, `inference_target_names`, `policy_engine_arn`, `oauth2_callback_urls`, `gateway_log_group_name`, and `dogwood_policies_to_apply`. See [`outputs.tf`](outputs.tf).

## Constraints

* A gateway admits at most one service account subject: `sub` is a string claim, so only `EQUALS` works, and a second rule on `sub` is rejected. With more than one agent, separate them with the network policy and the policy engine. See [AgentCore Gateway](https://docs.aws.amazon.com/eks/latest/userguide/agents-gateway.html).
* With `policy_engine_mode = "ENFORCE"` and no Cedar policies, the gateway denies every call; the root's `checks.tf` warns about it.
* An inference target's model must serve the OpenAI dialect, and model IDs are the connector's own (`bedrock/<provider>.<model>`), not Bedrock model IDs. `inference_model_arns` doesn't bound which advertised models a caller can reach; the variable's description lists what does.
