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
  description = "Karpenter node IAM role name. Plug into the reserved-capacity EC2NodeClass when applying it manually."
  value       = module.karpenter.node_iam_role_name
}
