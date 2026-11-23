output "evaluation_role_arn" {
  description = "Role AgentCore Evaluations assumes to read traces and call the judge model."
  value       = aws_iam_role.evaluation.arn
}

output "evaluator_ids" {
  description = "Map of evaluator names to IDs."
  value       = { for k, v in aws_bedrockagentcore_evaluator.llm_judge : k => v.evaluator_id }
}

output "evaluator_arns" {
  description = "Map of evaluator names to ARNs."
  value       = { for k, v in aws_bedrockagentcore_evaluator.llm_judge : k => v.evaluator_arn }
}

output "online_evaluation_config_id" {
  description = "Online evaluation config ID, empty when online evaluation is not enabled."
  value       = try(aws_bedrockagentcore_online_evaluation_config.this[0].online_evaluation_config_id, "")
}

output "online_evaluation_running" {
  description = "Whether the online evaluation was started on create. False means it exists and grades nothing until someone starts it."
  value       = var.enable_online_evaluation && var.enable_on_create
}

output "runner_role_arn" {
  description = "The Strands Evals runner's Pod Identity role, or empty when evaluation is off."
  value       = one(aws_iam_role.runner[*].arn)
}
