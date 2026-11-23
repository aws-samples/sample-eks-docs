variable "name" {
  description = "Name prefix for the cluster and every resource in this configuration."
  type        = string
  default     = "agents-aws"
}

variable "region" {
  description = "AWS Region."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS control plane version."
  type        = string
  default     = "1.36"
}

# NETWORK: created for you by default, yours if you have one.
#
# An agent platform belongs inside the network perimeter the organization already operates, so if
# you have a VPC, pass it and these two are all you need. Leave them unset and this configuration
# builds a VPC sized and tagged for the job -- see terraform/modules/network for what it makes and
# why. That module is for evaluation; for production, bring your own network with the variables below.
#
# Supply BOTH or NEITHER. Half an answer is rejected at plan time rather than producing a cluster
# with nodes in a network you did not intend.

variable "vpc_id" {
  description = "VPC the cluster runs in. Leave empty to have this configuration create one."
  type        = string
  default     = ""
}

variable "subnet_ids" {
  description = "Private subnets for the cluster, its nodes and the session state cache. Leave empty to have this configuration create them. These must be PRIVATE subnets: nothing in this stack is meant to be reachable from the internet."
  type        = list(string)
  default     = []

  validation {
    condition     = (var.vpc_id == "") == (length(var.subnet_ids) == 0)
    error_message = "Set both vpc_id and subnet_ids to use your own network, or neither to have one created. Setting only one would place the cluster in a network you did not fully specify."
  }
}

# The knobs for the created network. Ignored when you bring your own.

variable "vpc_cidr" {
  description = "CIDR for the created VPC. A /16 gives each subnet a /20, which the VPC CNI needs because it assigns real VPC addresses to pods. With vpc_id set, give the existing VPC's CIDR: the bastion's DNS egress and the VPC endpoints' HTTPS ingress are scoped to it."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Availability Zones for the created network, one private and one public subnet each. Three by default: Auto Mode node pools span every subnet they are given, and a zone that cannot fill a launch presents as \"no capacity\" rather than as a zonal failure, so more zones means more places to succeed. Ignored when vpc_id is set."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "One NAT gateway for the created VPC instead of one per zone. True by default because a NAT gateway bills hourly plus per gigabyte; it is a single point of failure, so set it false for anything you care about. Ignored when vpc_id is set."
  type        = bool
  default     = true
}

variable "enable_vpc_flow_logs" {
  description = "VPC Flow Logs for the created VPC, to a CloudWatch Logs group under /aws/vpc/<name>/flow-logs. False by default: flow logs bill per gigabyte, and an organization's own network usually collects them centrally. Set it true when nothing else records this VPC's traffic. Ignored when vpc_id is set."
  type        = bool
  default     = false
}

variable "vpc_flow_logs_retention_days" {
  description = "Days the flow log group keeps records. Used only when enable_vpc_flow_logs is true."
  type        = number
  default     = 90
}

variable "cluster_admin_principal_arns" {
  description = <<-EOT
    IAM principals granted cluster admin: the platform team's own roles, nothing else. Empty, the
    default, means the principal running Terraform -- the IAM role behind an assumed-role session,
    or the IAM user -- so a first apply hands back a cluster you can administer. Name the roles
    explicitly for anything shared, so the admin list is reviewable in Git.
  EOT
  type        = list(string)
  default     = []
}

variable "direct_model_id" {
  description = <<-EOT
    The Amazon Bedrock model agents call when there is no gateway: an inference profile id, because
    Claude models do not support on-demand calls against the bare foundation model id. Turn on access
    to the model in every Region the profile routes to; `terraform output agent_model_arns` lists the
    ARNs an Agent's `modelArns` must name for it.
  EOT
  type        = string
  default     = "us.anthropic.claude-sonnet-5-5"
}

variable "agent_namespaces" {
  description = "Namespaces agents run in."
  type        = list(string)
  default     = ["agents"]
}

variable "ecr_repository_names" {
  description = "ECR repositories for agent images. Unset (null), the list follows the components that are on, as on the open source path: the base gets agents/reasoning-direct, agents/execution, agents/reasoning and agents/mcp-server whether or not the gateway is on, and the chat UI, evaluations and the consent receiver add theirs."
  type        = list(string)
  default     = null
}

variable "gitops_repo_url" {
  description = <<-EOT
    The Git repository Argo CD reads the platform's charts from. The default is the public sample
    repository. The stack's own values never go to it, or to any repository: Terraform renders them
    locally and scripts/bootstrap-gitops.sh passes them to the cluster through the root Application.
    Point this at a repository of your own only to run templates you've changed. A CodeCommit
    repository (scripts/gitops-mirror.sh create) is read with no stored credential once it's in
    argocd_codecommit_repository_arns; any other private repository needs a credential registered
    with Argo CD.
  EOT
  type        = string
  default     = "https://github.com/aws-samples/sample-eks-docs.git"

  validation {
    condition     = !var.enable_argocd || trimspace(var.gitops_repo_url) != ""
    error_message = "enable_argocd needs gitops_repo_url: the repository Argo CD reads the platform's charts from. Leave it unset for the public sample repository. With enable_argocd = false, scripts/install-platform.sh installs gitops/ without a repository."
  }
}

variable "gitops_repo_revision" {
  description = <<-EOT
    The revision of gitops_repo_url every Application reads: a tag or a commit, so the cluster runs
    exactly the code it was tested with and a later change to the repository reaches it only when
    you move this. A branch name works but follows every commit to that branch.
  EOT
  type        = string
  default     = "main"

  validation {
    condition     = trimspace(var.gitops_repo_revision) != ""
    error_message = "gitops_repo_revision must name a tag, a commit or a branch of gitops_repo_url."
  }
}

variable "gitops_repo_path" {
  description = <<-EOT
    Where this directory sits in gitops_repo_url, with a trailing slash: "agents/" in the public
    sample repository, "" in a repository that holds only this directory (what
    scripts/gitops-mirror.sh push makes).
  EOT
  type        = string
  default     = "agents/"

  validation {
    condition     = var.gitops_repo_path == "" || endswith(var.gitops_repo_path, "/")
    error_message = "gitops_repo_path is empty or ends with a slash, such as \"agents/\"."
  }
}

variable "argocd_extra_source_repos" {
  description = <<-EOT
    Repositories, beyond gitops_repo_url and the chart repositories the platform's own Applications
    read, that Applications in the eks-agents AppProject may sync from: a team's own repository of
    Agent manifests, for example, when it is not gitops_repo_url (application setup, Step 6). Each is
    a repository URL as an Application's repoURL spells it, or an Argo CD glob such as
    "https://github.com/example-org/*". Terraform appends them to the project's sourceRepos in
    gitops/bootstrap/<path>/appproject.local.yaml; the project refuses any other repository.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.argocd_extra_source_repos : trimspace(r) != "" && trimspace(r) != "*"])
    error_message = "argocd_extra_source_repos entries are repository URLs or globs: not empty, and not \"*\", which would let the project sync from any repository."
  }
}

variable "checkpoint_bucket_name" {
  description = "Checkpoint bucket name. Null derives it from the cluster name and the account ID."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key used across the platform: checkpoints, session state, memory, the gateway, the policy engine, the evaluators and the log groups. Null uses each service's default key."
  type        = string
  default     = null
}

variable "organization_id" {
  description = "AWS Organizations ID for the checkpoint bucket's data perimeter."
  type        = string
  default     = null
}

variable "agents" {
  description = <<-EOT
    The agents this configuration creates an identity for, keyed by agent name.

    LEAVE THIS EMPTY unless you specifically want Terraform to own an agent's IAM. Empty is what
    enables the `Agent` resource definition, so agents are declared in the cluster and kro composes
    each one's role, Pod Identity association and Deployment -- which is the reason the ACK and kro
    capabilities are installed. An agent added here is an agent whose every change is a platform
    team `terraform apply`.

    It remains available because one case justifies it: an agent whose permissions are unusual
    enough that the platform team wants them reviewed in Terraform rather than composed from an
    in-cluster resource. Subjects of agents named here are folded into the gateway's allowlist
    automatically, so they do not also need listing in allowed_agent_subjects.
  EOT
  type = map(object({
    namespace                     = string
    service_account               = optional(string)
    bedrock_model_arns            = optional(list(string), [])
    bedrock_inference_profile_ids = optional(list(string), [])
    bedrock_guardrail_arn         = optional(string)
    bedrock_guardrail_version     = optional(string)
    needs_checkpoints             = optional(bool, true)
    session_policy_json           = optional(string)
    extra_policy_json             = optional(string)
  }))

  # No "at least one" validation. Leaving this empty is the normal case: it is what turns the
  # `Agent` resource definition on, so agents are declared in the cluster and composed by kro
  # instead of being created here. The gateway's allowlist comes from allowed_agent_subjects.
  default = {}
}

# --- Gateway -----------------------------------------------------------------

variable "enable_gateway" {
  description = <<-EOT
    Create the egress gateway, Amazon Bedrock AgentCore Gateway, and point the network policy at it.
    The same switch as the open source path's, where it deploys AgentGateway in the cluster.

    Off means no gateway, no gateway IAM role, credential providers, policy engine or targets are
    created, and the network policy permits `bedrock-runtime` in this region instead of the
    gateway's host name -- so agents call Amazon Bedrock directly with their own Pod Identity
    credential. The boundary still holds; what you give up is the tool catalogue and credential
    brokering, the policy engine, and the one point every model and tool call passes through.

    THE DEFAULT AGENT IMAGE DOES NOT START WITH THIS OFF. agents/reasoning reaches a model only
    through the gateway. Deploy agents/reasoning-direct instead, which calls Bedrock on the agent's
    own role -- an option, not the sample's default (the agents-application-setup page of the EKS User
    Guide, the model route).

    The gateway's own variables (gateway_*, the providers, the targets, the policy engine) are
    ignored while this is off.
  EOT
  type        = bool
  default     = false
}


