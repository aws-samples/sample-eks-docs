output "gateway_role_arn" {
  description = "The gateway's IAM role. Pass it to each ../agent-identity as assumable_by_role_arns, so that agent's role trusts this gateway and no other."
  value       = aws_iam_role.gateway.arn
}

output "gateway_namespace" {
  description = "Namespace AgentGateway runs in. The cluster-scoped egress policy in gitops/base/templates names it as the one permitted destination."
  value       = var.gateway_namespace
}

output "gateway_service_account" {
  description = "Service account AgentGateway runs as."
  value       = var.gateway_service_account
}

output "third_party_secret_arns" {
  description = "Map of the credential keys passed in to their Secrets Manager ARNs. Reference these in the AgentgatewayBackend's policies.auth.secretRef; the value is set out of band."
  value       = { for k, v in aws_secretsmanager_secret.third_party : k => v.arn }
}

output "third_party_secret_names" {
  description = "Map of the credential keys to their secret names, which is what a Kubernetes-side secret syncer references."
  value       = { for k, v in aws_secretsmanager_secret.third_party : k => v.name }
}

output "mesh_private_ca_arn" {
  description = "Private CA ARN when enable_mesh_private_ca is set, otherwise empty. The CA is created with no issued certificate: activating it is a deliberate step, not something apply should do silently."
  value       = try(aws_acmpca_certificate_authority.mesh[0].arn, "")
}

output "judge_role_arn" {
  description = "The role the gateway assumes to sign the evaluation judge's model calls, or empty when evaluation is off."
  value       = one(aws_iam_role.judge[*].arn)
}
