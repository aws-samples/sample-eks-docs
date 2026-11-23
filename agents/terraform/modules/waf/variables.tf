variable "name" {
  description = "The web ACL's name, and the prefix of its metric names."
  type        = string
}

variable "description" {
  description = "What the web ACL protects. Letters, digits, spaces and + = : # @ / - , . only, which is what AWS WAF accepts."
  type        = string

  validation {
    condition     = can(regex("^[\\w+=:#@/\\-,.][\\w+=:#@/\\-,.\\s]+[\\w+=:#@/\\-,.]$", var.description))
    error_message = "AWS WAF accepts only letters, digits, spaces and + = : # @ / - , . in a web ACL description."
  }
}

variable "rate_limit_per_ip" {
  description = <<-EOT
    Requests per source IP address in any 5-minute window before the address is blocked, or null for
    no rate rule. Use null where every caller shares an address, such as a gateway whose callers all
    leave the VPC through one NAT gateway: a per-IP limit there limits everyone at once.
  EOT
  type        = number
  default     = null

  validation {
    condition     = var.rate_limit_per_ip == null || try(var.rate_limit_per_ip >= 10, false)
    error_message = "rate_limit_per_ip must be at least 10, the smallest limit AWS WAF accepts, or null."
  }
}

variable "body_rules_count_only" {
  description = <<-EOT
    The managed rules that match on the request BODY, set to count rather than block. An agent's
    request body is a prompt or a conversation, so it legitimately holds SQL, markup and text far
    over the common rule set's 8 KB body limit; blocking on those signatures refuses ordinary turns.
    The agent server enforces its own size limit. Headers, query strings and URIs stay blocked.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for the web ACL."
  type        = map(string)
  default     = {}
}