variable "gateway_audiences" {
  description = <<-EOT
    Audiences the gateway accepts on an inbound token. Name the gateway, so a token minted for
    another relying party is not accepted here.

    The default matches gateway.audience in gitops/base/values.yaml, which is the audience the
    agent's projected token is minted for. Change one and you have to change the other: the two
    sides agreeing is what makes a model call work, and a mismatch fails closed with no
    object-level error on either side.

    An empty list turns the audience check off. A workload can request its identity as a JWT naming
    any audience with no allowlist at fetch time, so with no check here a token the agent obtained
    for some unrelated service is accepted as a gateway credential.
  EOT
  type        = list(string)
  default     = ["agentgateway"]

  validation {
    condition     = length(var.gateway_audiences) > 0
    error_message = "Name at least one audience. An empty list accepts a token minted for any relying party, which is the separation this check exists to provide."
  }
}

variable "gateway_inference_model_arns" {
  description = <<-EOT
    Models the gateway itself may invoke through the `bedrock:` actions, which on this path is
    semantic tool search. Guardrail checks are separate: gateway_guardrails attaches them as
    AgentCore Policy statements, and they need bedrock:InvokeGuardrailChecks, not these models.

    IT DOES NOT BOUND WHICH MODELS AN AGENT CAN REACH, and on this path nothing in an agent's own
    role does either -- the gateway signs the model call, not the agent. A call to the inference
    target is authorized by `bedrock-mantle:CreateInference` on `project/default`, which names no
    model, so it is all of the connector's catalogue or none of it. With `bedrock:InvokeModel`
    scoped to one foundation model, other models still serve completions to a caller holding only
    a projected token.

    What bounds an agent's model access here: a gateway rule's `routeToTarget.staticRoute.model`,
    which replaces the model in the request for every caller; the policy engine, per agent but per
    target rather than per model; and a rate limit keyed on `qualifiedModelId`.
  EOT
  type        = list(string)
  default     = []
}

variable "enable_policy_engine" {
  description = "Create a Cedar policy engine and attach it to the gateway. Without it the gateway routes and brokers but decides nothing about which tool a caller may invoke."
  type        = bool
  default     = true
}

variable "policy_engine_mode" {
  description = "ENFORCE, or LOG_ONLY to record each Cedar decision without denying. (Not AUDIT: the gateway API refuses it.)"
  type        = string
  default     = "ENFORCE"
  validation {
    condition     = contains(["ENFORCE", "LOG_ONLY"], var.policy_engine_mode)
    error_message = "policy_engine_mode must be ENFORCE or LOG_ONLY -- the gateway API's values. AUDIT is refused at apply."
  }
}

variable "gateway_permitted_agents" {
  description = <<-EOT
    Agents that may call the model through the gateway, as `name` (namespace agents) or
    `namespace/name`. Each gets a Cedar permit for the inference target, generated beside
    cedar_policies; the evaluation judge gets its own whenever enable_evaluations is on.

    The policy engine is ENFORCE and deny-by-default, so an agent with no permit gets 403 "No policy
    applies to the request" on every model call. Without this, research, two example agents and the
    judge each need a hand-written permit, all four identical. This is the same explicit allowlist,
    one name per agent. A permit in cedar_policies with the same
    key replaces the generated one.
  EOT
  type        = list(string)
  default     = ["research"]

  validation {
    condition     = alltrue([for a in var.gateway_permitted_agents : can(regex("^([a-z0-9]([-a-z0-9]*[a-z0-9])?/)?[a-z0-9]([-a-z0-9]*[a-z0-9])?$", a))])
    error_message = "Each entry is an agent name, or namespace/name, in Kubernetes name syntax."
  }
}

variable "evaluation_builtin_evaluators" {
  description = "AgentCore built-in evaluators the online evaluation grades with (see modules/evaluations-aws). Set [] to grade with llm_judge_evaluators only."
  type        = list(string)
  default     = ["Builtin.Helpfulness", "Builtin.Correctness", "Builtin.GoalSuccessRate"]
}

variable "cedar_policies" {
  description = "Cedar policies on the gateway's policy engine, keyed by name. Keep the statements in Git, so a platform team can review them before they take effect. Every permit must name its principal; restrict with forbid, never with a narrower permit. The generated forbid_unlisted_principals keeps any principal outside gateway_permitted_agents out of every target."
  type = map(object({
    description     = string
    statement       = string
    validation_mode = optional(string)
  }))
  default = {}

  # A PERMIT MUST NAME ITS PRINCIPAL. Cedar permits combine: any matching permit allows. On this
  # gateway every caller is an AgentCore::OAuthUser, so `permit(principal, ...)` and
  # `permit(principal is AgentCore::OAuthUser, ...)` both admit every subject the gateway's
  # audience accepts. scripts/lib/check_cedar_principals.py applies the same rule to the repo's
  # example tfvars; this applies it to yours, at plan time.
  validation {
    condition     = alltrue([for k, p in var.cedar_policies : !can(regex("permit\\s*\\(\\s*principal\\s*(is\\s+[A-Za-z:_]+\\s*)?[,)]", p.statement))])
    error_message = "A permit in cedar_policies must name its principal (principal == ... or principal in ...). permit(principal, ...) or permit(principal is AgentCore::OAuthUser, ...) admits every caller of the gateway, because Cedar permits combine. Restrict with a forbid instead."
  }
}

variable "gateway_baseline_forbid" {
  description = <<-EOT
    Attach forbid_unlisted_principals: a Cedar forbid that keeps every OAuth caller not in
    gateway_permitted_agents, the evaluation judge (with enable_evaluations) or
    gateway_extra_principals out of every gateway target. A forbid overrides every permit, so a
    broad permit attached by mistake cannot open the gateway to an unlisted agent. With it on, every
    principal the gateway serves must be in one of those lists.
  EOT
  type        = bool
  default     = true
}

variable "gateway_require_vpc_endpoint" {
  description = <<-EOT
    With the agentcore-gateway VPC endpoint in place (vpc_endpoints lists "agentcore"), attach a
    resource-based policy to the gateway that refuses every invocation not made through that
    endpoint (aws:SourceVpce). The gateway's endpoint stays public, and its authorizer accepts any
    valid token for its audience, so without this a projected agent token copied out of a pod works
    from anywhere until it expires. With it, the token works only from inside this VPC. No effect
    without the endpoint.
  EOT
  type        = bool
  default     = true
}

variable "gateway_rate_limits" {
  description = <<-EOT
    Request and token budgets per caller, enforced by the gateway before a call reaches its target.
    Every caller of this gateway is a workload, so a budget is per agent: the key is the caller's
    token subject, system:serviceaccount:<namespace>:<name>. `requests_per_minute` and
    `tokens_per_minute` apply to each agent; `per_agent` overrides them for an agent named as in
    gateway_permitted_agents (name, or namespace/name). Tokens count input plus output on the
    inference target only. A caller over its budget gets 429. Null sets no budget.

    Applied with the awscc provider (awscc_bedrockagentcore_gateway_rate_limit), which has the
    resource the aws provider doesn't.
  EOT
  type = object({
    requests_per_minute = optional(number)
    tokens_per_minute   = optional(number)
    per_agent = optional(map(object({
      requests_per_minute = optional(number)
      tokens_per_minute   = optional(number)
    })), {})
  })
  default = null

  validation {
    condition = var.gateway_rate_limits == null || alltrue([
      for b in concat([var.gateway_rate_limits], values(try(var.gateway_rate_limits.per_agent, {}))) :
      b.requests_per_minute != null || b.tokens_per_minute != null
    ])
    error_message = "Each budget in gateway_rate_limits, and each per_agent entry, needs requests_per_minute, tokens_per_minute or both."
  }
}

variable "gateway_guardrails" {
  description = <<-EOT
    A guardrail check the gateway runs on every model call, through AgentCore Policy, whatever the
    agent asked for:

      prompt_attack_threshold    Refuse a chat completion whose newest message scores above this
                                 for prompt_attack_categories: the user's prompt on a turn's first
                                 call, and each tool result on the calls after it. Each message is
                                 screened once, on the call that adds it, so a long session isn't
                                 re-scored as it grows, and the system prompt isn't screened.
                                 The default is 0.9. Lower refuses ordinary agent instructions:
                                 at 0.6, "Save this as my note with save_my_note: ... Reply OK."
                                 is refused every time. Null turns the check off.
      The model's response isn't screened here: AgentCore Policy's output check refuses every
      streamed chat completion, and the agents stream every turn. Screen responses in the agent,
      or with a Bedrock guardrail on a non-streaming route.

    The checks are AgentCore Policy statements on the inference target's chat completions action,
    applied through the aws CLI like dogwood_policies, so the aws CLI must be where terraform runs.
    Guardrails in policies are available only in some Regions; the policy fails to create in one
    that lacks them. Null attaches no guardrail.
  EOT
  type = object({
    prompt_attack_threshold  = optional(number, 0.9)
    prompt_attack_categories = optional(list(string), ["JAILBREAK", "PROMPT_INJECTION"])
  })
  default = null

  validation {
    condition     = var.gateway_guardrails == null || alltrue([for c in try(var.gateway_guardrails.prompt_attack_categories, []) : contains(["JAILBREAK", "PROMPT_INJECTION", "PROMPT_LEAKAGE"], c)])
    error_message = "prompt_attack_categories takes JAILBREAK, PROMPT_INJECTION and PROMPT_LEAKAGE."
  }
}

variable "enable_gateway_waf" {
  description = <<-EOT
    An AWS WAF web ACL on the AgentCore gateway: the AWS managed rule groups for common exploits,
    known bad inputs and SQL injection, inspecting every call before the gateway's authorizer runs.
    Rules that inspect the body count rather than block, because the body is the agent's
    conversation; see terraform/modules/waf. There is no per-IP rate rule, because every agent
    reaches the gateway from the same NAT or endpoint addresses; gateway_rate_limits budgets each
    agent instead. AWS WAF bills per web ACL, per rule and per request.
  EOT
  type        = bool
  default     = false
}

