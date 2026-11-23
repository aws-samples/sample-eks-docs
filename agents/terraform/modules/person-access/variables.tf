variable "name" {
  description = "Prefix for every resource this module creates; the cluster name."
  type        = string
}

variable "region" {
  description = "Region of the Cognito user pool."
  type        = string
}

variable "account_id" {
  description = "Account id, for a globally unique bucket name."
  type        = string
}

variable "agents" {
  description = <<-EOT
    The agents that may act with a person's authority, by Agent name. Each gets its own role,
    <name>-<agent>-person-data, scoped to people/<sub>/<agent>/. An agent not listed has no person
    role, so it cannot exchange a person's token for anything.
  EOT
  type        = list(string)

  validation {
    condition     = alltrue([for a in var.agents : can(regex("^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$", a))])
    error_message = "Each agent must be an Agent name of at most 32 characters: lowercase letters, digits and hyphens, starting and ending with a letter or digit (it is in the role name and the session name)."
  }
}

variable "user_pool_id" {
  description = "The Cognito user pool people sign in to (the ingress module's pool)."
  type        = string
}

variable "callback_urls" {
  description = <<-EOT
    Redirect URIs for an application that signs people in with the authorization code flow through
    the pool's hosted UI. Empty: the api client has no OAuth flow, only the SRP and (test) password
    flows.
  EOT
  type        = list(string)
  default     = []
}

variable "allow_password_auth" {
  description = <<-EOT
    Allow USER_PASSWORD_AUTH on the api client, a public client with no secret. scripts/exercise.sh
    uses it to sign its test users in; a real application uses the hosted UI's authorization code
    flow. Turn it off outside a test. The roots expose it as person_access_password_auth.
  EOT
  type        = bool
  default     = true
}

variable "token_validity_minutes" {
  description = "Lifetime of the api client's ID and access tokens. An agent can use a token it was handed until it expires."
  type        = number
  default     = 15

  validation {
    condition     = var.token_validity_minutes >= 5 && var.token_validity_minutes <= 60
    error_message = "token_validity_minutes must be 5-60."
  }
}

variable "existing_oidc_provider_arn" {
  description = "An IAM OIDC provider already registered for this pool's issuer. IAM refuses a second provider for the same URL."
  type        = string
  default     = ""
}

variable "role_path" {
  description = "IAM path for the person role."
  type        = string
  default     = "/eks-agents/"
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for the person role, when the account requires one."
  type        = string
  default     = ""
}

variable "force_destroy" {
  description = "Let terraform destroy delete a bucket that still holds people's objects."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}

variable "gateway_role_arn" {
  description = <<-EOT
    The egress gateway's IAM role. Set, each agent's person role also trusts that role alone to
    assume it with session tags person (the person's verified sub) and agent (this agent), and its
    permissions read the person from the tag, so AgentGateway can sign S3 calls with the person's
    authority for that agent. Empty: only the agent's own web-identity exchange.
  EOT
  type        = string
  default     = ""
}

variable "gateway_services" {
  description = <<-EOT
    AWS services besides S3 that an agent reaches through the gateway with a person's authority
    (gateway_role_arn set), keyed by the service's SigV4 signing name. Each entry's statements join
    every agent's person role, with {agent} in a resource or condition value replaced by the agent's
    name. Write them so the person scopes the access: a resource or condition keyed on
    $${aws:PrincipalTag/person}, which only the gateway's tagged session carries -- for example a
    DynamoDB statement with dynamodb:LeadingKeys = $${aws:PrincipalTag/person}.
  EOT
  type = map(object({
    statements = list(object({
      actions   = list(string)
      resources = list(string)
      conditions = optional(list(object({
        test     = string
        variable = string
        values   = list(string)
      })), [])
    }))
  }))
  default = {}

  validation {
    condition     = !contains(keys(var.gateway_services), "s3")
    error_message = "s3 is built in (the person-data bucket); gateway_services is for the other services."
  }
}
