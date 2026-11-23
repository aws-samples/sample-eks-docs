output "role_arns" {
  description = "Each agent's person role, by agent: what that agent exchanges a person's ID token for."
  value       = { for a, r in aws_iam_role.person : a => r.arn }
}

output "role_arn_prefix" {
  description = "The person roles' ARN up to the agent name: <prefix><agent>-person-data."
  value       = "arn:${data.aws_partition.current.partition}:iam::${var.account_id}:role${var.role_path}${var.name}-"
}

output "agents" {
  description = "The agents that have a person role."
  value       = var.agents
}

output "bucket" {
  description = "The bucket holding each person's data under people/<sub>/."
  value       = aws_s3_bucket.people.bucket
}

output "issuer" {
  description = "The pool's issuer URL, which a tool verifies a person's token against."
  value       = local.issuer_url
}

output "api_client_id" {
  description = "The client an application signs a person in with to receive an ID token."
  value       = aws_cognito_user_pool_client.api.id
}

output "oidc_provider_arn" {
  description = "The IAM OIDC provider for the pool."
  value       = local.oidc_provider_arn
}
