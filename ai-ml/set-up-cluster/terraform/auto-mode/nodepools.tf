# The dynamic (spot/on-demand) set is applied by default. Setting reserved_capacity.enabled = true
# creates an On-Demand Capacity Reservation (ODCR) and switches the gpu-inf NodePool to the
# reserved set (reserved-first, with spot/on-demand overflow).
locals {
  reserved_enabled         = var.reserved_capacity.enabled
  nodepools_manifests_path = local.reserved_enabled ? "${path.module}/nodepools/reserved-capacity-spot-overflow" : "${path.module}/nodepools/dynamic-spot-on-demand"
}

# ODCR — bills immediately until destroyed. Created only when reserved_capacity.enabled = true.
resource "aws_ec2_capacity_reservation" "gpu" {
  count = local.reserved_enabled ? 1 : 0

  instance_type           = var.reserved_capacity.instance_type
  instance_platform       = "Linux/UNIX"
  availability_zone       = coalesce(var.reserved_capacity.az, local.azs[0])
  instance_count          = var.reserved_capacity.instance_count
  instance_match_criteria = "open"
  end_date_type           = "unlimited"

  tags = { Name = "${local.name}-gpu-reserved" }
}

# Dynamic path references the Auto Mode-managed `default` NodeClass (no nodeclass file), so this is
# empty unless reserved capacity is enabled, where the reserved set ships a custom NodeClass.
resource "kubectl_manifest" "nodeclasses" {
  for_each = fileset(local.nodepools_manifests_path, "nodeclass-*.yml")

  yaml_body = templatefile("${local.nodepools_manifests_path}/${each.value}", {
    cluster_name            = local.name
    node_iam_role_name      = module.eks.node_iam_role_name
    capacity_reservation_id = local.reserved_enabled ? aws_ec2_capacity_reservation.gpu[0].id : ""
  })

  depends_on = [module.eks]
}

resource "kubectl_manifest" "nodepools" {
  for_each = fileset(local.nodepools_manifests_path, "nodepool-*.yml")

  yaml_body = templatefile("${local.nodepools_manifests_path}/${each.value}", {})

  depends_on = [kubectl_manifest.nodeclasses, module.eks]
}
