output "collector_role_arn" {
  description = "IAM role the ADOT collector assumes. Writes telemetry; explicitly denied every read."
  value       = aws_iam_role.collector.arn
}

output "collector_namespace" {
  description = "Namespace the collector runs in."
  value       = var.collector_namespace
}

output "collector_service_account" {
  description = "Service account the collector runs as."
  value       = var.collector_service_account
}

output "telemetry_log_group_name" {
  description = "Log group the agent's OTLP telemetry lands in."
  value       = aws_cloudwatch_log_group.agent_telemetry.name
}

output "application_log_group_name" {
  description = "Log group for the agent's application logs."
  value       = aws_cloudwatch_log_group.agent_application.name
}

output "transaction_search_enabled" {
  description = "Whether this module enabled Transaction Search. When false, the GenAI Observability views will not carry per-invocation token counts or tool-call outcomes, whatever the agent emits."
  value       = var.enable_transaction_search
}

output "genai_observability_console_url" {
  description = "Where the curated agent views are read. The open source path has no equivalent: those dashboards are the part the platform team assembles itself."
  value       = "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#gen-ai-observability"
}

output "dashboard_url" {
  description = "The out-of-box agent dashboard. Its spend widgets are estimates from var.token_prices, not billed cost."
  value       = var.create_dashboard ? "https://${local.region}.console.aws.amazon.com/cloudwatch/home?region=${local.region}#dashboards:name=${aws_cloudwatch_dashboard.agents[0].dashboard_name}" : ""
}
