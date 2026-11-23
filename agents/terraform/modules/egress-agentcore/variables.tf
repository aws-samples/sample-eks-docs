variable "name" {
  description = "Name prefix, normally the cluster name. AgentCore resource names take underscores rather than dashes, and the module converts for you."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster the agents run on. Used in descriptions only; the gateway is not a cluster resource."
  type        = string
}

variable "oidc_issuer_url" {
  description = <<-EOT
    The cluster's OIDC issuer, from the cluster_oidc_issuer_url output of ../agent-cluster.

    This is what the gateway validates the agent's service account token
    against. It is per-cluster, so the gateway admits agents from one cluster.
  EOT
  type        = string
}

variable "allowed_agent_subjects" {
  description = <<-EOT
    AT MOST ONE service account subject the gateway admits, for example
    "system:serviceaccount:agents:research-agent". Empty is valid and is the right answer for more
    than one agent.

    One, not a list, because that is all the gateway can express: EQUALS is the only operator a
    STRING claim accepts, and `sub` in a projected service account token is a string. Both
    multi-value operators demand a STRING_ARRAY claim type, and a gateway configured that way is
    created successfully and then refuses every token. A second rule on `sub` is rejected as a
    duplicate claim name.

    Do not pass a namespace prefix -- it is rejected by the regex below, and it would not work
    anyway for the same reason. With more than one agent, leave this empty and separate the agents
    with the egress network policy, which decides which namespaces can reach the gateway at all,
    and with the policy engine. The agents-gateway page of the EKS User Guide covers this limit.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_agent_subjects) <= 1
    error_message = "At most one subject. The AgentCore Gateway admits exactly one service account subject per gateway: EQUALS is the only operator a STRING claim accepts, CONTAINS and CONTAINS_ANY both require a STRING_ARRAY claim type that a JWT `sub` never has, and a second rule on `sub` is rejected as a duplicate claim name. For more than one agent, leave this empty and separate the agents with the egress network policy and the policy engine instead -- see the agents-gateway page of the EKS User Guide."
  }

  validation {
    condition     = alltrue([for s in var.allowed_agent_subjects : can(regex("^system:serviceaccount:[a-z0-9-]+:[a-z0-9-]+$", s))])
    error_message = "Each subject must be a fully qualified service account: system:serviceaccount:<namespace>:<name>. A namespace prefix admits every service account a tenant creates in that namespace."
  }

  # NO PREFIX-RELATIONSHIP CHECK, and none is needed. CONTAINS_ANY matching would make a subject
  # that is a prefix of another admit the longer one's agent too, but that cannot arise: the gateway
  # accepts at most one subject, enforced above, so there is never a second subject to be a prefix
  # of.
}

variable "allowed_audiences" {
  description = "Audiences the gateway accepts on an inbound token. Name the gateway, so a token minted for another relying party is not accepted here."
  type        = list(string)
  default     = []
}

variable "mcp_instructions" {
  description = "Instructions the gateway returns to an MCP client, describing what this tool surface is for."
  type        = string
  default     = "Tools and credentials for agents running on Amazon EKS. Every call is attributed to the calling agent's identity."
}

variable "mcp_search_type" {
  description = "Tool search mode. SEMANTIC lets an agent find the right tool without carrying every definition in its prompt, which is the capability this gateway adds over the self-managed one."
  type        = string
  default     = "SEMANTIC"

  validation {
    condition     = contains(["SEMANTIC", "NONE"], var.mcp_search_type)
    error_message = "mcp_search_type must be SEMANTIC or NONE."
  }
}

variable "enable_policy_engine" {
  description = "Create an AgentCore policy engine and attach it to the gateway. On by default: without it the gateway routes and brokers but decides nothing about which tool a caller may invoke."
  type        = bool
  default     = true
}

