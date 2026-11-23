output "role_arn" {
  description = "The agent's IAM role. This is what the egress gateway assumes to sign the agent's model calls."
  value       = aws_iam_role.agent.arn
}

output "role_name" {
  description = "The agent's IAM role name."
  value       = aws_iam_role.agent.name
}

output "service_account" {
  description = "Service account the association covers. Create it in the cluster with automountServiceAccountToken: false; this module does not create Kubernetes objects."
  value       = local.service_account
}

output "namespace" {
  description = "Namespace the association covers."
  value       = var.namespace
}

output "association_id" {
  description = "Pod Identity association ID."
  value       = aws_eks_pod_identity_association.agent.association_id
}

output "session_tags_enabled" {
  description = "False when a session policy is in effect, because the two are exclusive. When false, any IAM policy elsewhere that conditions on a Pod Identity session tag stops matching for this agent."
  value       = var.session_policy_json == null
}

output "checkpoint_prefix" {
  description = "Prefix in the checkpoint bucket this agent may read and write. Pass it to the agent as configuration; an agent that chooses its own prefix gets AccessDenied, which is the intent."
  value       = local.checkpoint_prefix
}