variable "gateway_extra_principals" {
  description = "Workload subjects (system:serviceaccount:<namespace>:<name>) the baseline forbid admits besides gateway_permitted_agents and the judge, for a caller that uses tools through the gateway but has no model permit. Each still needs a permit of its own."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for p in var.gateway_extra_principals : can(regex("^system:serviceaccount:[a-z0-9-]+:[a-z0-9-]+$", p))])
    error_message = "Each gateway_extra_principals entry is a workload subject: system:serviceaccount:<namespace>:<name>."
  }
}

variable "api_key_providers" {
  description = "Credential providers for services that issue only a static key. secret_id names an existing Secrets Manager secret; Terraform never sets its value."
  type = map(object({
    secret_id = string
    json_key  = string
  }))
  default = {}
}

variable "oauth2_providers" {
  description = <<-EOT
    Credential providers for services that require the person's own consent.

    On this path the platform team supplies the piece that receives that approval: a small web
    service behind a load balancer, once per service rather than once per agent. The callback URL
    each provider expects is in the oauth2_callback_urls output, and it has to be registered with
    that service's own app configuration before the first consent flow can complete.
  EOT
  type = map(object({
    vendor        = string
    client_id     = string
    secret_id     = string
    json_key      = optional(string, "client_secret")
    tenant_id     = optional(string)
    discovery_url = optional(string)
  }))
  default = {}
}

variable "mcp_server_targets" {
  description = "Remote MCP servers agents reach through the gateway."
  type = map(object({
    description = string
    endpoint    = string
    # DEFAULT or DYNAMIC, the only two the module accepts; any other value, such as "EXPLICIT",
    # fails the module's validation at plan time.
    listing_mode = optional(string, "DEFAULT")

    # Reachability for a target inside a VPC. Omit for a target on the public internet. See
    # modules/egress-agentcore for what the address behind it has to be.
    private_endpoint = optional(object({
      vpc_id                   = string
      subnet_ids               = list(string)
      security_group_ids       = optional(list(string), [])
      endpoint_ip_address_type = optional(string, "IPV4")
    }))
    credential = object({
      kind           = string
      provider       = optional(string)
      location       = optional(string, "HEADER")
      parameter_name = optional(string, "Authorization")
      prefix         = optional(string, "Bearer")
      scopes         = optional(list(string), [])
      grant_type     = optional(string, "AUTHORIZATION_CODE")
      # AUTHORIZATION_CODE: the consent receiver's /complete/<key> (agentcore_consent).
      default_return_url = optional(string)
      service            = optional(string)
    })
  }))
  default = {}
}

variable "lambda_targets" {
  description = <<-EOT
    MCP tools backed by a Lambda function, keyed by target name.

    THE ONLY TARGET SHAPE THAT WORKS FOR A TOOL YOU WRITE YOURSELF ON THIS PATH. The gateway runs
    outside the VPC, so it cannot reach a ClusterIP Service: an in-cluster MCP server needs a
    private endpoint and a VPC-routable address, which `mcp_server_targets` does not configure. A
    Lambda target needs no network path at all -- the gateway signs the invoke with its own role.

    `lambda_target_arns` is what grants that invoke; it defaults to the function ARNs named here,
    so the ordinary case needs nothing else. Set it only to widen or narrow the grant.

    apps/mcp-lambda carries a worked function and the commands that deploy it.
  EOT
  type = map(object({
    description  = string
    function_arn = string
    tool_schema = list(object({
      name        = string
      description = string
      properties = optional(list(object({
        name        = string
        type        = string
        description = optional(string, "")
        required    = optional(bool, false)
      })), [])
    }))
  }))
  default = {}
}

variable "lambda_target_arns" {
  description = "Function ARNs the gateway's role may invoke. Empty means every function named in lambda_targets, which is almost always what you want."
  type        = list(string)
  default     = []
}

variable "open_api_targets" {
  description = "OpenAPI services exposed to agents as MCP tools. Every response media type in the schema must be application/json, application/xml, multipart/form-data or application/x-www-form-urlencoded: a text/plain response is accepted by the create call and the target then settles FAILED."
  type = map(object({
    description   = string
    schema_s3_uri = optional(string)
    schema_inline = optional(string)

    # Reachability for a target inside a VPC. Omit for a target on the public internet. See
    # modules/egress-agentcore for what the address behind it has to be.
    private_endpoint = optional(object({
      vpc_id                   = string
      subnet_ids               = list(string)
      security_group_ids       = optional(list(string), [])
      endpoint_ip_address_type = optional(string, "IPV4")
    }))

    credential = object({
      kind           = string
      provider       = optional(string)
      location       = optional(string, "HEADER")
      parameter_name = optional(string, "Authorization")
      prefix         = optional(string, "Bearer")
      scopes         = optional(list(string), [])
      grant_type     = optional(string, "AUTHORIZATION_CODE")
      # AUTHORIZATION_CODE: the consent receiver's /complete/<key> (agentcore_consent).
      default_return_url = optional(string)
      service            = optional(string)
    })
  }))
  default = {}
}

# --- Observability -----------------------------------------------------------

variable "enable_observability" {
  description = <<-EOT
    The agents' telemetry: the agent telemetry log group, the ADOT collector and its IAM role, the
    CloudWatch dashboard, and Transaction Search when enable_transaction_search is also set. In the
    cluster, the ADOT collector and the cert-manager its operator's webhooks need
    (gitops/platform/aws-services/templates/45-cert-manager.yaml, 50-adot.yaml) are synced only with this on.
    The same switch as the open source path's, where it is the OpenTelemetry collector, Prometheus,
    Grafana and the dashboard.

    Off means agents are given no OTLP endpoint and no egress to a collector, and export nothing.
    Needed by enable_evaluations and enable_online_evaluation, which grade the spans it records.
  EOT
  type        = bool
  default     = false
}


variable "enable_transaction_search" {
  description = "Enable CloudWatch Transaction Search. Required for the GenAI Observability views, and an account-and-Region setting, so enable it in one configuration per Region."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Retention on the agent log groups. These carry prompts and tool arguments."
  type        = number
  default     = 90
}

# --- Memory ------------------------------------------------------------------

variable "enable_session_state" {
  description = "Create the ElastiCache Serverless cache. This is the rung most agents need, and the only one."
  type        = bool
  default     = false
}

variable "session_state_user_group_id" {
  description = "ElastiCache user group for IAM authentication. Null creates one, with the default user disabled and an IAM-authenticated user for the agents; pass an id to use a group you manage."
  type        = string
  default     = null
}

variable "enable_semantic_recall" {
  description = "Create the S3 Vectors bucket and indexes. Enable where an agent retrieves by meaning."
  type        = bool
  default     = false
}

variable "semantic_recall_bucket_name" {
  description = "Vector bucket name. Null derives it from the cluster name and the account ID."
  type        = string
  default     = null
}

variable "semantic_recall_indexes" {
  description = "Vector indexes. dimension has to match the embedding model; a mismatch is not caught until the first write."
  type = map(object({
    dimension                    = number
    distance_metric              = optional(string, "cosine")
    non_filterable_metadata_keys = optional(list(string), [])
  }))
  default = {}
}

variable "enable_consolidation" {
  description = "Create AgentCore Memory. The rung most teams do not reach; a team that cannot name its case for it is better off without it."
  type        = bool
  default     = false
}

variable "consolidation_event_expiry_duration" {
  description = "How long raw memory events are kept, in DAYS (3-365). Set it from the organization's retention policy: this is a store of what people told the agents. Not an ISO-8601 duration -- the API takes an integer number of days."
  type        = number
  default     = 90
}

variable "consolidation_model_arns" {
  description = "Models the memory execution role may invoke for extraction and consolidation."
  type        = list(string)
  default     = []
}

variable "consolidation_strategies" {
  description = "Memory strategies. namespaces is what scopes memory per user and per agent; without it a personalizing agent can return one person's context to another. The four built-in types (SEMANTIC, SUMMARIZATION, USER_PREFERENCE, EPISODIC) take nothing else; configuration_type and the model overrides apply only to CUSTOM."
  type = map(object({
    type                   = string
    namespaces             = list(string)
    configuration_type     = optional(string)
    extraction_model_id    = optional(string)
    extraction_prompt      = optional(string, "")
    consolidation_model_id = optional(string)
    consolidation_prompt   = optional(string, "")
  }))
  default = {}
}

# --- Evaluations -------------------------------------------------------------

variable "judge_model_arns" {
  description = "Models the evaluation role may invoke as a judge."
  type        = list(string)
  default     = []
}

variable "llm_judge_evaluators" {
  description = "Graded dimensions. Ship a handful rather than one: a single aggregate score tells nobody which release regressed."
  type = map(object({
    description      = string
    level            = string
    instructions     = string
    model_id         = string
    judge_max_tokens = optional(number, 2048)
    rating_scale = list(object({
      label      = string
      definition = string
      score      = number
    }))
  }))
  default = {}
}

variable "evaluation_service_names" {
  description = <<-EOT
    The OTEL service name online evaluation grades, for an agent this configuration does not create.

    REQUIRED WHEN enable_online_evaluation IS TRUE AND `agents` IS EMPTY, which is the normal case:
    an empty `agents` map is what turns the `Agent` resource definition on, so Terraform never sees
    the agents and cannot derive this. Without it the apply fails on the evaluation config after
    everything else has been created.

    ONE NAME, NOT A LIST OF AGENTS. The API accepts exactly one service name per online evaluation
    config, so grading several agents needs several configs. This is a list only so that it can
    combine with the subjects derived from `agents`; the total has to come to one.

    The value is the agent's OTEL service.name -- the `Agent` resource's name, unless the agent
    overrides OTEL_SERVICE_NAME.
  EOT
  type        = list(string)
  default     = []
}

variable "enable_online_evaluation" {
  description = "Grade live traffic, sampled. Off by default; turn it on once the evaluator definitions have been reviewed. On, the ADOT collector keeps prompt and completion content on spans, which it strips otherwise (collector.keepPromptContent in gitops/charts/adot-collector), because the grading reads what the agent said from them."
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_online_evaluation || var.enable_observability
    error_message = "enable_online_evaluation needs enable_observability: it grades the spans the collector writes to the agents' telemetry log group, and with no collector there are none."
  }
}

