variable "cluster_name" {
  description = "EKS cluster the agent runs on."
  type        = string
}

variable "cluster_arn" {
  description = "ARN of that cluster. Written into the role's trust policy condition so the role cannot be assumed on behalf of a service account of the same name on a different cluster."
  type        = string
}

variable "agent_name" {
  description = "The agent. Used for the role name and as the default service account name, so one agent has one name in both Kubernetes and AWS. Keeping those two names in step is a convention the platform team maintains and nothing enforces."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$", var.agent_name))
    error_message = "agent_name must be a DNS label, because it is also a Kubernetes service account name."
  }
}

variable "namespace" {
  description = "Namespace the agent runs in."
  type        = string
}

variable "service_account" {
  description = "Service account the agent runs as. Defaults to var.agent_name. One agent, one service account: the association covers a namespace and a service account, so two agents sharing a service account are one identity to AWS whatever else differs about them."
  type        = string
  default     = null
}

variable "role_path" {
  description = "IAM path to create the role under. Match the agent_role_path output of ../agent-cluster, or the ACK capability role's own permissions will not cover roles created here."
  type        = string
  default     = "/eks-agents/"
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary for this role. Pass the agent_permissions_boundary_arn output of ../agent-cluster. Null creates the role with no boundary, which means this agent's authority is capped only by its own policy."
  type        = string
  default     = null
}

variable "bedrock_model_arns" {
  description = <<-EOT
    Foundation model and inference profile ARNs this agent may invoke. This is where per-agent model
    scope comes from on this stack: the gateway assumes this role to sign the agent's model
    calls, so the model list an agent gets is the one in its own role rather than a gateway-wide
    allowance.

    Empty grants no model access at all, which is correct for an execution-tier agent: that tier
    has no network device, so it could not reach Bedrock even with the permission.
  EOT
  type        = list(string)
  default     = []
}

variable "bedrock_guardrail_arn" {
  description = "Guardrail this agent's model calls must carry. When set, every bedrock:InvokeModel and bedrock:Converse call from this role is denied unless it names this guardrail, so the guardrail is not something the agent's code can decide to skip."
  type        = string
  default     = null
}

variable "bedrock_guardrail_version" {
  description = "Guardrail version to require. A specific version, not DRAFT: requiring DRAFT means the agent's content controls change whenever someone edits the guardrail."
  type        = string
  default     = null

  # A guardrail ARN with no version is a configuration that looks like a control and is not one: the
  # condition it produces can never be satisfied, so every model call from this role is denied. Fail
  # the plan instead of shipping a role that looks governed and is broken.
  validation {
    condition     = var.bedrock_guardrail_arn == null || var.bedrock_guardrail_version != null
    error_message = "Set bedrock_guardrail_version alongside bedrock_guardrail_arn. A guardrail condition without a version matches nothing and denies every model call this role makes."
  }
}

variable "checkpoint_bucket_arn" {
  description = "Durable checkpoint bucket from ../durable-storage. Null grants no object storage."
  type        = string
  default     = null
}

variable "checkpoint_prefix" {
  description = "Prefix inside that bucket this agent may read and write. Defaults to agents/<agent_name>/. Scoping by prefix is what gives per-agent authority where several agents share one bucket."
  type        = string
  default     = null
}

variable "checkpoint_kms_key_arn" {
  description = "KMS key the checkpoint bucket is encrypted with, if it is customer-managed. Without it an agent with s3:GetObject still cannot read an encrypted object."
  type        = string
  default     = null
}

variable "extra_policy_json" {
  description = "Additional IAM policy JSON merged into the agent's permission policy, for a destination this module does not model. It is still capped by the permissions boundary, so widening an agent past the boundary takes a deliberate change to the boundary itself."
  type        = string
  default     = null
}

variable "assumable_by_role_arns" {
  description = <<-EOT
    Roles permitted to assume this agent's role, in addition to the EKS Pod Identity service.

    This is the egress gateway's own role: the gateway maps the agent's
    verified identity to this role and signs the agent's model calls as the agent. It is the one place
    per-agent AWS authority comes from on this stack. Leave it empty for an agent
    that calls AWS directly rather than through a gateway.
  EOT
  type        = list(string)
  default     = []
}

variable "gateway_identity_claim" {
  description = <<-EOT
    The SPIFFE identity the gateway presents when it assumes this role on the agent's behalf, passed
    as an external ID on the assume-role condition. It ties one gateway-assumed session to one
    agent identity, so a compromised gateway configuration cannot quietly assume agent A's role
    while serving agent B.

    Null omits the condition, which is weaker: any session from an assumable role can take this
    role. Set it whenever assumable_by_role_arns is non-empty.
  EOT
  type        = string
  default     = null
}

variable "session_policy_json" {
  description = <<-EOT
    A session policy on the Pod Identity association, for an agent whose authority has to narrow per
    request rather than per agent.

    Setting it turns the session tags off — the two are exclusive — so this policy has to carry
    every bit of scoping the tags would have carried. The module sets disable_session_tags for you
    when this is non-null and refuses the combination that would silently drop the conditions an
    IAM policy elsewhere still reads. Most agents leave this null.
  EOT
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the role and the association."
  type        = map(string)
  default     = {}
}

variable "bedrock_inference_profile_ids" {
  description = <<-EOT
    Cross-region inference profiles this agent may invoke, by id -- for example
    "us.anthropic.claude-sonnet-5-5".

    PREFER THIS OVER LISTING ARNs IN bedrock_model_arns. A us./eu./apac./global. prefixed model id
    is an inference profile, and Bedrock authorizes the call against the profile's ARN AND the
    foundation-model ARN in whichever region the profile routed the request to. So a policy naming
    only the home region fails intermittently, by region, with a message that names a region nobody
    configured: one denial names us-west-2, the next us-east-1.

    Listing the id here derives every ARN the call can touch, so there is nothing to keep in sync
    when a profile's region list changes.

    Most models now require a profile rather than offering one: every Anthropic model in us-west-2
    reports inferenceTypesSupported = ["INFERENCE_PROFILE"] and cannot be invoked in-region at all.
    Check before assuming a single-region policy is possible:

      aws bedrock get-foundation-model --model-identifier <model-id> \
        --query 'modelDetails.inferenceTypesSupported'
  EOT
  type        = list(string)
  default     = []
}
