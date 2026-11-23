output "tool_audience" {
  description = "The audience every delegated token names."
  value       = aws_cognito_resource_server.tools.identifier
}

output "actor_clients" {
  description = "Each agent's Cognito client id, mapped to the agent's workload subject. A tool reads the actor of a delegated token from act.sub and maps it with this."
  value       = { for k, v in local.agents : awscc_cognito_user_pool_client.agent[k].client_id => v.subject }
}

output "provider_name_prefix" {
  description = "An agent's credential provider is <prefix><agent>-on-behalf-of; its workload identity is <prefix><agent>."
  value       = "${var.name}-"
}

output "agents" {
  description = "Per agent: its credential provider's and workload identity's names and ARNs."
  value = { for k, v in local.agents : k => {
    provider_name     = aws_bedrockagentcore_oauth2_credential_provider.agent[k].name
    provider_arn      = aws_bedrockagentcore_oauth2_credential_provider.agent[k].credential_provider_arn
    workload_name     = aws_bedrockagentcore_workload_identity.agent[k].name
    workload_identity = aws_bedrockagentcore_workload_identity.agent[k].workload_identity_arn
  } }
}