variable "enable_online_evaluation_on_create" {
  description = "Start the online evaluation immediately. False creates it stopped, for validating the evaluator definitions before paying for them."
  type        = bool
  default     = false
}

variable "evaluation_sampling_percentage" {
  description = "Share of sessions graded. Every sampled session is a judge model call."
  type        = number
  default     = 10
}

# --- GitOps handoff ----------------------------------------------------------

variable "evaluation_session_timeout_minutes" {
  description = <<-EOT
    Idle time after a session's last span before online evaluation treats it as finished and grades
    it. This is the latency floor on every grade: with the default, nothing is graded until thirty
    minutes after a conversation's last turn.

    Lower it to see grades sooner, for a test or a batch agent whose sessions end with their last
    call. Keep it above the longest pause a person leaves between turns on an interactive agent, or
    one conversation is graded as several.
  EOT
  type        = number
  default     = 30
}

variable "write_gitops_values" {
  description = "Render the values file the GitOps side reads."
  type        = bool
  default     = true
}

variable "activate_cost_allocation_tags" {
  description = <<-EOT
    Activate the cost allocation tags this stack's usage carries -- iamPrincipal/agent and
    iamPrincipal/cluster from the Pod Identity session tags, aws:eks:cluster-name, and
    eks-agents/path -- so per-agent and per-cluster spend reaches Cost Explorer and the CUR. On this path the model call is signed by the gateway's role, so
    per-agent MODEL spend is not in the bill -- see the comment on the resource.

    OFF BY DEFAULT for two reasons that are both about when it can succeed rather than whether it is
    wanted. It is a billing-level setting, so the apply needs PAYER-ACCOUNT credentials and fails
    with AccessDenied from a member account. And a user-defined key is activatable only once it has
    appeared in the account's tag inventory, which happens after tagged usage exists -- so an apply
    that turns it on before any agent has called a model can fail on a key the account has not seen.

    The sequence that works: apply, run some agents, then set this true with payer credentials.
    Activation is not retroactive; spend before it stays unsplit.
  EOT
  type        = bool
  default     = false
}

variable "path_name_for_bootstrap" {
  description = "Which gitops/bootstrap directory to render the applyable bootstrap objects from. Defaults to this root's own path and should not need changing."
  type        = string
  default     = "aws-services"
}

variable "agent_image_registry" {
  description = <<-EOT
    A registry that already holds the agent images, instead of the ECR repositories this
    configuration creates.

    Empty is the default and means ECR: `terraform apply` creates the repositories, you build and
    push into them, and `registry` in the rendered values points there. That build step is the one
    manual step left in the quickstart.

    Set this to the prefix of a registry you choose that already holds the images -- your own ECR
    registry or mirror, for example -- and the same repository paths are appended to it, so every
    chart, example and `Agent` follows without an edit.
  EOT
  type        = string
  default     = ""
}

variable "gitops_values_path" {
  description = <<-EOT
    Where to write that file. Commit it; it carries no secret -- but it does carry your account id,
    your cluster's name and every endpoint, so commit it to your own fork.

    THE DEFAULT IS A TRACKED FILE, AND APPLY OVERWRITES IT IN PLACE. That is the point -- it is how
    the GitOps side learns the ARNs -- and it has one consequence worth knowing before your first
    apply in a clone of this repository: the placeholder version in Git is replaced, so a
    `git add -A` for an unrelated change commits your rendered values along with it. Point this
    somewhere outside the work tree if you would rather render and copy deliberately.
  EOT
  type        = string
  default     = "../../gitops/platform/aws-services/terraform-values.yaml"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}

variable "network_policy_admin_tier_default_deny" {
  description = <<-EOT
    End the reasoning namespace's Admin tier with a Deny (networkPolicy.adminTierDefaultDeny), so the
    cluster-scoped Accepts are the agents' whole reachable set and a namespaced policy a tenant can
    edit cannot widen it. Off by default: some destinations are admitted below the Admin tier, and the
    chart names them in the Admin tier only when this is on. Run scripts/exercise.sh with it
    on before relying on it. An Agent with needsClusterApi keeps the Kubernetes API under it, through
    the Admin-tier Accept eks-agents-cluster-api, and an Agent with mcpAudience keeps the MCP servers'
    namespace, through eks-agents-mcp-servers.
  EOT
  type        = bool
  default     = false
}

variable "enable_network_policy" {
  description = <<-EOT
    Deploy the egress boundary: the enforcement ConfigMap, the cluster-scoped and namespaced policy
    tiers, and the per-agent policy each Agent composes.

    Off means an agent namespace has NO egress boundary -- an agent reaches anything the node can,
    and nothing makes the managed gateway unavoidable. Set it false only where something else
    provides the boundary. One asymmetry: turning it off removes the ConfigMap but does NOT disable
    enforcement on a cluster where it was once enabled, because that ConfigMap belongs to the
    cluster rather than to this release.

    enable_gateway decides what the policy names as the model destination: the gateway's host name,
    or bedrock-runtime with it off.
  EOT
  type        = bool
  default     = true
}

variable "mesh_mode" {
  description = <<-EOT
    The one variable that decides the mesh configuration: "none" or "ambient".

    none      The default, on both paths. No mesh. Egress still fails closed, because the network policy makes the gateway the
              only reachable destination -- but pointing an agent at the gateway becomes a
              convention the agent could ignore rather than something it cannot evade. Correct when
              every agent on the cluster is one the platform team builds or packages.

    ambient   One proxy per node. Traffic is captured below the
              agent, so an unmodified or third-party agent runs under the same controls as one the
              platform team governs, and the agent's pod holds no mesh key -- which matters here
              because that pod is the one running model-generated code.

    There is no sidecar mode: an agent's namespace enforces Pod Security restricted, which
    refuses istio-init, and a sidecar would put a mesh key in the pod that runs model-generated
    code.

    This is rendered into the GitOps values file, so Terraform and the charts cannot disagree about
    it. Changing it after the fact is a migration rather than a toggle: the namespace labels, the
    Istio installation and where authorization policy attaches all follow from it.

    THE DEFAULT IS "none" ON BOTH PATHS: the base is network policy alone, and the mesh is a layer
    you turn on. On this path it buys less than on the open source one, because the managed gateway
    is reached over the internet rather than as an in-cluster service, and it is three charts and a
    data plane to operate. Setting it to ambient here also syncs 54-istio-namespace.yaml and
    55-istio.yaml, which this variable otherwise excludes from the root Application --
    gitops/platform/aws-services/ISTIO-DECISION.md has the decision.

    See the agents-mesh page of the EKS User Guide.
  EOT
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "ambient"], var.mesh_mode)
    error_message = "mesh_mode must be one of: none, ambient. There is no sidecar mode; see the agents-mesh page of the EKS User Guide."
  }
}

# --- the managed Argo CD, and what it requires -------------------------------
#
# The ARGOCD capability authenticates PEOPLE through AWS IAM Identity Center, and
# idc_instance_arn is required by the API -- so it cannot be created in an organization that has no
# IdC instance, and there is no IAM-only mode. The instance is therefore a PREREQUISITE of the
# default apply (README, "Before you begin"); set enable_argocd = false to apply without one.
#
# Find the instance with `aws sso-admin list-instances`. An organization has at most one, in a
# single region, which is frequently not the cluster's region.
variable "enable_argocd" {
  description = <<-EOT
    Create the managed Argo CD (the ARGOCD EKS Capability), which is what applies everything in
    gitops/. Without it nothing from that directory reaches the cluster and
    `scripts/install-platform.sh` is the fallback.

    ON BY DEFAULT, which makes an IAM Identity Center instance a prerequisite: the capability cannot
    be created without one, and CreateCapability requires it even on a cluster where nobody signs
    in. Everything else is automatic -- the instance is discovered, the admin group is created, and
    the role mapping is composed. If no instance exists, the apply fails with the single call that
    creates one (`aws sso-admin create-instance`).

    Set false only in an organization that cannot have an Identity Center instance; every other
    resource still applies, and `scripts/install-platform.sh` installs gitops/ from the bastion.
  EOT
  type        = bool
  default     = true
}

variable "argocd_idc_instance_arn" {
  description = "ARN of the IAM Identity Center instance for the managed Argo CD. Leave empty to discover the instance in this account and region, which is the zero-step path. Setting it also turns the capability on."
  type        = string
  default     = ""
}

variable "argocd_manage_admin_group" {
  description = "Create the Identity Center group that holds Argo CD ADMIN and map it, rather than leaving the group, the membership and the mapping to the operator. On by default; see the module's variables.tf for what it replaces."
  type        = bool
  default     = true
}

variable "argocd_admin_group_name" {
  description = "Display name of the Argo CD admin group. Defaults to <cluster>-argocd-admins."
  type        = string
  default     = ""
}

variable "argocd_admin_users" {
  description = "Identity Center users to create and grant Argo CD ADMIN. Each needs user_name, display_name, given_name, family_name and email. Identity Center sends an invitation and the person sets their own password at first sign-in; there is no API for it."
  type = list(object({
    user_name    = string
    display_name = string
    given_name   = string
    family_name  = string
    email        = string
  }))
  default = []
}

variable "argocd_admin_existing_user_names" {
  description = "Identity Store user names that already exist and should hold Argo CD ADMIN. The normal case in an organization already using Identity Center."
  type        = list(string)
  default     = []
}

variable "argocd_idc_region" {
  description = <<-EOT
    Region of the Identity Center instance, when it differs from the cluster's. Empty means the
    cluster's region.

    This is the ONLY thing a cross-region instance needs. Discovery, the admin group, the users and
    the memberships all follow it, because Identity Center is reached through a provider aliased to
    this region.
  EOT
  type        = string
  default     = ""
}