variable "policy_engine_mode" {
  description = "ENFORCE or LOG_ONLY. ENFORCE by default. In LOG_ONLY the engine records each decision and denies nothing -- a platform left there records the call it was there to refuse. The gateway API accepts only LOG_ONLY and ENFORCE, not AUDIT."
  type        = string
  default     = "ENFORCE"

  validation {
    condition     = contains(["ENFORCE", "LOG_ONLY"], var.policy_engine_mode)
    error_message = "policy_engine_mode must be ENFORCE or LOG_ONLY, the gateway API's values. AUDIT is refused at apply."
  }
}

variable "policy_validation_mode" {
  description = "FAIL_ON_ANY_FINDINGS or IGNORE_ALL_FINDINGS. The first by default: ignoring findings creates the policy anyway, which leaves an enforcement point holding a rule that silently matches nothing."
  type        = string
  default     = "FAIL_ON_ANY_FINDINGS"

  validation {
    condition     = contains(["FAIL_ON_ANY_FINDINGS", "IGNORE_ALL_FINDINGS"], var.policy_validation_mode)
    error_message = "policy_validation_mode must be FAIL_ON_ANY_FINDINGS or IGNORE_ALL_FINDINGS."
  }
}

variable "cedar_policies" {
  description = <<-EOT
    Cedar policies attached to the policy engine, keyed by name. Keep the statements in Git next to
    this configuration, not in the console, so a platform team can review them before they take
    effect.

    WRITE `{{gateway_arn}}` WHERE THE GATEWAY'S ARN GOES. It is substituted at apply time. You
    cannot write the ARN yourself: it carries a service-generated suffix that does not exist until
    the gateway has been created.

    THE RULES THAT DECIDE WHETHER A STATEMENT IS EVEN ACCEPTED, none of which are obvious:

      - There is NO WILDCARD ACTION in Cedar. Each action is named exactly, as
        `AgentCore::Action::"<TargetName>___<ToolName>"`. To cover a group of tools, point at the
        gateway TARGET, which acts as an action group: `action in AgentCore::Action::"<TargetName>"`.
      - Naming any specific action REQUIRES a specific gateway:
        `resource == AgentCore::Gateway::"{{gateway_arn}}"`. A type check is rejected there.
      - A type check (`resource is AgentCore::Gateway`) or a bare `resource` is allowed ONLY for a
        policy covering any action -- which is exactly what a deny-by-default `forbid` is, so that
        one needs no ARN at all.
      - Action names depend on the target type: MCP is `<TargetName>___<ToolName>`, an AgentCore
        Runtime target is `<TargetName>___<METHOD>:/invocations`, and an HTTP proxy target is
        `<TargetName>___<METHOD>:<uri>`.

    Cedar decides on the CURRENT request. For a rule that depends on what already happened in the
    session -- an approval before an action, a call count in a window, a running total under a
    budget -- that is a TEMPORAL policy, written in Dogwood, a strict superset of Cedar. See
    enable_temporal_policies, and note that this provider's policy resource exposes only the
    `cedar` definition, so a Dogwood statement goes in through the service API rather than
    through this variable.
  EOT
  type = map(object({
    description = string
    statement   = string
    # Overrides policy_validation_mode for this policy alone. Only the generated baseline forbid
    # sets it: the validator calls any forbid that would cover tools no permit covers yet "Overly
    # Restrictive", which is what a baseline deny is for.
    validation_mode = optional(string)
  }))
  default = {}
}

variable "lambda_target_arns" {
  description = "Lambda functions exposed as gateway targets, so the gateway's role may invoke them. Keep it to the functions that are actually targets."
  type        = list(string)
  default     = []
}

