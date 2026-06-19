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
    GPU NodePool strategies to enable, keyed by folder name under nodepools/. Defaults to
    { "dynamic-spot-on-demand" = {} }. Set `reservation` on a strategy to have Terraform create a
    tagged On-Demand Capacity Reservation (ODCR) for it; the NodeClass selects it by the
    nodepool=<key> tag. An ODCR bills immediately until destroyed.

    dynamic-spot-on-demand and reserved-capacity-spot-overflow both manage the gpu-inf pool and are
    mutually exclusive. To add a strategy: create nodepools/<name>/ and add <name> to the validation list.
  EOT
  type = map(object({
    reservation = optional(object({
      instance_type  = optional(string, "g6e.4xlarge")
      instance_count = optional(number, 1)
      az             = optional(string, "") # defaults to the first cluster AZ
    }))
  }))
  default = { "dynamic-spot-on-demand" = {} }

  validation {
    condition = alltrue([
      for k in keys(var.nodepools) : contains([
        "dynamic-spot-on-demand",
        "reserved-capacity-spot-overflow",
      ], k)
    ])
    error_message = "Each key must be an existing strategy folder under nodepools/."
  }

  validation {
    condition     = !(contains(keys(var.nodepools), "dynamic-spot-on-demand") && contains(keys(var.nodepools), "reserved-capacity-spot-overflow"))
    error_message = "dynamic-spot-on-demand and reserved-capacity-spot-overflow cannot be enabled together; both manage the gpu-inf NodePool."
  }
}
