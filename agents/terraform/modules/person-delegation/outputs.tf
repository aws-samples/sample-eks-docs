output "client_id" {
  description = "The exchanger client the gateway authenticates as at the token endpoint."
  value       = awscc_cognito_user_pool_client.exchanger.client_id
}

output "secret_arn" {
  description = "The Secrets Manager secret holding the exchanger's client secret, under the key clientSecret."
  value       = aws_secretsmanager_secret.exchanger.arn
}

output "secret_name" {
  description = "The same secret's name."
  value       = aws_secretsmanager_secret.exchanger.name
}

output "audience" {
  description = "The delegated token's audience (the resource server identifier)."
  value       = aws_cognito_resource_server.tools.identifier
}


output "actor_provider" {
  description = "The provider name the token request gives for the actor token (actor_token_provider_name)."
  value       = aws_cognito_identity_provider.agents.provider_name
}

output "actor_issuer" {
  description = "Who signs the actor token: a tool checks act.iss against it."
  value       = var.actor_issuer
}