variable "inference_model_arns" {
  description = <<-EOT
    Model ARNs the gateway itself may invoke through the `bedrock:` actions, which is semantic tool
    search. Guardrail checks come from guardrail_policies instead.

    THIS IS NOT A LIST OF THE MODELS AN AGENT CAN REACH THROUGH AN INFERENCE TARGET, and it cannot
    be made into one. A call to the inference connector is authorized by
    `bedrock-mantle:CreateInference` against `project/default` -- a different service namespace, one
    project per account and Region, and no model anywhere in the resource. The service says so when
    the action is missing:

      User: arn:aws:sts::<acct>:assumed-role/<name>-agentcore-gateway/gateway-session-invocation
      is not authorized to perform: bedrock-mantle:CreateInference on resource:
      arn:aws:bedrock-mantle:<region>:<acct>:project/default

    So CreateInference is binary: the gateway serves every model the connector advertises, or none
    of them. With it granted and `bedrock:InvokeModel` scoped to one foundation model, a caller
    holding only a projected token still gets completions from every other model the connector
    advertises. With it withheld, every model is refused, including the one the `bedrock:`
    statement allows.

    The `bedrock:` actions above are still the control for what the gateway calls through the
    `bedrock:` namespace, which is semantic tool search.
    `GET /inference/v1/models` needs only bedrock-mantle:ListModels and advertises every model to
    every admitted caller, so the catalogue is bounded by discovery rather than by this list.

    To bound which model an agent reaches, use one of these instead:

      a gateway rule       `routeToTarget.staticRoute.model` REPLACES the model in the request. It
                           applies to every caller, because a rule's conditions are HTTP-target
                           paths or IAM principals and a JWT-authenticated agent is neither.
      the policy engine    per agent, but per TARGET rather than per model --
                           `action in AgentCore::Action::"<target>"`.
      a rate limit         per model, with `qualifiedModelId` as a dimension key, and per caller
                           with `$.context.jwt.sub`. A budget rather than an allowlist.

    On the open source path the gateway assumes the AGENT's role and signs as it, so there the
    agent's own `bedrock:` scope is the control and this variable is not involved.
  EOT
  type        = list(string)
  default     = []
}

variable "api_key_providers" {
  description = <<-EOT
    Credential providers for services that issue only a static key. The gateway holds the key and
    attaches it per caller, so the agent never sees it, and these are the long-lived secrets whose
    removal from the pod carries most of the security value.

    secret_id names an existing Secrets Manager secret; this module never sets its value.
  EOT
  type = map(object({
    secret_id = string
    json_key  = string
  }))
  default = {}
}

variable "oauth2_providers" {
  description = <<-EOT
    Credential providers for services that require the person's own consent. The person approves
    once in a browser and the gateway holds the resulting token per user.

    vendor is one of GithubOauth2, SlackOauth2, GoogleOauth2, AtlassianOauth2, MicrosoftOauth2 or
    CustomOauth2. tenant_id applies to Microsoft; discovery_url applies to Custom.

    The client secret is read from an existing Secrets Manager secret. Terraform never holds it.
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

  validation {
    condition = alltrue([
      for k, v in var.oauth2_providers :
      contains(["GithubOauth2", "SlackOauth2", "GoogleOauth2", "AtlassianOauth2", "MicrosoftOauth2", "CustomOauth2"], v.vendor)
    ])
    error_message = "vendor must be one of GithubOauth2, SlackOauth2, GoogleOauth2, AtlassianOauth2, MicrosoftOauth2, CustomOauth2."
  }

  validation {
    condition = alltrue([
      for k, v in var.oauth2_providers :
      v.vendor != "MicrosoftOauth2" || v.tenant_id != null
    ])
    error_message = "A MicrosoftOauth2 provider needs tenant_id."
  }

  validation {
    condition = alltrue([
      for k, v in var.oauth2_providers :
      v.vendor != "CustomOauth2" || v.discovery_url != null
    ])
    error_message = "A CustomOauth2 provider needs discovery_url."
  }
}

