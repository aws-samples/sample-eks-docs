variable "enable_fsx" {
  description = "Create the FSx for Lustre file system, CSI driver, and static PV/PVC."
  type        = bool
  default     = false
}

variable "storage_capacity" {
  description = "FSx for Lustre storage capacity in GiB (multiple of 2400 for PERSISTENT_2 SSD)."
  type        = number
  default     = 76800

  validation {
    condition     = var.storage_capacity % 2400 == 0 && var.storage_capacity >= 2400
    error_message = "storage_capacity must be a multiple of 2400 GiB for PERSISTENT_2 SSD."
  }
}

variable "per_unit_storage_throughput" {
  description = "Per-unit storage throughput in MB/s/TiB for PERSISTENT_2 (125, 250, 500, or 1000)."
  type        = number
  default     = 1000

  validation {
    condition     = contains([125, 250, 500, 1000], var.per_unit_storage_throughput)
    error_message = "per_unit_storage_throughput must be one of 125, 250, 500, or 1000."
  }
}

variable "subnet_id" {
  description = <<-EOT
    Subnet for the FSx for Lustre file system. Lustre uses a single subnet, which
    MUST be in the same AZ as the p6-b200 capacity block for EFA to work. Required
    when enable_fsx = true.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_fsx || var.subnet_id != ""
    error_message = "subnet_id must be set when enable_fsx is true."
  }
}

# -----------------------------------------------------------------------------
# File system
# -----------------------------------------------------------------------------

resource "aws_fsx_lustre_file_system" "this" {
  count = var.enable_fsx ? 1 : 0

  file_system_type_version = "2.15"
  storage_type             = "SSD"
  storage_capacity         = var.storage_capacity
  subnet_ids               = [var.subnet_id] # Lustre supports a single subnet
  security_group_ids       = [aws_security_group.shared.id]

  deployment_type             = "PERSISTENT_2"
  per_unit_storage_throughput = var.per_unit_storage_throughput
  efa_enabled                 = true
  data_compression_type       = "NONE"

  metadata_configuration {
    mode = "AUTOMATIC"
  }

  # PartOf + ManagedBy come from the provider default_tags.
  tags = {
    Name = "${local.name}-fsx-lustre"
  }
}

# -----------------------------------------------------------------------------
# FSx CSI driver (EKS add-on, Pod Identity)
# -----------------------------------------------------------------------------

resource "aws_iam_role" "fsx_csi" {
  count = var.enable_fsx ? 1 : 0

  name               = "${local.name}-fsx-csi-controller"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "fsx_csi" {
  count = var.enable_fsx ? 1 : 0

  role       = aws_iam_role.fsx_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonFSxFullAccess"
}

resource "aws_eks_addon" "fsx_csi" {
  count = var.enable_fsx ? 1 : 0

  cluster_name = module.eks.cluster_name
  addon_name   = "aws-fsx-csi-driver"

  pod_identity_association {
    role_arn        = aws_iam_role.fsx_csi[0].arn
    service_account = "fsx-csi-controller-sa"
  }

  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# Static PersistentVolume + PersistentVolumeClaim
# -----------------------------------------------------------------------------

resource "kubernetes_persistent_volume_v1" "fsx_lustre" {
  count = var.enable_fsx ? 1 : 0

  metadata {
    name = "fsx-lustre-pv"
  }

  spec {
    capacity = {
      storage = "${var.storage_capacity}Gi"
    }

    volume_mode                      = "Filesystem"
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    mount_options                    = ["flock"]

    persistent_volume_source {
      csi {
        driver        = "fsx.csi.aws.com"
        volume_handle = aws_fsx_lustre_file_system.this[0].id

        volume_attributes = {
          dnsname   = aws_fsx_lustre_file_system.this[0].dns_name
          mountname = aws_fsx_lustre_file_system.this[0].mount_name
        }
      }
    }
  }

  depends_on = [aws_eks_addon.fsx_csi]
}

resource "kubernetes_persistent_volume_claim_v1" "fsx_lustre" {
  count = var.enable_fsx ? 1 : 0

  metadata {
    name      = "fsx-lustre-claim"
    namespace = "default"
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = ""
    volume_name        = kubernetes_persistent_volume_v1.fsx_lustre[0].metadata[0].name

    resources {
      requests = {
        storage = "${var.storage_capacity}Gi"
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Outputs (null when enable_fsx = false)
# -----------------------------------------------------------------------------

output "fsx_file_system_id" {
  description = "FSx for Lustre file system ID."
  value       = one(aws_fsx_lustre_file_system.this[*].id)
}

output "fsx_file_system_dns_name" {
  description = "FSx for Lustre DNS name."
  value       = one(aws_fsx_lustre_file_system.this[*].dns_name)
}
