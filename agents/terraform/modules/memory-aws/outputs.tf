output "session_state_endpoint" {
  description = <<-EOT
    Valkey endpoint for session state as "address:port", empty when that rung is not enabled.

    A STRING, deliberately. The ElastiCache attribute is a set of objects, and passed through it
    would reach the agent's environment as a Go-formatted structure no client can parse. The open
    source path supplies a plain service DNS name here, and the chart treats both the same way.
  EOT
  value = try(
    format(
      "%s:%s",
      tolist(aws_elasticache_serverless_cache.session_state[0].endpoint)[0].address,
      tolist(aws_elasticache_serverless_cache.session_state[0].endpoint)[0].port,
    ),
    "",
  )
}

output "session_state_security_group_id" {
  description = "Security group on the session state cache, empty when that rung is not enabled."
  value       = try(aws_security_group.session_state[0].id, "")
}

output "semantic_recall_bucket_arn" {
  description = "S3 Vectors bucket ARN, empty when semantic recall is not enabled."
  value       = try(aws_s3vectors_vector_bucket.semantic[0].vector_bucket_arn, "")
}

output "semantic_recall_index_arns" {
  description = "Map of index names to ARNs."
  value       = { for k, v in aws_s3vectors_index.semantic : k => v.index_arn }
}

output "memory_id" {
  description = "AgentCore Memory ID, empty when consolidation is not enabled. An agent reads and writes it from application code: there is no ACK controller for it, so it is the one AWS dependency in this stack that cannot be composed into the agent-shaped resource."
  value       = try(aws_bedrockagentcore_memory.this[0].id, "")
}

output "memory_arn" {
  description = "AgentCore Memory ARN, for the agent role's own policy."
  value       = try(aws_bedrockagentcore_memory.this[0].arn, "")
}

output "memory_execution_role_arn" {
  description = "Role AgentCore Memory assumes to run extraction and consolidation."
  value       = try(aws_iam_role.memory[0].arn, "")
}

output "session_state_user_arn" {
  description = "ARN of the IAM-authenticated ElastiCache user for session state, empty when a user group was supplied or the rung is off. An agent's role needs elasticache:Connect on both this and the cache."
  value       = try(aws_elasticache_user.session_state_agents[0].arn, "")
}

output "session_state_user_name" {
  description = "User name an agent authenticates as. ElastiCache requires it to equal the user id for IAM authentication."
  value       = try(aws_elasticache_user.session_state_agents[0].user_name, "")
}

output "session_state_agent_user_arns" {
  description = "Per-agent ElastiCache user ARNs, keyed by the agent name given in session_state_agent_keyspaces. Grant each agent's role elasticache:Connect on the cache and ONLY on its own entry here: a role scoped that way is refused with WRONGPASS at AUTH if it presents another agent's user. Empty when the map is empty, which is when every agent shares the one ~* user."
  value       = { for k, u in aws_elasticache_user.session_state_agent : k => u.arn }
}

output "session_state_agent_user_names" {
  description = "Per-agent user names to authenticate as, keyed by agent name. Equal to the user ids because ElastiCache requires that for IAM authentication."
  value       = { for k, u in aws_elasticache_user.session_state_agent : k => u.user_name }
}

output "session_state_cache_arn" {
  description = "ARN of the session state cache, for the elasticache:Connect grant."
  value       = try(aws_elasticache_serverless_cache.session_state[0].arn, "")
}
