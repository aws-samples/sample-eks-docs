# Which NodePool strategies under nodepools/ are applied is controlled by var.nodepools.
# Defaults to ["dynamic-spot-on-demand"].
#
# Usage:
#   terraform apply
#       -> dynamic-spot-on-demand only (default)
#   terraform apply -var 'nodepools=["reserved-capacity-spot-overflow"]'
#       -> Terraform creates the ODCR and applies the reserved gpu-inf pool (reserved-first, spot/on-demand
#          overflow). Defaults to g6e.4xlarge, 1 instance, in the first cluster AZ (azs[0]).
#   terraform apply -var 'nodepools=["reserved-capacity-spot-overflow"]' -var 'reserved_capacity={instance_type="g6e.4xlarge",instance_count=2}'
#       -> override ODCR instance type / count / az
#
# Notes:
#   - dynamic-spot-on-demand and reserved-capacity-spot-overflow both manage the gpu-inf pool and
#     cannot be enabled together (enforced by a validation on var.nodepools).

locals {
  nodepools_root   = "${path.module}/nodepools"
  reserved_enabled = contains(var.nodepools, "reserved-capacity-spot-overflow")

  nodeclass_files = merge([
    for mode in var.nodepools : {
      for f in fileset("${local.nodepools_root}/${mode}", "nodeclass-*.yml") :
      f => "${local.nodepools_root}/${mode}/${f}"
    }
  ]...)

  nodepool_files = merge([
    for mode in var.nodepools : {
      for f in fileset("${local.nodepools_root}/${mode}", "nodepool-*.yml") :
      f => "${local.nodepools_root}/${mode}/${f}"
    }
  ]...)
}

# ODCR — bills immediately until destroyed. Created only when reserved-capacity-spot-overflow is enabled.
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

# Dynamic Auto Mode pools reference the managed `default` NodeClass (no nodeclass file), so this is
# empty unless a strategy ships its own custom NodeClass (e.g. reserved-capacity-spot-overflow).
resource "kubectl_manifest" "nodeclasses" {
  for_each = local.nodeclass_files

  yaml_body = templatefile(each.value, {
    cluster_name            = local.name
    node_iam_role_name      = module.eks.node_iam_role_name
    capacity_reservation_id = local.reserved_enabled ? aws_ec2_capacity_reservation.gpu[0].id : ""
  })

  depends_on = [module.eks]
}

resource "kubectl_manifest" "nodepools" {
  for_each = local.nodepool_files

  yaml_body = templatefile(each.value, {})

  depends_on = [kubectl_manifest.nodeclasses, module.eks]
}