variable "argocd_rbac_role_mappings" {
  description = "Who gets which Argo CD role. role is ADMIN, EDITOR or VIEWER; identity_type is SSO_USER or SSO_GROUP; identity_id is an Identity Store id. Prefer a group over a user."
  type = list(object({
    role          = string
    identity_type = string
    identity_id   = string
  }))
  default = []
}

variable "argocd_vpce_ids" {
  description = "VPC endpoint ids that may reach the managed Argo CD, for keeping its API and UI off the internet."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# What the Argo CD capability may read
# ---------------------------------------------------------------------------
#
# The capability's role is created with a trust policy and NO permissions, so until one of these is
# set it cannot read any repository and every Application fails before it syncs anything:
#
#   ComparisonError: Failed to load target state: ... failed to list refs: authorization failed:
#   User: .../<cluster>-capability-argocd is not authorized to perform: codecommit:GitPull
#
# A public repository over anonymous HTTPS is the only source that needs none of these. Pick the one
# matching where your manifests live; the module documents the reference form each one requires.

variable "argocd_codecommit_repository_arns" {
  description = "CodeCommit repository ARNs the Argo CD capability may pull from. In-account and IAM-authenticated, so no credential is stored anywhere."
  type        = list(string)
  default     = []
}

variable "argocd_codeconnections_arns" {
  description = "CodeConnections connection ARNs the Argo CD capability may use. The path for GitHub, GitLab or Bitbucket, including self-managed servers; the connection holds the authorization so no credential enters the cluster."
  type        = list(string)
  default     = []
}

variable "argocd_secrets_manager_secret_arns" {
  description = "Secrets Manager secret ARNs holding repository credentials, for a Git host the direct integrations do not cover. The in-cluster Repository Secret carries only a secretArn, so the credential itself never enters Kubernetes."
  type        = list(string)
  default     = []
}

variable "argocd_ecr_pull" {
  description = "Let the Argo CD capability read Helm charts and OCI artifacts from ECR, for manifests that are packaged rather than kept in Git."
  type        = bool
  default     = false
}

variable "argocd_cluster_access_policy_arn" {
  description = <<-EOT
    EKS access policy associated with the Argo CD capability role, at cluster scope.

    The capability's own access entry (AmazonEKSArgoCDClusterPolicy, plus AmazonEKSArgoCDPolicy on
    the `argocd` namespace) cannot list arbitrary resource types, so Argo CD's cluster cache never
    builds without cluster-wide read. This stack also applies cluster-scoped objects (CRDs,
    ClusterNetworkPolicies, ValidatingAdmissionPolicies, ClusterRoles), so it needs cluster-scoped
    write as well.

    The default, AmazonEKSClusterAdminPolicy, is the EKS User Guide's quick-setup choice, which the
    guide says not to use in production. For production, set this to "" (no association is made)
    and grant the capability role AmazonEKSAdminViewPolicy, or a get/list/watch ClusterRole, plus a
    custom ClusterRole bound to the group `eks-access-entry:<capability role ARN>`, limited to the
    kinds this stack applies:
    https://docs.aws.amazon.com/eks/latest/userguide/argocd-register-clusters.html
  EOT
  type        = string
  default     = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
}

variable "allowed_agent_subjects" {
  description = <<-EOT
    AT MOST ONE Kubernetes service account subject the AgentCore Gateway admits, as
    `system:serviceaccount:<namespace>:<name>`. Empty is valid and is the right answer for more
    than one agent.

    This is the gateway's inbound allowlist and it is a platform control, stated here rather than
    derived from the agents, because agents are declared in the cluster as `Agent` resources and
    Terraform does not know them when the gateway is created. The app team creates an `Agent` that
    uses this service account; an agent on any other one gets a token the gateway refuses with
    `403 insufficient_scope`.

    ONE, NOT A LIST, AND THAT IS THE GATEWAY'S LIMIT. `EQUALS` over a `STRING` claim is the only
    shape that admits anything: both multi-value operators demand a `STRING_ARRAY` claim type,
    which declares the CLAIM is an array, and `sub` in a projected token is a string -- so a gateway
    configured that way is created, reports READY and refuses every token. A second rule on `sub`
    is rejected as a duplicate claim name, and a rule on the nested `kubernetes.io` claim is
    accepted and matches nothing, so there is no namespace-level form either.

    Do not pass a prefix: the regex below rejects it, and `CONTAINS` cannot be configured against a
    string claim anyway.

    WITH MORE THAN ONE AGENT, leave this empty. The gateway then admits every subject its audience
    accepts, and per-agent separation comes from the egress network policy -- which namespaces may
    reach the gateway at all -- plus the policy engine, whose Cedar principal
    `AgentCore::OAuthUser` carries this same subject as its entity id.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.allowed_agent_subjects) <= 1
    error_message = "At most one subject. An AgentCore Gateway admits exactly one service account subject: EQUALS is the only operator a STRING claim accepts, CONTAINS and CONTAINS_ANY both require a STRING_ARRAY claim type that a JWT `sub` never has, and a second rule on `sub` is rejected as a duplicate claim name. For more than one agent, leave this empty and separate the agents with the egress network policy and the policy engine."
  }

  validation {
    condition     = alltrue([for s in var.allowed_agent_subjects : can(regex("^system:serviceaccount:[a-z0-9-]+:[a-z0-9-]+$", s))])
    error_message = "Each entry must be a full subject of the form system:serviceaccount:<namespace>:<name>."
  }
}

variable "gateway_model_id" {
  description = <<-EOT
    The model name agents put in the `model` field of a request to the gateway.

    This is NOT a Bedrock model id or inference profile id. The AgentCore connector advertises its
    own catalogue with ids of the form `bedrock/<provider>.<model>`, and a Bedrock id returns a 404
    from an otherwise correct call. List what your gateway serves once it exists:

      curl -H "Authorization: Bearer $TOKEN" https://<gateway>/inference/v1/models

    Pick one that serves the OpenAI dialect: some models refuse /v1/chat/completions and require
    /v1/messages with an anthropic_version field, which an OpenAI-SDK agent does not send.

    The examples use bedrock/openai.gpt-oss-120b, which serves the OpenAI dialect, while the base,
    which calls Amazon Bedrock directly, gets Claude Sonnet 5.5 from model.directModelId. Check the
    catalogue for the models your gateway serves.
  EOT
  type        = string
  default     = ""
}

variable "enable_temporal_policies" {
  description = <<-EOT
    Grant the gateway what a TEMPORAL policy needs, and expect every caller to supply a policy
    session.

    Temporal policies are written in Dogwood, a strict superset of Cedar, and decide on what has
    already happened in a session rather than on the current request alone: an approval before a
    transfer, a call count in a window, a running total under a budget. Two things come with them
    and both fail late:

      1. The gateway mints a Workload Access Token to carry the caller's session identity, so its
         role needs bedrock-agentcore:GetWorkloadAccessToken.
      2. EVERY request must carry a policy session id in the
         x-amzn-bedrock-agentcore-policy-session-id header. The gateway does NOT generate one, and
         omitting it while a temporal policy is attached is a validation error -- so this is a
         change to how agents CALL the gateway, not only to the policy set. Changing temporal
         policies mid-session also invalidates open sessions.

    Leave it false unless a policy actually references the past.
  EOT
  type        = bool
  default     = false
}

variable "dogwood_enforcement_mode" {
  description = "LOG_ONLY (default: record what each temporal policy would have denied) or ACTIVE (enforce). See dogwood_policies."
  type        = string
  default     = "LOG_ONLY"
}

variable "dogwood_policies" {
  description = <<-EOT
    TEMPORAL policies, written in Dogwood, keyed by name. Use `{{gateway_arn}}` where the gateway's
    ARN goes.

    Dogwood is a strict superset of Cedar: it adds conditions over what already happened in a
    SESSION -- an approval before an action, a call count in a window, a running total under a
    budget. Everything a plain Cedar policy can say still belongs in cedar_policies; reach for this
    only when a rule must look at the past.

    Applied through the aws CLI (definition.policy) by terraform/modules/egress-agentcore, because
    the AWS provider's policy resource exposes only the Cedar definition and rejects a temporal
    statement there with `unexpected token 'temporal'`. Created on apply, waited on until ACTIVE,
    replaced on change, deleted on destroy; needs the aws CLI where terraform runs. See the module's variable documentation for the three syntax rules and
    the one semantic rule that each cause a policy to fail or to silently never match, and set
    enable_temporal_policies so the gateway has the IAM it needs.
  EOT
  type = map(object({
    description = string
    statement   = string
  }))
  default = {}

  # A PERMIT MUST NAME ITS PRINCIPAL. Cedar permits combine: any matching permit allows. On this
  # gateway every caller is an AgentCore::OAuthUser, so `permit(principal, ...)` and
  # `permit(principal is AgentCore::OAuthUser, ...)` both admit every subject the gateway's
  # audience accepts. scripts/lib/check_cedar_principals.py applies the same rule to the repo's
  # example tfvars; this applies it to yours, at plan time.
  validation {
    condition     = alltrue([for k, p in var.dogwood_policies : !can(regex("permit\\s*\\(\\s*principal\\s*(is\\s+[A-Za-z:_]+\\s*)?[,)]", p.statement))])
    error_message = "A permit in dogwood_policies must name its principal (principal == ... or principal in ...). permit(principal, ...) or permit(principal is AgentCore::OAuthUser, ...) admits every caller of the gateway, because Cedar permits combine. Restrict with a forbid instead."
  }

  validation {
    condition     = length(var.dogwood_policies) == 0 || var.enable_temporal_policies
    error_message = "dogwood_policies needs enable_temporal_policies = true: the gateway must be allowed to mint the Workload Access Token that carries a session's identity, and without it every call fails at that step once a temporal policy is attached."
  }
}

variable "bastion_teardown_access" {
  description = "Let the bastion delete this stack's ECR repositories and empty its checkpoint bucket, so scripts/teardown.sh runs whole on it (through scripts/run-stack.sh) before terraform destroy. Scoped to this stack's own repositories and bucket. The recommended setting; false splits the teardown across two credentials. See modules/bastion teardown_access."
  type        = bool
  default     = true
}

