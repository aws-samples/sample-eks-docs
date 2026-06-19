# Only the dynamic (spot/on-demand) NodePool is managed by Terraform. It references the
# Auto Mode-managed `default` NodeClass, so no NodeClass is applied here. The reserved-capacity
# overflow manifests under nodepools/ (custom NodeClass + NodePool) are applied manually (see the guide).
locals {
  nodepools_manifests_path = "${path.module}/nodepools/dynamic-spot-on-demand"
}

resource "kubectl_manifest" "nodepools" {
  for_each = fileset(local.nodepools_manifests_path, "nodepool-*.yml")

  yaml_body = templatefile("${local.nodepools_manifests_path}/${each.value}", {})

  depends_on = [module.eks]
}
