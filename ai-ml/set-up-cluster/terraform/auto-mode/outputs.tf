output "region" {
  description = "AWS region the deployment was applied to."
  value       = var.region
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Command to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}

output "node_iam_role_name" {
  description = "Node IAM role name. Plug into the reserved-capacity NodeClass when applying it manually."
  value       = module.eks.node_iam_role_name
}