variable "enable_image_build" {
  description = <<-EOT
    Build the agent images in AWS CodeBuild. `scripts/build-images.sh --root` then stages this
    working tree in an S3 bucket and starts one build that pushes to this stack's ECR repositories,
    so neither the bastion nor a workstation needs Docker, and an Arm workstation needs no
    cross-build. Terraform creates only the project (terraform/modules/image-build); `apply` builds
    nothing. Off, build-images.sh --root builds through scripts/run-stack.sh: on the bastion, or on
    the workstation with Docker or Finch.
  EOT
  type        = bool
  default     = true
}

variable "image_build_architecture" {
  description = "`x86_64` or `arm64`: what CodeBuild builds on, and so the images' architecture. Match the node pools the agents run on (EKS Auto Mode's default pool is x86_64)."
  type        = string
  default     = "x86_64"
}

variable "enable_bastion" {
  description = <<-EOT
    Create the SSM-managed host that reaches the cluster's private API endpoint.

    ON BY DEFAULT. The control plane endpoint is private by default, so nothing outside the VPC can
    run kubectl against it -- which is every in-cluster step in the EKS User Guide and this
    repository's README, including bootstrapping GitOps and confirming the egress boundary is
    enforcing. The bastion is REQUIRED with a private-only endpoint: false is refused unless the
    endpoint is public (cluster_endpoint_public_access).

    WORKSTATION MODE: cluster_endpoint_public_access = true and enable_bastion = false. Every step
    and script then runs from your machine: kubectl against the public endpoint (restricted to
    cluster_endpoint_public_access_cidrs), and scripts/run-stack.sh -- which exercise.sh,
    build-images.sh --root and teardown.sh --root use -- runs here instead of on a host. Images
    build in CodeBuild (enable_image_build), so the machine needs no Docker.
    Reaching ingress from the machine as well needs ingress_scheme = "internet-facing", which is
    allowlisted by ingress_allowed_cidrs.
    The trade-off is the fallback: with no bastion, the allowlist is the only way in. When this
    machine's public address changes -- a VPN, or a network that leaves through a rotating pool of
    NAT addresses -- every call times out until you apply again from the new address, and the
    endpoint keeps refusing for a few minutes after that apply while EKS rolls it out. On such a
    network name the pool's CIDRs in cluster_endpoint_public_access_cidrs instead of relying on the
    one-address default, or keep the bastion.

    The host costs roughly the price of its instance type; see bastion_instance_type.
  EOT
  type        = bool
  default     = true
}

variable "bastion_instance_type" {
  # t3.small, not t4g.small. The module resolves the AL2023 AMI by architecture, which defaults to
  # x86_64 to match EKS Auto Mode's default node pool -- so an arm64 instance type here boots an
  # x86_64 AMI and the instance never comes up. The two have to agree.
  description = "The bastion's instance type. It runs kubectl, helm, git and the agent image builds, not workloads. Change it together with bastion_architecture."
  type        = string
  default     = "t3.small"
}

variable "bastion_architecture" {
  description = <<-EOT
    The bastion's CPU architecture: `x86_64` or `arm64`. Must match the architecture your node pools
    run, because the bastion is where the agent images are built -- an arm64 build will not run on
    x86_64 nodes, and the failure is `exec format error` after a successful pull.
  EOT
  type        = string
  default     = "x86_64"
}

variable "bastion_kubectl_version" {
  description = "The kubectl release the bastion installs, as a `v1.33.0`-style tag. Keep it within one minor of kubernetes_version."
  type        = string
  default     = "v1.36.6"
}

# ---------------------------------------------------------------------------
# Ingress
# ---------------------------------------------------------------------------

variable "enable_ingress" {
  description = <<-EOT
    Expose agents to a person through an Application Load Balancer, with the caller authenticated at
    the load balancer before any agent sees the request.

    This turns on the cluster's Gateway API setting and emits the `ingress` values the base chart
    needs. Off by default: an agent reached only by other agents or by a schedule needs none of it,
    and an exposed agent is the one thing in this stack that cannot be undone quietly.

    The load balancer is INTERNAL. Reaching it means being inside the VPC or on a network routed to
    it; `ingress_scheme` is the only place that changes, and it is a separate decision with a
    separate review.
  EOT
  type        = bool
  default     = false
}

variable "ingress_domain_name" {
  description = <<-EOT
    The DNS suffix agents are reached at, e.g. `agents.example.com`. An agent's route claims
    `<agent>.<this>`, and the certificate has to cover that.

    A private hosted zone is created for it, holding an alias to the load balancer, so the name
    resolves inside the VPC and nowhere else. That is deliberate even when the certificate is
    publicly trusted: a publicly resolvable name in front of an internal load balancer tells the
    internet an endpoint exists and where, and buys nothing.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = !var.enable_ingress || var.ingress_domain_name != ""
    error_message = "ingress_domain_name is required when enable_ingress is true. An agent's route hostname is derived from it, and a route whose hostname the listener certificate does not cover is accepted and then fails the TLS handshake, which reads like a DNS fault."
  }
}

variable "ingress_certificate_arn" {
  description = <<-EOT
    An existing ACM certificate for the HTTPS listener, covering `*.<ingress_domain_name>`. Empty
    requests one from ACM against the public hosted zone in `ingress_public_zone_id`.

    Supply it when the zone is not in this account, or when the certificate is an imported one. An
    ALB serves only ACM certificates, so there is no third option: either ACM issues it or you
    import it into ACM first.
  EOT
  type        = string
  default     = ""
}

variable "ingress_self_signed_certificate" {
  description = <<-EOT
    Generate the HTTPS listener's certificate and import it into ACM, instead of requesting one or
    naming one.

    FOR A PRIVATE INGRESS WITH NO PUBLICLY DELEGATED ZONE. ACM issues only against DNS it can
    reach, and an ALB serves only ACM certificates -- so without this, a cluster whose agents live
    under an internal name has no way to bring up an HTTPS listener except by hand, with `openssl`
    and `aws acm import-certificate`. A manual step inside a security control is the thing this
    repository exists to remove.

    Nothing trusts it by default: a browser warns, and a client has to be given the
    `ingress_certificate_pem` output as a CA. Right for an internal ingress exercised by a
    workload gate or a test; wrong for ingress a person logs into for real, which wants a
    delegated zone and an ACM-issued certificate.
  EOT
  type        = bool
  default     = false
}

variable "ingress_public_zone_id" {
  description = <<-EOT
    A PUBLICLY DELEGATED Route 53 zone covering `ingress_domain_name`, used only to answer ACM's
    DNS validation challenge. Required when `ingress_certificate_arn` is empty.

    Publicly delegated is the part that bites: a zone can exist in Route 53 while the registrar's NS
    records point elsewhere, and ACM validation then waits forever against a zone that is
    authoritative for nobody. Check with `dig +short NS <domain> @8.8.8.8` before relying on it.
  EOT
  type        = string
  default     = ""

  validation {
    condition = (!var.enable_ingress || var.ingress_certificate_arn != "" ||
    var.ingress_public_zone_id != "" || var.ingress_self_signed_certificate)
    error_message = "Ingress needs one of: ingress_certificate_arn (one you already hold), ingress_public_zone_id (so ACM can issue against a delegated zone), or ingress_self_signed_certificate = true (generated here, trusted by nothing). An ALB serves only certificates held in ACM, so there is no fourth option."
  }
}

variable "ingress_allowed_cidrs" {
  description = <<-EOT
    Source CIDRs an internet-facing ingress load balancer admits, on HTTPS only. Used only with
    ingress_scheme = "internet-facing", where Terraform creates the load balancer's security group
    from it, so moving it is an apply and no GitOps sync. Empty, the default, means the same
    addresses as the API endpoint: cluster_endpoint_public_access_cidrs, or this machine's public
    IPv4 address as a /32 when that is empty. 0.0.0.0/0 is refused. The sign-in gate stays on every
    route either way; this narrows who can reach the sign-in page at all.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.ingress_allowed_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 opens the agents' ingress to the internet. Name the CIDRs that need it, or leave the list empty for the API endpoint's allowlist."
  }
}

variable "ingress_scheme" {
  description = <<-EOT
    `internal` or `internet-facing`, and it belongs to the platform team rather than to an agent
    author -- which is why it is here and on the GatewayClass, not on an agent's own route.

    `internet-facing` places the load balancer in the public subnets, behind a security group that
    admits HTTPS from ingress_allowed_cidrs only, and makes the agents' zone public, delegated from
    ingress_public_zone_id (required), so a workstation in the allowlist resolves and reaches every
    agent attached to this ingress. The authenticating listener rule is still the only thing between
    an allowlisted caller and an agent, so confirm the refusal before any route gets a backend. It
    is what lets the EKS User Guide's ingress steps run from a workstation (see enable_bastion).
  EOT
  type        = string
  default     = "internal"

  validation {
    condition     = contains(["internal", "internet-facing"], var.ingress_scheme)
    error_message = "ingress_scheme must be internal or internet-facing."
  }

  validation {
    condition     = var.ingress_scheme == "internal" || !var.enable_ingress || var.ingress_public_zone_id != ""
    error_message = "ingress_scheme = \"internet-facing\" needs ingress_public_zone_id: the agents' public zone is delegated from it, and ingress_domain_name must be a subdomain of it."
  }
}

variable "enable_ingress_waf" {
  description = <<-EOT
    An AWS WAF web ACL on the ingress load balancer, which inspects every request before the load
    balancer's sign-in runs: the AWS managed rule groups for common exploits, known bad inputs and SQL
    injection, and a per-IP rate rule (ingress_waf_rate_limit_per_ip). The managed rules that inspect
    the request body count rather than block, because an agent's body is a prompt; see
    terraform/modules/waf. On an agent route that validates a JWT at the load balancer, a request
    with no token is refused with 401 before AWS WAF sees it, so there the web ACL inspects only
    requests with a valid token. Needs enable_ingress. To turn ingress off, leave this on: the web ACL stays while the load
    balancer does, and the apply after the load balancer is gone removes it. AWS WAF bills per web ACL, per rule and per
    request.
  EOT
  type        = bool
  default     = false
}

