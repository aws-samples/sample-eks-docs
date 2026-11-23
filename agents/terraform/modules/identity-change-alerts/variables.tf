variable "name" {
  description = "The stack's name; every resource here is named for it."
  type        = string
}

variable "region" {
  description = "The cluster's region, where the topic and the regional rule are."
  type        = string
}

variable "account_id" {
  description = "This account, for the key and topic policies."
  type        = string
}

variable "role_names" {
  description = "The IAM roles whose trust and permissions decide who acts for a person: the gateway's role and each agent's person role."
  type        = list(string)
}

variable "user_pool_id" {
  description = "The user pool that issues the person's tokens. Changes to its clients, identity providers and resource servers are reported."
  type        = string
}

variable "cluster_name" {
  description = "The EKS cluster. A Pod Identity association created, changed or deleted on it is reported: one could hand the gateway's role to another service account."
  type        = string
}

variable "emails" {
  description = "Addresses subscribed to the topic. Each receives a confirmation email from SNS first. Empty: subscribe what you use yourself."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
