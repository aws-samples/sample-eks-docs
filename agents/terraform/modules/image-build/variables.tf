variable "name" {
  description = "Name prefix, normally the cluster name."
  type        = string
}

variable "ecr_repository_arns" {
  description = "The stack's agent image repositories. The build role can push to these and no others."
  type        = list(string)
}

variable "architecture" {
  description = "`x86_64` or `arm64`: the CPU the builds run on, which is the architecture of the images. Match the node pools the agents run on."
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be x86_64 or arm64."
  }
}

variable "compute_type" {
  description = "The CodeBuild compute type. BUILD_GENERAL1_MEDIUM (4 vCPU, 7 GB) builds the reference images in a few minutes."
  type        = string
  default     = "BUILD_GENERAL1_MEDIUM"
}

variable "log_retention_days" {
  description = "How long the build logs are kept."
  type        = number
  default     = 14
}

variable "kms_key_arn" {
  description = "A customer managed KMS key for the build logs. Null uses CloudWatch Logs' own encryption."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
