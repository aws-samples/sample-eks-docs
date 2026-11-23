variable "name" {
  description = "The stack's name: the prefix of the clients, providers and workload identities."
  type        = string
}

variable "user_pool_id" {
  description = "The Cognito user pool people sign in to (the ingress module's pool). Its domain must serve managed login (the ingress module's managed_login): Cognito refuses a token exchange on a domain that serves the classic UI."
  type        = string
}

variable "issuer" {
  description = "The user pool's issuer URL, https://cognito-idp.<region>.amazonaws.com/<pool id>. AgentCore discovers the token endpoint from it."
  type        = string
}

variable "tool_audience" {
  description = "The audience every delegated token names, and the identifier of the resource server registered for it. A tool refuses a token for any other audience."
  type        = string
}

variable "agents" {
  description = "The agents that may act for a person (person_access_agents), as name or namespace/name. Each gets its own Cognito client, credential provider and workload identity, so the delegated token's actor is that agent and no other."
  type        = list(string)
}

variable "token_validity_minutes" {
  description = "How long a delegated token is valid. The tool accepts it until it expires, so keep it short."
  type        = number
  default     = 15
}

variable "tags" {
  description = "Tags for the resources that take them."
  type        = map(string)
  default     = {}
}
