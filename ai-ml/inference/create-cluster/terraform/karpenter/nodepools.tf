locals {
  compute_manifests_path = "${path.module}/manifests/compute"
}

resource "kubectl_manifest" "nodeclasses" {
  for_each = fileset(local.compute_manifests_path, "nodeclass-*.yml")

  yaml_body = templatefile("${local.compute_manifests_path}/${each.value}", {
    cluster_name            = local.cluster_name
    node_iam_role_name      = module.karpenter.node_iam_role_name
    capacity_reservation_id = var.capacity_reservation_id
  })

  depends_on = [module.eks]
}

resource "kubectl_manifest" "nodepools" {
  for_each = fileset(local.compute_manifests_path, "nodepool-*.yml")

  yaml_body = templatefile("${local.compute_manifests_path}/${each.value}", {})

  depends_on = [kubectl_manifest.nodeclasses]
}
