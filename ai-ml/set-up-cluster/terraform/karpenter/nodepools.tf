# Only the dynamic (spot/on-demand) set is managed by Terraform. The reserved-capacity
# overflow manifests under nodepools/ are applied manually (see the guide).
locals {
  nodepools_manifests_path = "${path.module}/nodepools/dynamic-spot-on-demand"
}

resource "kubectl_manifest" "nodeclasses" {
  for_each = fileset(local.nodepools_manifests_path, "nodeclass-*.yml")

  yaml_body = templatefile("${local.nodepools_manifests_path}/${each.value}", {
    cluster_name       = local.name
    node_iam_role_name = module.karpenter.node_iam_role_name
  })

  depends_on = [module.eks]
}

resource "kubectl_manifest" "nodepools" {
  for_each = fileset(local.nodepools_manifests_path, "nodepool-*.yml")

  yaml_body = templatefile("${local.nodepools_manifests_path}/${each.value}", {})

  depends_on = [kubectl_manifest.nodeclasses]
}
