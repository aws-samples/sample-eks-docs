output "region" {
  description = "AWS region the deployment was applied to."
  value       = var.region
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, ordered by AZ."
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, ordered by AZ."
  value       = module.vpc.public_subnets
}

output "azs" {
  description = "Availability zones the VPC's subnets span."
  value       = local.azs
}

output "shared_security_group_id" {
  description = "Shared SG for intra-VPC connectivity."
  value       = aws_security_group.shared.id
}

output "configure_kubectl" {
  description = "Command to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = module.eks.cluster_endpoint
}

output "cluster_primary_security_group_id" {
  description = "EKS-managed cluster primary SG (mutual ingress with shared SG wired in eks.tf)."
  value       = module.eks.cluster_primary_security_group_id
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA / Pod Identity associations."
  value       = module.eks.oidc_provider_arn
}

output "capacity_reservation_id" {
  description = "[Optional] Capacity Reservation ID. Empty string omits the selector entirely."
  value       = var.capacity_reservation_id
}
