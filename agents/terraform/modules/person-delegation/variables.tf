variable "name" {
  description = "Prefix for every resource this module creates; the cluster name."
  type        = string
}

variable "user_pool_id" {
  description = "The Cognito user pool people sign in to (the ingress module's pool). Its domain must serve managed login: the ingress module's managed_login."
  type        = string
}

variable "actor_issuer" {
  description = "The cluster's OIDC issuer URL: who signs the actor token, the agent's projected service account token."
  type        = string

  validation {
    condition     = startswith(var.actor_issuer, "https://")
    error_message = "actor_issuer must be the cluster's OIDC issuer URL."
  }
}

variable "actor_audience" {
  description = "The audience the actor token names: the gateway's, so the token the agent already presents to the gateway is the actor."
  type        = string
  default     = "agentgateway"
}

variable "tool_audience" {
  description = "The resource server identifier, and the delegated token's audience: what a tool checks the token is for."
  type        = string
  default     = "mcp-server"
}

variable "exchanger_callback_url" {
  description = "A redirect URI for the exchanger client, which Cognito requires before a client may hold OAuth scopes. Never used: the client signs nobody in."
  type        = string
  default     = "https://localhost/unused"
}

variable "token_validity_minutes" {
  description = "Lifetime of a delegated token. A tool accepts one until it expires."
  type        = number
  default     = 15

  validation {
    condition     = var.token_validity_minutes >= 5 && var.token_validity_minutes <= 60
    error_message = "token_validity_minutes must be 5-60."
  }
}

variable "secret_reader_arns" {
  description = "Principals that may read the exchanger's secret: the reader that projects it into the gateway's namespace, and administrators."
  type        = list(string)

  validation {
    condition     = length(var.secret_reader_arns) > 0
    error_message = "secret_reader_arns must name the reader that projects the secret into the gateway's namespace."
  }
}

variable "secret_recovery_window_days" {
  description = "Recovery window for the exchanger's Secrets Manager secret."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags for every resource that takes them."
  type        = map(string)
  default     = {}
}
