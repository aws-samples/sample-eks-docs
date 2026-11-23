variable "name" {
  description = "Name prefix, normally the cluster name."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster the gateway runs on."
  type        = string
}

variable "cluster_arn" {
  description = "ARN of that cluster, for the Pod Identity condition on the gateway's trust policy."
  type        = string
}

variable "gateway_namespace" {
  description = "Namespace AgentGateway runs in. Not a tenant namespace: the gateway holds every agent's credentials for every destination, so nobody with RBAC in an agent namespace should have RBAC here."
  type        = string
  default     = "agentgateway-system"
}

variable "gateway_service_account" {
  description = <<-EOT
    Service account the gateway's DATA PLANE runs as, which is the Gateway object's name.

    This is not a name you choose. AgentGateway's controller creates one Deployment, Service and
    ServiceAccount per Gateway object, each taking the Gateway's name -- so this has to equal
    gateway.name in gitops/charts/agentgateway-config, which is "egress" by default.

    Getting it wrong delivers credentials to a service account nothing uses, and the gateway then
    has no AWS identity at all. The symptom is HTTP 502 "backend authentication failed" on every
    model call, because the gateway cannot call sts:AssumeRole to become the calling agent.
    The usual mistake is "agentgateway", the controller's own name, which leaves no association
    for the data plane.
  EOT
  type        = string
  default     = "egress"
}

variable "agent_role_path_arn" {
  description = <<-EOT
    A role-PATH ARN the gateway may assume, for agents that are composed in the cluster rather than
    declared in Terraform.

    Required on that path and unused on the other. When agents arrive as `Agent` resources there is
    no list of role ARNs at apply time -- kro creates each role when a team commits an agent -- so
    an enumerated grant cannot exist. Without this the gateway has no sts:AssumeRole statement at
    all and every model call returns 403 from Bedrock, with the gateway's own access log showing the
    request reaching the right route and backend.

    This is genuinely broader than the enumerated form and the bound is the path: every role under
    it is created by the agent resource definition with the agent permissions boundary attached, so
    what the gateway can do as any of them is still bounded by that boundary. Pass the path ARN,
    e.g. arn:aws:iam::123456789012:role/eks-agents/*, and keep the path narrow.
  EOT
  type        = string
  default     = ""
}

variable "agent_role_arns" {
  description = <<-EOT
    The per-agent IAM roles the gateway may assume. Pass the role_arn output of each
    ../agent-identity instance.

    This list is the gateway's entire AWS authority. Adding an agent to it is the deployment
    contract: an agent whose role is not here reaches the gateway and gets no AWS credential from
    it, which fails closed.
  EOT
  type        = list(string)
  default     = []
}

variable "third_party_credentials" {
  description = <<-EOT
    The destinations whose credentials the gateway holds so the agent does not, keyed by a short
    name used in the secret path.

    One entry per destination. The gateway selects the credential by the request's host, so a
    destination carries one credential, used on behalf of one caller agent. It does NOT hold a
    credential per end user: that needs a token store keyed on the user, which the open source
    gateway does not have.

    This module creates the secret and the access path. It never sets the value: a secret value
    passed through Terraform is a secret in a state file, and where the service requires the
    person's own consent the value only exists after somebody approves it in a browser.
  EOT
  type = map(object({
    destination = string
    caller      = string
  }))
  default = {}
}

variable "credential_kms_key_arn" {
  description = "Customer-managed KMS key for the brokered credentials. Null uses the Secrets Manager AWS managed key. A customer-managed key is what lets a key policy, not only an IAM policy, decide who can read these."
  type        = string
  default     = null
}

variable "credential_admin_principal_arns" {
  description = "Principals besides the gateway permitted to read the brokered credentials, for the humans or the pipeline that set the values. Keep it short: every principal here is another way a long-lived third-party token leaves the account."
  type        = list(string)
  default     = []
}

variable "secret_recovery_window_days" {
  description = "Secrets Manager recovery window. Zero deletes immediately, which loses the ability to recover a credential somebody deleted by mistake."
  type        = number
  default     = 7
}

variable "enable_mesh_private_ca" {
  description = "Create an AWS Private CA for the mesh. Off by default: this stack takes the mesh's own CA. A Private CA bills per month and per certificate, and on this stack it signs one every time an agent presents mTLS."
  type        = bool
  default     = false
}

variable "mesh_trust_domain" {
  description = "Common name for the mesh CA, normally the SPIFFE trust domain. It is per-cluster and not a domain the customer owns, so an identity issued under it cannot be presented outside the cluster."
  type        = string
  default     = "cluster.local"
}

variable "mesh_ca_organization" {
  description = "Organization name on the mesh CA subject."
  type        = string
  default     = "eks-agents-paved-paths"
}

variable "private_ca_deletion_window_days" {
  description = "Permanent deletion window for the Private CA, 7 to 30 days."
  type        = number
  default     = 30

  validation {
    condition     = var.private_ca_deletion_window_days >= 7 && var.private_ca_deletion_window_days <= 30
    error_message = "private_ca_deletion_window_days must be between 7 and 30."
  }
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "enable_bedrock_marketplace_subscribe" {
  description = <<-EOT
    Let the gateway's role accept the one-time AWS Marketplace subscription an Anthropic model on
    Amazon Bedrock needs on first invoke.

    It grants aws-marketplace:Subscribe and aws-marketplace:ViewSubscriptions on "*", account-wide,
    because Marketplace actions take no resource. It is on because Anthropic models are Marketplace
    models and their caller, here the gateway that signs the model call, has to subscribe: on an
    account that has not, the first Claude call fails with "not authorized to perform the required
    AWS Marketplace actions" while Amazon-owned models keep working.

    false is the tighter setting, for an account where subscriptions are managed centrally and have
    already been accepted. The model ARNs an agent may invoke stay scoped by its own role either
    way, and unsubscribe is never granted.
  EOT
  type        = bool
  default     = true
}

variable "judge" {
  description = <<-EOT
    The evaluation judge's identity at the gateway, when evaluation is enabled. Null creates nothing.

      model_arns                The models the judge may invoke: an inference profile ARN AND the
                                foundation-model ARNs it routes to, as for an agent -- a profile
                                alone is refused on the underlying model.
      role_path                 The agent role path, so the gateway's path-scoped grant covers it.
      permissions_boundary_arn  The agents' permissions boundary.
  EOT
  type = object({
    model_arns               = list(string)
    role_path                = string
    permissions_boundary_arn = string
  })
  default = null

  validation {
    condition     = var.judge == null || length(try(var.judge.model_arns, [])) > 0
    error_message = "judge.model_arns is empty. The judge's policy renders it into a Resource list, and an empty one is a role that can call no model -- every grade would fail with AccessDenied."
  }
}

variable "guardrail_arn" {
  description = "The Amazon Bedrock guardrail the gateway applies to every model request and response (promptGuard), or empty for none. Grants the gateway's role bedrock:ApplyGuardrail on it."
  type        = string
  default     = ""
}
