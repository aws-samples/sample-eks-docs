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

variable "reserved_capacity" {
  description = <<-EOT
    On-Demand Capacity Reservation (ODCR) for reserved-first GPU capacity with spot/on-demand overflow.
    When enabled, Terraform creates the ODCR and switches the gpu-inf NodePool to the reserved set.
    Note: an ODCR bills immediately until destroyed (terraform destroy or enabled = false).
  EOT
  type = object({
    enabled        = optional(bool, false)
    instance_type  = optional(string, "g6e.4xlarge")
    instance_count = optional(number, 1)
    az             = optional(string, "") # defaults to the first cluster AZ
  })
  default = {}
}
