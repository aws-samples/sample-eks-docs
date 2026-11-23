output "gateway_id" {
  description = "AgentCore Gateway ID."
  value       = aws_bedrockagentcore_gateway.this.gateway_id
}

output "gateway_arn" {
  description = "AgentCore Gateway ARN."
  value       = aws_bedrockagentcore_gateway.this.gateway_arn
}

output "gateway_url" {
  description = <<-EOT
    The MCP endpoint agents call. This is the hostname the cluster-scoped egress policy in
    gitops/base/templates permits, and the one an agent is configured to reach.

    Nothing in AWS forces an agent's traffic here. The network policy is what makes it the only
    reachable destination, and Istio ambient capture is what makes arrival enforced rather than
    agreed; see the agents page of the EKS User Guide.
  EOT
  value       = aws_bedrockagentcore_gateway.this.gateway_url
}

output "gateway_hostname" {
  description = "Hostname part of the gateway URL, for a network policy domainNames rule."
  value       = try(regex("^https?://([^/:]+)", aws_bedrockagentcore_gateway.this.gateway_url)[0], "")
}

output "gateway_role_arn" {
  description = "The gateway's execution role."
  value       = aws_iam_role.gateway.arn
}

output "workload_identity_details" {
  description = "Workload identity details the service returns for this gateway."
  value       = aws_bedrockagentcore_gateway.this.workload_identity_details
}

output "policy_engine_arn" {
  description = "Cedar policy engine ARN, empty when the policy engine is disabled."
  value       = try(aws_bedrockagentcore_policy_engine.this[0].policy_engine_arn, "")
}

output "api_key_provider_arns" {
  description = "Map of api_key_providers keys to their credential provider ARNs."
  value       = { for k, v in aws_bedrockagentcore_api_key_credential_provider.this : k => v.credential_provider_arn }
}

output "oauth2_provider_arns" {
  description = "Map of oauth2_providers keys to their credential provider ARNs."
  value       = { for k, v in aws_bedrockagentcore_oauth2_credential_provider.this : k => v.credential_provider_arn }
}

output "oauth2_callback_urls" {
  description = <<-EOT
    The callback URL each OAuth2 provider expects, which has to be registered with that service's
    own app configuration before the first consent flow can complete.

    The person's approval happens in a browser, out of band from the agent, so something has to
    receive it. On this path that is the
    web service the platform team supplies, once per service an agent reaches this way.
  EOT
  value       = { for k, v in aws_bedrockagentcore_oauth2_credential_provider.this : k => v.callback_url }
}

output "target_ids" {
  description = "Map of every target name to its target ID."
  value = merge(
    { for k, v in aws_bedrockagentcore_gateway_target.mcp_server : k => v.target_id },
    { for k, v in aws_bedrockagentcore_gateway_target.open_api : k => v.target_id },
  )
}

# ---------------------------------------------------------------------------
# The two endpoints an agent is configured with
# ---------------------------------------------------------------------------

# One gateway, two paths. Deriving both from the origin here means no caller hand-assembles a URL,
# and no agent is handed a hostname with no scheme on it.
locals {
  gateway_origin = try(regex("^https?://[^/]+", aws_bedrockagentcore_gateway.this.gateway_url), "")
}

output "model_endpoint" {
  description = <<-EOT
    The OpenAI-compatible model endpoint, for OPENAI_BASE_URL on an agent.

    Requires at least one inference target (var.inference_targets, on by default for Bedrock).
    With no inference target the gateway serves tools only and this endpoint returns no model, so
    an agent whose egress policy permits the gateway and nothing else cannot reach a model at all.

    Empty when inference targets are disabled, which scripts/validate.sh treats as a failure on
    this path rather than rendering an agent that cannot call a model.
  EOT
  value       = length(var.inference_targets) > 0 ? "${local.gateway_origin}/inference/v1" : ""
}

output "mcp_endpoint" {
  description = "The MCP endpoint, for an agent's tool client. The gateway's own URL, unmodified."
  value       = aws_bedrockagentcore_gateway.this.gateway_url
}

output "inference_target_names" {
  description = "Inference target names. An agent selects one by prefixing the model id, as target/model."
  value       = keys(aws_bedrockagentcore_gateway_target.inference)
}

output "dogwood_policies_to_apply" {
  description = <<-EOT
    Temporal policies with {{gateway_arn}} resolved, keyed by name. This module applies them
    through the AWS CLI, because aws_bedrockagentcore_policy does not expose `definition.policy`.

    The equivalent manual call:

      aws bedrock-agentcore-control create-policy \
        --policy-engine-id <id> --name <name> --validation-mode FAIL_ON_ANY_FINDINGS \
        --enforcement-mode LOG_ONLY \
        --definition '{"policy":{"statement":"<statement>"}}'

    LOG_ONLY first, deliberately: a temporal policy decides on history, so the first thing worth
    knowing is what it WOULD have denied. Promote to ACTIVE once that is boring.
  EOT
  value = {
    for k, v in var.dogwood_policies : k => {
      description = v.description
      statement   = replace(v.statement, "{{gateway_arn}}", try(aws_bedrockagentcore_gateway.this.gateway_arn, ""))
    }
  }
}

output "gateway_log_group_name" {
  description = "The gateway's application log group, or null when enable_gateway_logs is false. Read it first when a tool call returns 'An internal error occurred'."
  value       = try(aws_cloudwatch_log_group.gateway[0].name, null)
}
