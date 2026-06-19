# GPU NodePools, controlled by var.nodepools (a map keyed by folder name under nodepools/).
# Defaults to { "dynamic-spot-on-demand" = {} }.
#
# Usage:
#   terraform apply
#       -> dynamic-spot-on-demand only (default)
#   terraform apply -var 'nodepools={"reserved-capacity-spot-overflow"={reservation={}}}'
#       -> reserved gpu-inf pool (reserved-first, spot/on-demand overflow). reservation={} makes Terraform
#          create a tagged ODCR with defaults (g6e.4xlarge, 1 instance, first cluster AZ); the NodeClass
#          selects it by tag (nodepool=reserved-capacity-spot-overflow).
#   terraform apply -var 'nodepools={"reserved-capacity-spot-overflow"={reservation={instance_type="g6e.4xlarge",instance_count=2,az="us-east-2a"}}}'
#       -> override the ODCR instance type / count / az
#
# Notes:
#   - dynamic-spot-on-demand and reserved-capacity-spot-overflow both manage the gpu-inf pool and
#     cannot be enabled together (enforced by a validation on var.nodepools).
#   - Each strategy with a `reservation` gets its own ODCR tagged nodepool=<key>. Add another keyed
#     entry for a second pool plus its own reservation.

locals {
  nodepools_dir = "${path.module}/nodepools"

  # Flatten every enabled strategy folder to { filename => path }. Keying by filename (not folder)
  # keeps each pool's address stable, so changing a pool's strategy is an in-place update.
  manifests = merge([
    for strategy in keys(var.nodepools) : {
      for file in fileset("${local.nodepools_dir}/${strategy}", "*.yml") :
      file => "${local.nodepools_dir}/${strategy}/${file}"
    }
  ]...)

  nodeclass_files = { for f, p in local.manifests : f => p if startswith(f, "nodeclass-") }
  nodepool_files  = { for f, p in local.manifests : f => p if startswith(f, "nodepool-") }
}

# One ODCR per strategy that sets `reservation`, tagged nodepool=<key> so the matching NodeClass can
# select it by tag. Bills immediately until destroyed.
resource "aws_ec2_capacity_reservation" "gpu" {
  for_each = { for strategy, cfg in var.nodepools : strategy => cfg.reservation if cfg.reservation != null }

  instance_type           = each.value.instance_type
  instance_platform       = "Linux/UNIX"
  availability_zone       = coalesce(each.value.az, local.azs[0])
  instance_count          = each.value.instance_count
  instance_match_criteria = "open"
  end_date_type           = "unlimited"

  tags = {
    Name     = "${local.name}-${each.key}"
    nodepool = each.key
  }
}

# Dynamic Auto Mode pools reference the managed `default` NodeClass (no nodeclass file), so this is
# empty unless a strategy ships its own custom NodeClass (e.g. reserved-capacity-spot-overflow).
resource "kubectl_manifest" "nodeclasses" {
  for_each = local.nodeclass_files

  yaml_body = templatefile(each.value, {
    cluster_name       = local.name
    node_iam_role_name = module.eks.node_iam_role_name
  })

  depends_on = [module.eks, aws_ec2_capacity_reservation.gpu]
}

resource "kubectl_manifest" "nodepools" {
  for_each = local.nodepool_files

  yaml_body = templatefile(each.value, {})

  depends_on = [kubectl_manifest.nodeclasses, module.eks]
}