variable "mcp_server_targets" {
  description = <<-EOT
    Remote MCP servers agents reach through the gateway.

    credential.kind is "api_key", "oauth" or "gateway_iam_role". For api_key and oauth, provider
    names a key in var.api_key_providers or var.oauth2_providers.

    NO PASSTHROUGH AND NO CALLER CREDENTIALS. AgentCore Gateway refuses JWT_PASSTHROUGH on an MCP
    server target ("MCP server target does not support JWT_PASSTHROUGH credential provider
    type"), and its outbound-authorization table lists neither token
    passthrough nor caller IAM credentials for MCP server or OpenAPI targets: both are for
    AgentCore Runtime (HTTP) targets. So the agent's own token does not reach the server, and
    the server cannot verify which agent called. On this gateway the agent side is decided by Cedar,
    on the principal (the agent's token's sub) per tool; a person's token can reach the tool as an
    allowlisted request header, which the tool verifies itself.

    private_endpoint is how a gateway reaches a target that is NOT on the public internet, which
    includes anything in your cluster: AgentCore runs outside the VPC and cannot reach a ClusterIP
    Service. Supplying it has AgentCore place an ENI in the subnets you name, so the target's
    address has to be routable from them -- an internal load balancer in front of the Service, or a
    pod address if your CNI gives pods VPC addresses. A ClusterIP will not do.

    listing_mode is DEFAULT or DYNAMIC. DEFAULT by default: DYNAMIC has the gateway list whatever
    the upstream offers at call time, so the agent's tool catalogue changes whenever the upstream
    does, with no review in between.
  EOT
  type = map(object({
    description  = string
    endpoint     = string
    listing_mode = optional(string, "DEFAULT")

    # Reachability for a target inside a VPC. Omit for a target on the public internet.
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
      # AUTHORIZATION_CODE only: where AgentCore sends the browser after consent, which must
      # complete the session binding (CompleteResourceTokenAuth). On this stack that is the consent
      # receiver's /complete/<key> (gitops/charts/consent-receiver).
      default_return_url = optional(string)
      service            = optional(string)
    })
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.mcp_server_targets :
      contains(["api_key", "oauth", "gateway_iam_role"], v.credential.kind)
    ])
    error_message = "credential.kind must be api_key, oauth or gateway_iam_role: AgentCore Gateway refuses token passthrough and caller IAM credentials on an MCP server target."
  }

  validation {
    condition = alltrue([
      for k, v in var.mcp_server_targets :
      v.credential.kind == "gateway_iam_role" || v.credential.provider != null
    ])
    error_message = "An api_key or oauth credential needs provider set to a key in api_key_providers or oauth2_providers."
  }

  validation {
    condition = alltrue([
      for k, v in var.mcp_server_targets : contains(["DEFAULT", "DYNAMIC"], v.listing_mode)
    ])
    error_message = "listing_mode must be DEFAULT or DYNAMIC."
  }

  validation {
    condition = alltrue([
      for k, v in var.mcp_server_targets :
      startswith(v.endpoint, "https://")
    ])
    error_message = "An MCP server endpoint must be https. A plaintext endpoint means the brokered credential leaves the gateway in the clear."
  }
}

variable "mcp_supported_versions" {
  description = "MCP protocol versions the gateway accepts. Include 2025-11-25 for authorization-code (3LO) targets: their consent URL is delivered by URL elicitation, which needs it."
  type        = list(string)
  default     = ["2025-03-26", "2025-06-18", "2025-11-25"]
}

variable "open_api_targets" {
  description = "OpenAPI services exposed to agents as MCP tools. Set exactly one of schema_s3_uri or schema_inline."
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
      # AUTHORIZATION_CODE only: where AgentCore sends the browser after consent, which must
      # complete the session binding (CompleteResourceTokenAuth). On this stack that is the consent
      # receiver's /complete/<key> (gitops/charts/consent-receiver).
      default_return_url = optional(string)
      service            = optional(string)
    })
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.open_api_targets :
      (v.schema_s3_uri == null) != (v.schema_inline == null)
    ])
    error_message = "Set exactly one of schema_s3_uri or schema_inline on each OpenAPI target."
  }

  validation {
    condition = alltrue([
      for k, v in var.open_api_targets : contains(["api_key", "oauth", "gateway_iam_role"], v.credential.kind)
    ])
    error_message = "credential.kind must be api_key, oauth or gateway_iam_role: AgentCore Gateway lists neither token passthrough nor caller IAM credentials for an OpenAPI target."
  }
}