variable "ingress_waf_rate_limit_per_ip" {
  description = "Requests from one source IP address in any 5-minute window before AWS WAF blocks the address, with enable_ingress_waf. Null for no rate rule."
  type        = number
  default     = 2000
}

variable "ingress_idp" {
  description = <<-EOT
    Who a person signs in with at ingress. All three choices create an Amazon Cognito user pool.
    With `cognito` and `oidc` the load balancer authenticates against it with
    `authenticate-cognito`; with `oidc-direct` it calls the provider itself with `authenticate-oidc`.

    - `cognito` (the default): the pool's own users. Create them with
      `aws cognito-idp admin-create-user`; self-service sign-up is off.
    - `oidc`: an existing OpenID Connect provider (Okta, Entra ID, Auth0, Keycloak), named in
      `ingress_oidc` and federated into the pool. The person signs in there; the pool offers no
      password login of its own. The agent receives Cognito's claims and tokens.
    - `oidc-direct`: the same provider, called by the load balancer directly with
      `authenticate-oidc` and no pool in the person's path. The agent receives the provider's own
      claims, and its access token in `x-amzn-oidc-accesstoken` -- the one to choose when an agent
      calls APIs that trust the company's provider. The client secret is synced into the ingress
      namespace, and EKS Auto Mode's managed controller is granted read on that one Secret
      through the `eks:managed` group (gitops/base/templates/47-ingress-oidc.yaml).

    `cognito` and `oidc` run `authenticate-cognito` at the load balancer; `oidc-direct` runs
    `authenticate-oidc`. Every one sends the claims to the agent signed by the load balancer in
    `x-amzn-oidc-data`. It only serves a person at a browser: the flow is a redirect, so a schedule
    or another agent uses `routeAuth: workload` instead.
  EOT
  type        = string
  default     = "cognito"

  validation {
    condition     = contains(["cognito", "oidc", "oidc-direct"], var.ingress_idp)
    error_message = "ingress_idp must be cognito, oidc or oidc-direct. All three create a Cognito user pool; oidc federates an existing provider into it, and oidc-direct has the load balancer call that provider itself."
  }
}

variable "ingress_oidc" {
  description = <<-EOT
    The external provider, when `ingress_idp` is `oidc` or `oidc-direct`. Register the client in
    the provider with the redirect URIs from `terraform output ingress` (`idp_redirect_uris`):
    Cognito's for `oidc`, the load balancer's on every exposed hostname for `oidc-direct`. Take every
    endpoint from the provider's `/.well-known/openid-configuration`; `jwks_uri` is used only by
    `oidc`.

    `client_secret_arn` names a Secrets Manager secret holding the client secret as a plain string.
    Terraform reads it, and it lands in state: for `oidc` Cognito stores it in provider_details, which
    has no write-only form, and for `oidc-direct` it is copied into the secret the cluster syncs.
  EOT
  type = object({
    name                   = optional(string, "oidc")
    issuer                 = string
    authorization_endpoint = string
    token_endpoint         = string
    user_info_endpoint     = string
    jwks_uri               = string
    client_id              = string
    client_secret_arn      = string
    scopes                 = optional(list(string), ["openid", "email", "profile"])
  })
  default = null

  validation {
    condition     = !var.enable_ingress || !contains(["oidc", "oidc-direct"], var.ingress_idp) || var.ingress_oidc != null
    error_message = "ingress_oidc is required when ingress_idp is oidc or oidc-direct: without it there is no provider to federate or to call."
  }
}

variable "enable_chat_ui" {
  description = <<-EOT
    Render the chat UI (gitops/base/templates/60-chat-ui.yaml): a person signs in at ingress
    and talks to the agents in `chat_ui_agents`. Needs enable_ingress, because the UI's only gate
    is the load balancer's sign-in. Its hostname, chat.<ingress_domain_name>, is added to the
    identity provider's callback list here, so it does not have to be listed in ingress_hostnames.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_chat_ui || var.enable_ingress
    error_message = "enable_chat_ui needs enable_ingress: the UI's gate is the load balancer's sign-in, and without ingress the chart refuses to render it."
  }
}

variable "agent_permission_sets" {
  description = <<-EOT
    Named IAM permissions an Agent may attach to its role with spec.permissionSets, for an agent
    that calls an AWS service beyond its model and checkpoints: a DynamoDB table, an S3 prefix, a
    queue. The platform team defines each set; an Agent can only choose names, admission refuses a
    name not defined here or not offered to the Agent's namespace, and every set is also added to
    the agent permissions boundary. Remember the egress side: an agent reaches an AWS endpoint only
    if the cluster egress policy names it (networkPolicy.awsServiceEndpoints in the base chart).

      agent_permission_sets = {
        orders-read = {
          statements = [{ actions = ["dynamodb:GetItem", "dynamodb:Query"],
                          resources = ["arn:aws:dynamodb:us-west-2:111122223333:table/orders"] }]
          namespaces = ["agents"]   # empty: every agent namespace
        }
      }

    See terraform/modules/agent-cluster (agent_permission_sets) for what is refused.
  EOT
  type = map(object({
    statements = list(object({
      sid       = optional(string)
      actions   = list(string)
      resources = list(string)
    }))
    namespaces = optional(list(string), [])
  }))
  default = {}
}

variable "enable_agent_tasks" {
  description = <<-EOT
    Let agents run as tasks (Agent runtime: tasks): work arrives on an SQS queue and each task runs
    in its own sandboxed pod, started by KEDA, for work that outlives a request or arrives as
    events. Installs KEDA (gitops/platform/<path>/templates/13-keda.yaml) and, per agent in task_agents, a
    task queue, a dead-letter queue and a result queue (terraform/modules/agent-tasks), plus the
    permission set tasks-<agent> that lets that agent's role use its own two queues.
  EOT
  type        = bool
  default     = false
}

variable "task_agents" {
  description = "Agents, by name in the first agent namespace, that get task queues with enable_agent_tasks."
  type        = list(string)
  default     = ["research"]
}

variable "task_visibility_timeout_seconds" {
  description = "How long a taken task stays hidden from other pods between the worker's extensions."
  type        = number
  default     = 300

  validation {
    condition     = var.task_visibility_timeout_seconds >= 30 && var.task_visibility_timeout_seconds <= 43200
    error_message = "task_visibility_timeout_seconds must be 30-43200 (SQS's own limits are 0-43200; under 30 leaves the worker no room to extend it)."
  }
}

variable "enable_person_access" {
  description = <<-EOT
    Let an agent act with a person's own authority (terraform/modules/person-access): an ID token a
    person brings is exchanged with STS for one role scoped to that person's data, and the chat UI
    forwards a signed-in person's access token so a tool can verify the person itself. Creates the
    pool's `api` client, an IAM OIDC provider for the pool, a bucket holding each person's data
    under people/<sub>/, and the role. Needs enable_ingress with ingress_idp cognito or oidc, because
    the person's tokens are the ingress user pool's.
    See the agents-identity-on-behalf-of page of the EKS User Guide.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_person_access || (var.enable_ingress && var.ingress_idp != "oidc-direct")
    error_message = "enable_person_access needs enable_ingress with ingress_idp cognito or oidc: the person's tokens are issued by the ingress user pool, and with oidc-direct the load balancer never uses the pool."
  }
}

variable "person_access_agents" {
  description = <<-EOT
    The agents that may act with a person's authority (enable_person_access), by Agent name. Each
    gets its own role, <name>-<agent>-person-data, whose permissions are the intersection of the
    person's prefix and this agent's part of it (people/<sub>/<agent>/), and whose trust requires a
    session named for the agent, so CloudTrail shows which agent acted. An agent not listed gets no
    person role. Remove an agent to revoke it alone.
    See the agents-identity-on-behalf-of page of the EKS User Guide.
  EOT
  type        = list(string)
  default     = ["research"]

  validation {
    condition     = !var.enable_person_access || length(var.person_access_agents) > 0
    error_message = "enable_person_access needs at least one agent in person_access_agents; with none, no agent can act for a person."
  }
}

variable "person_access_delegated_token" {
  description = <<-EOT
    With enable_person_access, the agents' person tools get ONE delegated token instead of the
    person's own token. Each agent asks AgentCore Identity for an on-behalf-of token: the person's
    access token as the subject, the agent's own Cognito client as the actor. The pool signs a token
    with sub the person, aud this stack's tools and act naming the agent, and the tool refuses
    anything else, a person's raw token included. See terraform/modules/person-delegation-agentcore.
    It turns the ingress pool's domain to managed login, which Cognito requires for a token
    exchange. false sends the person's own token to the tool, for development only.
  EOT
  type        = bool
  default     = true
}

variable "person_access_callback_urls" {
  description = "Redirect URIs for your application's sign-in through the pool's hosted UI (authorization code flow) on the person-access api client. Empty: no OAuth flow on that client."
  type        = list(string)
  default     = []
}

variable "person_access_password_auth" {
  description = <<-EOT
    USER_PASSWORD_AUTH on the person-access api client, a public client with no secret. It lets
    the sample's scripts/exercise.sh sign its test users in; with it off, the exercise's delegation
    phase reports itself unchecked. The pool admits only admin-created users, and Cognito throttles
    and locks out repeated failed sign-ins. Turn it off outside a test: an application signs people
    in with the hosted UI's authorization code flow (person_access_callback_urls).
  EOT
  type        = bool
  default     = true
}

variable "chat_ui_agents" {
  description = "The agents the chat UI offers, by Agent name in the reasoning namespace. Each gets its own projected-token source, because a token names one audience."
  type        = list(string)
  default     = ["research"]
}

