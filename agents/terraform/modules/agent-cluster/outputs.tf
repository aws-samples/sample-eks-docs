output "cluster_name" {
  description = "EKS cluster name."
  value       = local.cluster_name
}

output "cluster_arn" {
  description = "EKS cluster ARN. Used in the condition of an agent IAM role's trust policy."
  value       = local.cluster_arn
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint. Private: reachable from inside the VPC only."
  value       = var.create_cluster ? one(aws_eks_cluster.this[*].endpoint) : one(data.aws_eks_cluster.existing[*].endpoint)
}

output "cluster_certificate_authority_data" {
  description = "Base64 cluster CA, for a kubeconfig."
  value       = var.create_cluster ? one(aws_eks_cluster.this[*].certificate_authority[0].data) : one(data.aws_eks_cluster.existing[*].certificate_authority[0].data)
}

output "cluster_oidc_issuer_url" {
  description = <<-EOT
    The cluster's OIDC issuer. Used at one place only: the egress gateway validates the service
    account token an agent presents against this issuer, which is how per-agent routing and policy
    work. It is per-cluster, so a rule written at a relying party against it covers one cluster and
    not a fleet.
  EOT
  value       = var.create_cluster ? one(aws_eks_cluster.this[*].identity[0].oidc[0].issuer) : one(data.aws_eks_cluster.existing[*].identity[0].oidc[0].issuer)
}

output "endpoint_public_access" {
  description = "Whether the API endpoint is public: this module's setting, or the existing cluster's own when create_cluster is false. Without a bastion it is the only way in."
  value       = var.create_cluster ? var.endpoint_public_access : one(data.aws_eks_cluster.existing[*].vpc_config[0].endpoint_public_access)
}

output "cluster_security_group_id" {
  description = "The cluster security group EKS creates. Reference it rather than a CIDR when permitting a data store to be reached from the cluster: a CIDR rule survives a VPC re-address and keeps permitting whatever moved into those addresses."
  value       = var.create_cluster ? one(aws_eks_cluster.this[*].vpc_config[0].cluster_security_group_id) : one(data.aws_eks_cluster.existing[*].vpc_config[0].cluster_security_group_id)
}

output "node_role_arn" {
  description = "IAM role Auto Mode nodes assume. An agent must never be able to reach this; it is here so a reviewer can see what it holds."
  value       = local.node_role_arn
}

output "node_role_name" {
  description = "Name of the IAM role Auto Mode nodes assume. A NodeClass takes the role's NAME rather than its ARN, which is why both are exported."
  value       = local.node_role_name
}

output "agent_permissions_boundary_arn" {
  description = "Permissions boundary every per-agent role is created inside. Pass it to ../agent-identity, and to any other mechanism that creates an agent role."
  value       = aws_iam_policy.agent_permissions_boundary.arn
}

output "agent_role_path" {
  description = "IAM path per-agent roles are created under. The ACK capability role's permissions are scoped to it."
  value       = var.ack_agent_role_path
}

output "ecr_repository_urls" {
  description = "Map of the repository names passed in to their registry URLs."
  value       = { for k, v in aws_ecr_repository.agents : k => v.repository_url }
}

output "capability_arns" {
  description = "ARNs of the EKS Capabilities created, by type. An empty value means that capability was not enabled."
  value = {
    argocd = try(aws_eks_capability.argocd[0].arn, "")
    kro    = try(aws_eks_capability.kro[0].arn, "")
    ack    = try(aws_eks_capability.ack[0].arn, "")
  }
}

output "capability_role_names" {
  description = <<-EOT
    The IAM role names the capabilities assume, by type. The kro one is needed by the base chart:
    the capability's Kubernetes user is that role assumed with the session name /KRO, and the chart
    binds Kubernetes RBAC to it.

    That binding is not optional. The kro capability arrives able to watch ResourceGraphDefinitions
    and nothing else -- it cannot create the resources an RGD composes, nor watch the custom kind
    the RGD defines. Without it the agent resource definition sits Inactive with a cache sync
    timeout while every other condition reports healthy.
  EOT
  value = {
    argocd = try(aws_iam_role.capability_argocd[0].name, "")
    kro    = try(aws_iam_role.capability_kro[0].name, "")
    ack    = try(aws_iam_role.capability_ack[0].name, "")
  }
}

output "argocd_server_url" {
  description = "Argo CD server URL from the managed capability. Empty when the Argo CD capability is not enabled."
  value       = try(aws_eks_capability.argocd[0].configuration[0].argo_cd[0].server_url, "")
}

output "gitops_repo_url" {
  description = "Echoes var.gitops_repo_url so the bootstrap step reads one place for it."
  value       = var.gitops_repo_url
}

output "coredns_cluster_ip_hint" {
  description = <<-EOT
    The address an ApplicationNetworkPolicy should allow for DNS, derived from the cluster's service
    CIDR as the .10 address. Empty for an IPv6 cluster, where the rule is the network address with
    "a" appended.

    Read the caveat in gitops/base/templates/ before pinning it: on EKS Auto Mode CoreDNS runs
    locally on each instance rather than behind one ClusterIP, so the shipped policies allow port 53
    to any address instead of pinning this one. The output exists because a platform team that wants
    the tighter rule should not have to derive it by hand.
  EOT
  value = try(cidrhost(var.create_cluster
    ? one(aws_eks_cluster.this[*].kubernetes_network_config[0].service_ipv4_cidr)
  : one(data.aws_eks_cluster.existing[*].kubernetes_network_config[0].service_ipv4_cidr), 10), "")
}

output "kubernetes_service_ip" {
  description = "The `kubernetes` Service's ClusterIP (the service CIDR's first address): the destination network policy names for an Agent with needsClusterApi. Empty for an IPv6 cluster."
  value = try(cidrhost(var.create_cluster
    ? one(aws_eks_cluster.this[*].kubernetes_network_config[0].service_ipv4_cidr)
  : one(data.aws_eks_cluster.existing[*].kubernetes_network_config[0].service_ipv4_cidr), 1), "")
}

output "ecr_repository_arns" {
  description = "ARNs of the agent image repositories, for granting push access to whatever builds the images. The bastion module takes these so the documented build-and-push step can be performed on the host that can already reach the cluster."
  value       = [for r in aws_ecr_repository.agents : r.arn]
}

output "agent_permission_sets" {
  description = "The permission sets an Agent may name: set name -> {arn, namespaces}."
  value       = { for k, v in var.agent_permission_sets : k => { arn = aws_iam_policy.permission_set[k].arn, namespaces = v.namespaces } }
}