variable "gateway_kms_key_arn" {
  description = <<-EOT
    Customer-managed KMS key for the gateway. Null uses the service default.

    Setting it also grants the gateway's role kms:Encrypt on the key, which is not optional: an
    update and a DELETE both encrypt, so a gateway whose role cannot encrypt with its own key
    cannot be changed or removed. The key policy has to allow the gateway's role as well -- this
    module writes the role side, and a key whose own policy excludes that role fails the same way.

    The key cannot be changed afterwards. An update that omits it is read as removing it and is
    refused with "KMS key cannot be updated for an existing gateway", so every update to a gateway
    carrying a customer-managed key has to re-state it.
  EOT
  type        = string
  default     = null
}

variable "policy_kms_key_arn" {
  description = "Customer-managed KMS key for the policy engine. Null uses the service default."
  type        = string
  default     = null
}

variable "credential_kms_key_arn" {
  description = "KMS key the credential secrets are encrypted with, if customer-managed. The gateway's role needs kms:Decrypt on it."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "inference_targets" {
  description = <<-EOT
    Model providers the gateway fronts as inference targets, keyed by target name. An inference
    target is what makes this gateway a model egress point rather than only a tool broker: the
    gateway exposes one OpenAI-compatible endpoint at /inference/v1, routes on the `model` field in
    the request body, and holds the provider credential so the agent does not.

    This is the piece that lets an agent on this path reach a model at all. Without an inference
    target the gateway serves tools only, and an agent whose egress policy permits the gateway and
    nothing else has nowhere to send a model call.

    PICK A MODEL THAT SERVES THE OPENAI DIALECT. The connector advertises its own catalogue with
    its own ids (bedrock/<provider>.<model>), so a Bedrock model id or inference profile id is not
    valid here and returns 404. More importantly, not every model serves every dialect:
    bedrock/anthropic.claude-haiku-4-5 refuses /v1/chat/completions and requires /v1/messages with
    an anthropic_version field, which an OpenAI-SDK agent does not send. An agent built on this
    stack's OpenAI-compatible contract therefore needs a model that serves the OpenAI dialect --
    bedrock/deepseek.v3.1 does. List what a gateway actually serves:

      curl -H "Authorization: Bearer $TOKEN" https://<gateway>/inference/v1/models

    connector_id is one of the built-in connectors:
      bedrock-mantle   Amazon Bedrock, OpenAI-compatible dialect (chat completions, messages).
                       This is the one an OpenAI-SDK or Strands agent wants.
      bedrock-runtime  Amazon Bedrock, native InvokeModel wire format.
      openai           OpenAI directly. Needs an api_key credential.
      anthropic        Anthropic directly. Needs an api_key credential.

    credential.kind is gateway_iam_role for Bedrock -- the gateway signs with its own role -- or
    api_key for a third-party provider, naming a key in api_key_providers.

    WHICH MODELS THE TARGET WILL SERVE IS NOT BOUNDED BY inference_model_arns. The connector
    authorizes on `bedrock-mantle:CreateInference` against a project arn, so every model it
    advertises is reachable by any admitted caller. That variable's documentation names the three
    surfaces that do bound it.
  EOT

  type = map(object({
    connector_id = string
    description  = optional(string)
    credential = object({
      kind           = string
      provider       = optional(string)
      location       = optional(string, "HEADER")
      parameter_name = optional(string, "Authorization")
      prefix         = optional(string, "Bearer ")
    })
  }))

  default = {
    bedrock = {
      connector_id = "bedrock-mantle"
      description  = "Amazon Bedrock, OpenAI-compatible dialect."
      credential   = { kind = "gateway_iam_role" }
    }
  }

  validation {
    condition = alltrue([
      for t in values(var.inference_targets) :
      contains(["bedrock-mantle", "bedrock-runtime", "openai", "anthropic"], t.connector_id)
    ])
    error_message = "connector_id must be one of: bedrock-mantle, bedrock-runtime, openai, anthropic."
  }

  validation {
    condition = alltrue([
      for t in values(var.inference_targets) :
      contains(["gateway_iam_role", "api_key"], t.credential.kind)
    ])
    error_message = "inference target credential.kind must be gateway_iam_role or api_key."
  }
}

variable "allowed_oauth_client_ids" {
  description = <<-EOT
    OAuth client_id values the gateway accepts, for a caller that is a registered OAuth
    application.

    Leave empty for Kubernetes workloads. A projected service account token has no client_id claim,
    so a value here matches nothing and the gateway refuses every request with 403
    insufficient_scope. Per-agent identity comes from var.allowed_agent_subjects, which is matched
    on the `sub` claim instead.
  EOT
  type        = list(string)
  default     = []
}

variable "lambda_targets" {
  description = <<-EOT
    MCP tools backed by a Lambda function, keyed by target name.

    This is the shape to reach for when the tool does not already exist as a service: the gateway
    exposes each entry as an MCP tool, invokes the function with the tool name and arguments, and
    returns its result. The function needs no public endpoint, no VPC and no credential of its own
    -- the gateway signs the invoke with its own role, which is what var.lambda_target_arns grants.

    It is also the answer to "the MCP server does not run on EKS". A gateway outside the cluster
    cannot reach a ClusterIP Service, so an in-cluster MCP server needs a private endpoint and a
    VPC-routable address; a Lambda target needs neither and is reachable by construction.

    tool_schema is the tool catalogue, and it is authored here rather than discovered: the gateway
    advertises exactly these tools, so adding one is a reviewable change rather than something an
    upstream can alter underneath the agent.
  EOT

  type = map(object({
    description  = string
    function_arn = string
    tool_schema = list(object({
      name        = string
      description = string
      # The tool's arguments. `required` is per-property here, not a list on the schema, which is
      # the shape the CRD takes.
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

variable "enable_temporal_policies" {
  description = <<-EOT
    Grant the gateway what a TEMPORAL policy needs, and expect callers to supply a policy session.

    Temporal policies -- written in Dogwood, a strict superset of Cedar -- decide on what has
    already happened in a session rather than on the current request alone: an approval before a
    transfer, a call count in a window, a running total under a budget. They cost two things beyond
    an ordinary Cedar policy, and both fail late:

      1. The gateway mints a Workload Access Token to carry the caller's session identity, so its
         role needs bedrock-agentcore:GetWorkloadAccessToken. Without it the tool call fails at the
         mint step, after the policy is written and attached.
      2. EVERY request must carry a policy session id in the
         x-amzn-bedrock-agentcore-policy-session-id header. The gateway does NOT generate one, and
         omitting it while a temporal policy is attached is a validation error -- so turning this on
         is a change to how agents call the gateway, not only to the policy set.

    Leave it false unless a policy actually references the past.
  EOT
  type        = bool
  default     = false
}

variable "dogwood_policies" {
  description = <<-EOT
    TEMPORAL policies, written in Dogwood. Keyed by name, same shape as cedar_policies, and
    `{{gateway_arn}}` is substituted the same way.

    APPLIED WITH THE AWS CLI RATHER THAN THE PROVIDER, because of a provider gap rather than a
    design choice. The service takes a policy as one of two definitions, and the AWS provider's
    aws_bedrockagentcore_policy resource exposes only the first:

      definition.cedar.statement    strict Cedar. This is what cedar_policies uses.
      definition.policy.statement   the Dogwood dialect, which is where `when temporal { }` goes.

    A temporal statement in the cedar field is rejected outright with `unexpected token
    'temporal'`, so there is no way to smuggle one through. Entries here are therefore created on
    apply with `aws bedrock-agentcore-control create-policy` through `definition.policy`, where the
    same statement that the cedar field rejects reaches ACTIVE. That needs the aws CLI on the host
    running terraform.

    WHAT A TEMPORAL POLICY COSTS:

      - enable_temporal_policies must be true, so the gateway may mint the Workload Access Token
        that carries session identity. Without it the call fails at the mint step, long after the
        policy looks correctly installed.
      - Every request must carry `x-amzn-bedrock-agentcore-policy-session-id`. The gateway does not
        generate it, and a request without it fails validation once ANY temporal policy is attached
        -- so this changes how agents call the gateway, not just the policy set.
      - Adding or changing a temporal policy invalidates open sessions; the next request on one
        returns HTTP 409 ConflictException.

    THREE SYNTAX RULES THAT THE SERVICE ENFORCES AND NOTHING WARNS YOU ABOUT:

      1. A policy scoped with `action in` CANNOT carry temporal conditions. The policy is created
         and then lands in CREATE_FAILED with the fix spelled out: move the membership test into a
         `when` clause. So the group form is
            permit(principal == AgentCore::OAuthUser::"system:serviceaccount:agents:<agent>",
                   action, resource == AgentCore::Gateway::"{{gateway_arn}}")
            when { action in AgentCore::Action::"<target>" }
            when temporal { ... };
         or scope to one tool with `action == AgentCore::Action::"<target>___<tool>"`.
      2. Every temporal predicate MUST include `eventResource: resource`. Omitting it is rejected
         with "temporal predicates do not constrain the matched event to the current request's
         resource".
      3. Ordered comparisons (`<`, `<=`, `>`, `>=`) require an INTEGER on both sides -- a decimal or
         a string is rejected at create time. Equality works on any matching types. So model
         anything a temporal rule totals or thresholds as an integer, including money in minor
         units.

    AND ONE SEMANTIC RULE that makes policies silently never match: only a PERMITTED action records
    a `response` event. A denied action records an `error` event instead, so a temporal rule that
    waits for a prerequisite needs a plain permit for that prerequisite as well, or the prerequisite
    is denied, never recorded, and the condition can never become true.
  EOT
  type = map(object({
    description = string
    statement   = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.dogwood_policies :
      !can(regex("action\\s+in\\s", v.statement)) || !can(regex("when\\s+temporal", v.statement))
    ])
    error_message = "A policy scoped with `action in` cannot carry temporal conditions: the service accepts it and then fails the create. Use a wildcard `action` scope and move the membership test into a `when { action in AgentCore::Action::\"<target>\" }` clause, or scope to a single tool with `action == `."
  }

  validation {
    condition = alltrue([
      for k, v in var.dogwood_policies :
      !can(regex("when\\s+temporal", v.statement)) || can(regex("eventResource\\s*:\\s*resource", v.statement))
    ])
    error_message = "Every temporal predicate must include `eventResource: resource`, which ties the matched event to the resource in the policy's scope. Without it the service rejects the policy."
  }
}

variable "guardrail_policies" {
  description = <<-EOT
    AgentCore Policy statements whose conditions call a guardrail (`when guardrails { ... }`), keyed by
    name, with `{{gateway_arn}}` where the gateway's ARN goes. Applied through the aws CLI like
    dogwood_policies, because the provider's policy resource takes only plain Cedar. Each is created
    ACTIVE with IGNORE_ALL_FINDINGS: the validator can't read a guardrail condition, so it reports a
    forbid gated only by one as "Overly Restrictive" and refuses it otherwise. Any of these turns on
    bedrock:InvokeGuardrailChecks on the gateway's role.
  EOT
  type = map(object({
    description = string
    statement   = string
  }))
  default = {}
}

variable "dogwood_enforcement_mode" {
  description = "Enforcement mode for the temporal policies: LOG_ONLY records what each would have denied without denying it, ACTIVE enforces. LOG_ONLY first, deliberately -- a rule over history is worth watching before it refuses anyone."
  type        = string
  default     = "LOG_ONLY"
  validation {
    condition     = contains(["LOG_ONLY", "ACTIVE"], var.dogwood_enforcement_mode)
    error_message = "dogwood_enforcement_mode must be LOG_ONLY or ACTIVE."
  }
}

variable "enable_gateway_logs" {
  description = "Deliver the gateway's APPLICATION_LOGS to CloudWatch Logs. On by default: it is where a failed tool call's real reason is recorded."
  type        = bool
  default     = true
}

variable "gateway_log_retention_days" {
  description = "Retention on the gateway's application log group. It carries request bodies, so tool arguments."
  type        = number
  default     = 30
}