variable "ingress_hostnames" {
  description = <<-EOT
    Hostnames exposed through ingress, as full names, for the identity provider's callback
    list.

    This cannot be derived. Agents are declared in the cluster rather than in Terraform -- the
    normal case is an empty `agents` map, which is what turns the `Agent` resource definition on --
    so the platform team states the exposed names here. Same shape as `allowed_agent_subjects` and
    `evaluation_service_names`, and for the same reason.

    A hostname missing from this list authenticates and then fails at the browser with a redirect
    URI mismatch, which reads as the agent being broken rather than the client being short a URL.
  EOT
  type        = list(string)
  default     = []
}

variable "enable_network_policy_logs" {
  description = <<-EOT
    With enable_observability, ship every network policy verdict (ACCEPT and DENY, per flow) from
    the nodes to the /aws/eks/<cluster>/network-policy log group, and show the denials on the
    <name>-policy-decisions dashboard next to the gateway's Cedar decisions. The CloudWatch
    Observability add-on's Fluent Bit ships the verdict log alone: agent container logs stay off
    unless enable_container_logs. Records name IP addresses, not pods.
  EOT
  type        = bool
  default     = true
}

variable "enable_cluster_log_types" {
  description = <<-EOT
    Control plane log types sent to CloudWatch Logs.

    `audit` is deliberately NOT in the default: it is the highest-volume stream by a wide margin, and
    on a cluster stood up to try these templates that spend buys nothing. Turn it on for a cluster
    that matters -- `["api", "audit", "authenticator"]` -- because the audit log is how a platform
    team answers which agent called the Kubernetes API, and it is the one record an agent cannot
    delete behind itself.

    Empty disables control plane logging entirely. The log group is created by this configuration
    either way, so it carries a retention and the destroy removes it.
  EOT
  type        = list(string)
  default     = ["api", "authenticator"]
}

variable "cluster_log_retention_days" {
  description = <<-EOT
    Retention on the CONTROL PLANE's log group, `/aws/eks/<cluster>/cluster`. Separate from
    `log_retention_days`, which covers the agent log groups: those carry prompts and tool arguments
    and are kept longer, while this one carries API and authentication records.

    An EKS-created group has no retention at all -- `retentionInDays: None`, never expire -- so this
    is the only place it gets one.
  EOT
  type        = number
  default     = 30
}

variable "enable_evaluations" {
  description = <<-EOT
    Strands Evals test cases as a release gate (gitops/charts/agent-evals): declared cases run on
    demand against deployed agents, graded, with results written to AgentCore Evaluations' result
    log group (/aws/bedrock-agentcore/evaluations/results/<name>-release-gate) so the CloudWatch
    GenAI Observability dashboard shows them beside the online evaluation's.

    Creates the runner's Pod Identity role in terraform/modules/evaluations-aws -- read the agents'
    telemetry log group and aws/spans, write results, no model permission -- and stops excluding
    52-agent-evals.yaml from the root Application. The judge calls the AgentCore Gateway's inference
    endpoint on the runner's projected token. Also keeps prompt and completion content on the
    spans the ADOT collector exports, which it strips otherwise (collector.keepPromptContent in
    gitops/charts/adot-collector), because the judge grades what the agent said from them.

    Independent of enable_online_evaluation, which is AgentCore's managed grading of live traffic.
    The two answer different questions: did this release regress before it shipped, and how is
    what shipped doing.
  EOT
  type        = bool
  default     = false

  validation {
    # The runner's subject has to be admitted by the gateway, which admits one subject or all.
    condition     = !var.enable_evaluations || length(var.allowed_agent_subjects) == 0
    error_message = "enable_evaluations needs allowed_agent_subjects to be empty. The AgentCore Gateway admits exactly one subject or every subject its audience accepts, and the evaluation judge is a second subject (system:serviceaccount:agent-evals:agent-evals), so with one agent pinned the judge's every model call is refused."
  }

  validation {
    condition     = !var.enable_evaluations || (var.enable_gateway && var.enable_observability)
    error_message = "enable_evaluations needs enable_gateway (the judge calls the gateway's inference endpoint) and enable_observability (the runner reads the agents' sessions from the spans the collector records)."
  }
}

variable "evaluation_judge_model_id" {
  description = <<-EOT
    The model name the evaluation judge sends to the gateway's inference endpoint. Empty uses
    gateway_model_id, the agents' own. Must be one the gateway serves:
    GET <gateway>/inference/v1/models lists them.
  EOT
  type        = string
  default     = ""
}



variable "agentcore_consent" {
  description = <<-EOT
    The session-binding half of AgentCore Gateway's OAuth consent (3LO), keyed by a short name.
    AgentCore runs the consent and keeps the token in AgentCore Identity's vault, but redirects the
    browser to a return URL that must call CompleteResourceTokenAuth with the identity that started
    the flow -- here the agent's own service-account token, which no browser holds. This deploys the
    consent receiver (gitops/charts/consent-receiver) to do that for the named agent.

      agent      the Agent the consent is for (its service account in agent_namespaces[0])
      tool       a tool on the authorization-code target, called to start the consent, e.g.
                 githuboauth___getAuthenticatedUser
      tool_arguments  its arguments, if it needs any

    Name <consent_public_base_url>/complete/<key> as the OAuth target's credential.default_return_url.
    Open <consent_public_base_url>/connect/<key> through scripts/consent.sh: the receiver calls the
    tool as the agent, sends the browser to the authorization URL, and completes the binding with the
    same token (AgentCore refuses any other). The token is keyed by that agent, not by a person.
  EOT
  type = map(object({
    agent          = string
    tool           = string
    tool_arguments = optional(map(string), {})
  }))
  default = {}
}

variable "consent_public_base_url" {
  description = "Where AgentCore sends the browser after consent: the forwarded localhost port of the consent receiver."
  type        = string
  default     = "http://localhost:8765"
}

variable "ecr_force_delete" {
  description = "Delete the agent images with the ECR repositories when a repository is deleted -- by terraform destroy, or by an apply that renames or drops one. Off by default: an apply must not be able to drop images as a side effect. Set true on a disposable stack, and terraform destroy needs no separate image cleanup (scripts/teardown.sh step 8)."
  type        = bool
  default     = false
}

variable "checkpoint_bucket_force_destroy" {
  description = "Delete every checkpoint object and version with the bucket when it is deleted -- by terraform destroy, or by an apply that renames it. Off by default: the bucket is agents' durable state. Set true only on a disposable stack, and terraform destroy needs no separate bucket cleanup (scripts/teardown.sh step 9)."
  type        = bool
  default     = false
}

variable "enable_checkpoints" {
  description = <<-EOT
    Durable state in Amazon S3: one versioned bucket with a prefix per agent, each agent's role scoped
    to its own prefix, and the egress rule to that bucket's own host. The reference agent saves each
    session's conversation there (Strands' S3SessionManager), so any replica, or a restarted pod,
    continues it. Off in the base: an agent with no bucket keeps no conversation between turns,
    unless it is a Sandbox with a workspace volume, where it saves to /workspace instead.
  EOT
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access" {
  description = "Open the cluster's API endpoint to the internet, restricted to cluster_endpoint_public_access_cidrs, so kubectl and the scripts can run from your workstation instead of the bastion. Off by default: the endpoint is private. Requests are still authenticated with IAM and authorized by access entries."
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Source CIDRs allowed to reach the public API endpoint. Empty, the default, means the public IPv4 address of the machine running Terraform, as a /32, looked up from https://checkip.amazonaws.com and https://api.ipify.org on each plan (both, when they differ); apply again from a new address to move it. Behind a corporate network or VPN whose traffic leaves through a pool of addresses, name the pool's CIDRs instead, because the lookup can miss some of them. 0.0.0.0/0 is refused."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.cluster_endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 opens the cluster's API endpoint to the internet. Name the CIDRs that need it, or leave the list empty for this machine's address."
  }
}

variable "vpc_endpoints" {
  description = <<-EOT
    AWS services the cluster reaches through an interface VPC endpoint instead of the NAT gateway
    and the service's public endpoint. Each has private DNS, so nothing in the cluster changes its
    URLs or network policy. Keys:
      agents     agentcore-gateway (with enable_gateway; its policy admits only this stack's
                 gateway), bedrock-runtime, agentcore (AgentCore Memory), s3vectors, sts,
                 secretsmanager, sqs (task queues, with enable_agent_tasks)
      nodes      ecr-api, ecr-dkr, eks-auth (Pod Identity)
      tokens     oidc-eks (the cluster's OIDC issuer, which every service account token check
                 reads)
      telemetry  logs, monitoring, xray
      bastion    ssm, ssmmessages, ec2messages; eks, elasticloadbalancing and bedrock for the
                 scripts run there (the EKS API, load balancer and inference profile lookups)
    With enable_gateway and agentcore listed, agentcore-gateway is added for you: the agentcore
    endpoint's private DNS zone covers every gateway's host name, which then resolves only through
    the gateway's own endpoint. With eks listed, oidc-eks is added for the same reason: the eks
    endpoint's zone covers the OIDC issuer's host name.
    S3 already has a gateway endpoint. Route 53 (ExternalDNS) has no VPC endpoint. Each interface
    endpoint is billed per hour in each Availability Zone. Created only when the stack creates the
    VPC, or when vpc_id and vpc_cidr are set.
  EOT
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.vpc_endpoints : contains(["agentcore-gateway", "bedrock-runtime", "agentcore", "s3vectors", "sts", "secretsmanager", "sqs", "ecr-api", "ecr-dkr", "eks-auth", "oidc-eks", "logs", "monitoring", "xray", "ssm", "ssmmessages", "ec2messages", "eks", "elasticloadbalancing", "bedrock"], e)])
    error_message = "Supported vpc_endpoints: agentcore-gateway, bedrock-runtime, agentcore, s3vectors, sts, secretsmanager, sqs, ecr-api, ecr-dkr, eks-auth, oidc-eks, logs, monitoring, xray, ssm, ssmmessages, ec2messages, eks, elasticloadbalancing, bedrock."
  }

  validation {
    condition     = !contains(var.vpc_endpoints, "agentcore-gateway") || var.enable_gateway
    error_message = "vpc_endpoints \"agentcore-gateway\" needs enable_gateway = true."
  }
}
