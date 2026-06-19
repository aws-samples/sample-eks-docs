variable "region" {
  description = "AWS region the deployment lands in."
  type        = string
  nullable    = false
  default     = "us-east-2"
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as the prefix for related resource names and the value of the PartOf tag."
  type        = string
  default     = "ai-eks-docs"
}

variable "kubernetes_version" {
  description = "Kubernetes minor version for the EKS control plane."
  type        = string
  default     = "1.35"
}

variable "karpenter_version" {
  description = "Karpenter chart version (CRD + controller releases)."
  type        = string
  default     = "1.12.0"
}

variable "enable_karpenter_node_repair" {
  description = "Enable Karpenter's nodeRepair feature gate (alpha as of chart 1.12.0). Replaces unhealthy Karpenter-launched nodes based on eks-node-monitoring-agent signals."
  type        = bool
  default     = true
}

variable "nvidia_device_plugin_version" {
  description = "NVIDIA k8s-device-plugin chart version."
  type        = string
  default     = "0.19.1"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach any publicly accessible endpoint this stack creates (EKS API, ALB)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_amazon_prometheus" {
  description = "Provision an Amazon Managed Prometheus workspace and IAM for the scraper."
  type        = bool
  default     = true
}

variable "kube_prometheus_stack_version" {
  description = "kube-prometheus-stack chart version."
  type        = string
  default     = "85.0.1"
}

variable "enable_dcgm_exporter" {
  description = "Install the NVIDIA DCGM exporter on GPU nodes for Prometheus scraping."
  type        = bool
  default     = true
}

variable "dcgm_exporter_version" {
  description = "NVIDIA dcgm-exporter chart version."
  type        = string
  default     = "4.8.2"
}

variable "nodepools" {
  description = <<-EOT
    GPU NodePool strategies to enable. Each value maps to a folder under nodepools/.
    Multiple may be enabled as long as their manifest filenames (and thus NodePool/NodeClass names) don't collide.
    dynamic-spot-on-demand and reserved-capacity-spot-overflow both manage the gpu-inf pool, so they are mutually exclusive.
    To add a strategy: create nodepools/<name>/ with uniquely-named manifests and add <name> to the validation list below.
  EOT
  type    = set(string)
  default = ["dynamic-spot-on-demand"]

  validation {
    condition = alltrue([
      for p in var.nodepools : contains([
        "dynamic-spot-on-demand",
        "reserved-capacity-spot-overflow",
      ], p)
    ])
    error_message = "Each entry must be an existing strategy folder under nodepools/."
  }

  validation {
    condition     = !(contains(var.nodepools, "dynamic-spot-on-demand") && contains(var.nodepools, "reserved-capacity-spot-overflow"))
    error_message = "dynamic-spot-on-demand and reserved-capacity-spot-overflow cannot be enabled together; both manage the gpu-inf NodePool."
  }
}

variable "reserved_capacity" {
  description = <<-EOT
    ODCR parameters, used when reserved-capacity-spot-overflow is enabled. Terraform creates the
    reservation and wires its id into the NodeClass. Note: an ODCR bills immediately until destroyed.
  EOT
  type = object({
    instance_type  = optional(string, "g6e.4xlarge")
    instance_count = optional(number, 1)
    az             = optional(string, "") # defaults to the first cluster AZ
  })
  default = {}
}
