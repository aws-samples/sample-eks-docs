variable "name" {
  description = "The cluster name; every queue and role is prefixed with it."
  type        = string
}

variable "cluster_name" {
  description = "The EKS cluster, for KEDA's Pod Identity association."
  type        = string
}

variable "agents" {
  description = "Agents (by name, in the first agent namespace) that run as tasks and get queues."
  type        = list(string)

  validation {
    condition     = alltrue([for a in var.agents : can(regex("^[a-z0-9][a-z0-9-]{0,40}$", a))])
    error_message = "task agent names must be 1-41 characters of lowercase letters, digits and -, as Agent names are."
  }
}

variable "visibility_timeout_seconds" {
  description = "How long a taken task stays invisible to other pods before the worker extends it. The worker extends it every third of this while the task runs."
  type        = number
  default     = 300
}

variable "message_retention_seconds" {
  description = "How long an untaken task or an unread result is kept."
  type        = number
  default     = 345600 # 4 days
}

variable "max_receive_count" {
  description = "Attempts before a task moves to the dead-letter queue."
  type        = number
  default     = 3
}

variable "keda_namespace" {
  description = "Where KEDA runs (gitops/platform/<path>/templates/13-keda.yaml)."
  type        = string
  default     = "keda"
}

variable "keda_service_account" {
  description = "KEDA operator's service account."
  type        = string
  default     = "keda-operator"
}

variable "role_path" {
  description = "IAM path for KEDA's role."
  type        = string
  default     = "/eks-agents/"
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
