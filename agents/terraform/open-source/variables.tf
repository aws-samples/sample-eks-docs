variable "name" {
  description = "Name prefix for the cluster and every resource in this configuration."
  type        = string
  default     = "agents-oss"
}

variable "region" {
  description = "AWS Region. One Region per configuration: the gateway, the models and the cluster all live in it."
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
  description = "Private subnets for the cluster and its nodes. Leave empty to have this configuration create them. These must be PRIVATE subnets: nothing in this stack is meant to be reachable from the internet."
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
  description = "Namespaces agents run in. Scopes the ACK capability role's permissions by the namespace session tag."
  type        = list(string)
  default     = ["agents"]
}

variable "ecr_repository_names" {
  description = <<-EOT
    ECR repositories created for agent images. Unset (null), the list follows the components that
    are on: the base gets agents/reasoning-direct (the agent that calls Amazon Bedrock itself),
    agents/execution (the network-less tier), agents/reasoning and agents/mcp-server, whether or not
    the gateway is on, so turning it off never plans the deletion of a repository holding images;
    the chat UI, evaluations and the consent receiver add theirs. Set a list to choose them yourself.

    Derived rather than everything up front, and never fewer than the components need: an example
    whose repository this configuration did not create fails late, as an ImagePullBackOff on a
    cluster that otherwise came up clean.
  EOT
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
  description = "Customer-managed KMS key used for the checkpoint bucket and the brokered credentials. One key for the platform is a reasonable start; separate them where the organization separates who may read agent data from who may read agent credentials."
  type        = string
  default     = null
}

variable "organization_id" {
  description = "AWS Organizations ID for the checkpoint bucket's data perimeter. Null restricts it to this account alone, which is stricter."
  type        = string
  default     = null
}

variable "mesh_trust_domain" {
  description = <<-EOT
    SPIFFE trust domain the mesh issues agent identities under.

    This is the mesh's own per-cluster domain, not a domain the customer owns,
    so an identity issued here cannot be presented to a system outside the cluster. Stated here rather than only
    in the docs, because this variable is where a reader forms the wrong impression.
  EOT
  type        = string
  default     = "cluster.local"
}

variable "gateway_audience" {
  description = <<-EOT
    The audience the agent's projected service account token is minted for, and the only audience
    AgentGateway accepts on an inbound token.

    This is the agent's whole credential at the gateway. It grants nothing anywhere -- it only names
    the caller -- and the gateway assumes the agent's own IAM role to sign the outbound call. A
    narrow audience is what stops a token the agent obtained for some other relying party from
    being usable here, because a workload may request its identity as a JWT naming any audience and
    nothing checks at fetch time.

    Changing it is safe but has to be one change: it is rendered into terraform-values.yaml and read
    by both the base chart, which mints the token, and agentgateway-config, which checks it. A
    mismatch between the two fails closed with no error on either object -- the pod is Running, the
    policies are Accepted, and every model call is rejected for an unverifiable identity.
  EOT
  type        = string
  default     = "agentgateway"

  validation {
    condition     = length(var.gateway_audience) > 0
    error_message = "An empty audience mints the agent a token for the Kubernetes API server instead, which the gateway rejects."
  }
}

variable "enable_mesh_private_ca" {
  description = "Create an AWS Private CA for the mesh instead of using the mesh's own self-signed CA. Off by default; it bills per month and per certificate, and on this stack it signs one every time an agent presents mTLS."
  type        = bool
  default     = false
}

variable "agents" {
  description = <<-EOT
    The agents this configuration creates an identity for, keyed by agent name.

    reached_through_gateway is the field that matters most. True means this agent's egress goes
    through AgentGateway, so the gateway may assume its role and sign its model calls as the agent.
    False is for an execution-tier agent: it boots with no network device, so there is no egress to
    route and nothing for a gateway to be in the path of. Give such an agent no model ARNs either;
    it could not reach Bedrock with the permission.

    Leave this empty if the platform team declares agents from the cluster instead, through the
    agent resource definition in gitops/base/templates. The two are alternatives.
  EOT
  type = map(object({
    namespace                     = string
    service_account               = optional(string)
    bedrock_model_arns            = optional(list(string), [])
    bedrock_inference_profile_ids = optional(list(string), [])
    bedrock_guardrail_arn         = optional(string)
    bedrock_guardrail_version     = optional(string)
    needs_checkpoints             = optional(bool, true)
    reached_through_gateway       = optional(bool, true)
    session_policy_json           = optional(string)
    extra_policy_json             = optional(string)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.agents :
      v.reached_through_gateway || length(v.bedrock_model_arns) == 0
    ])
    error_message = "An agent with reached_through_gateway = false is an execution-tier agent with no network device. Granting it model ARNs creates a permission it cannot use and suggests a reachability it does not have; move the model access to the reasoning tier."
  }
}

variable "third_party_credentials" {
  description = <<-EOT
    The destinations whose credentials the gateway holds so the agent does not, keyed by a short
    name: `destination` is the host (api.github.com), `caller` the one agent allowed to use it.

    This creates the Secrets Manager secret, the sync of it into the gateway's namespace, the
    gateway's route and credential binding for the host, and the rule that only `caller` may reach
    it. The VALUE is set out of band, as JSON {"token": "<credential>"}: an API key or personal
    access token written directly, or an OAuth token written by a consent flow. The open source
    gateway does not run a consent flow itself -- per-user OAuth (an authorization URL on first
    call, a token per end user) is an enterprise gateway feature -- so a consented token here is one
    token for this destination and caller, not one per end user. See the
    agents-third-party-credentials page of the EKS User Guide.
  EOT
  type = map(object({
    destination = string
    caller      = string
  }))
  default = {}

  # The gateway routes a third-party call on its host name, one route per host, so one host can
  # carry one credential. Two callers needing different authority to the same service is a per-user
  # credential, which needs a gateway with a token store.
  validation {
    condition     = length(distinct([for v in var.third_party_credentials : v.destination])) == length(var.third_party_credentials)
    error_message = "Each third_party_credentials entry needs its own destination host: the gateway selects the credential by host, so two entries for one host would be two routes for the same name."
  }
}

variable "oauth_consent" {
  description = <<-EOT
    OAuth consent for third_party_credentials entries whose service issues tokens only through a
    person's approval (GitHub, Slack, Google, Atlassian), keyed by the same name. Deploys the consent
    receiver (gitops/charts/consent-receiver): an operator opens /connect/<key> through kubectl
    port-forward, approves at the provider, and the receiver writes the token to that entry's secret.

    ONE TOKEN PER DESTINATION, NOT PER END USER. The open source gateway attaches the destination's one
    credential for its caller agent; it has no store of per-user tokens. The token carries the
    authority of whoever approved.

      client_id          the OAuth app's client id
      client_secret_arn  a Secrets Manager secret whose SecretString is the client secret
      authorize_url      e.g. https://github.com/login/oauth/authorize
      token_url          e.g. https://github.com/login/oauth/access_token
      scopes             space-separated. For a GitHub App leave it empty: its permissions are set
                         on the app and its installation, and scope is ignored

    For GitHub, register a GitHub App, not an OAuth App: its user token reaches only the
    repositories the app is installed on and expires after 8 hours, and the receiver refreshes it.
    Register <consent_public_base_url>/callback/<key> as the app's callback URL.
  EOT
  type = map(object({
    client_id         = string
    client_secret_arn = string
    authorize_url     = string
    token_url         = string
    scopes            = optional(string, "")
  }))
  default = {}

  validation {
    condition     = alltrue([for k, _ in var.oauth_consent : contains(keys(var.third_party_credentials), k)])
    error_message = "Every oauth_consent key must name a third_party_credentials entry: the consent writes that entry's secret."
  }
}

variable "consent_public_base_url" {
  description = "Where the provider redirects the operator's browser: the forwarded localhost port of the consent receiver."
  type        = string
  default     = "http://localhost:8765"
}

variable "credential_admin_principal_arns" {
  description = "Principals besides the gateway permitted to read the brokered credentials, for whoever sets the values. Keep it short."
  type        = list(string)
  default     = []
}

variable "write_gitops_values" {
  description = "Render the values file the GitOps side reads. On by default: the alternative is hand-copying ARNs into manifests, which is where a stack like this drifts."
  type        = bool
  default     = true
}

variable "activate_cost_allocation_tags" {
  description = <<-EOT
    Activate the cost allocation tags this stack's usage carries -- iamPrincipal/agent and
    iamPrincipal/cluster from the Pod Identity session tags, aws:eks:cluster-name, and
    eks-agents/path -- so per-agent and per-cluster spend reaches Cost Explorer and the CUR.

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
  default     = "open-source"
}

variable "enable_platform_secrets" {
  description = <<-EOT
    Generate the five platform secrets into AWS Secrets Manager, and project them into the cluster
    with the Secrets Store CSI driver.

    ON BY DEFAULT, because the alternative is five `kubectl create secret` commands and a component
    that waits forever if you miss one. The values are generated here rather than committed, because
    a password in Git is wrong, and rather than Helm-generated, because a value that changes on every
    render makes Argo CD diff forever.

    Set false to create the Secrets yourself -- valkey-auth, grafana-admin, langfuse-secrets,
    langfuse-init, langfuse-otlp and (with enable_evaluations) langfuse-evals-api -- in which case nothing here reads Secrets Manager and the
    CSI Applications can be removed too.
  EOT
  type        = bool
  default     = true
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
  description = "Where to write that file. Commit it; it carries no secret."
  type        = string
  default     = "../../gitops/platform/open-source/terraform-values.yaml"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
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

    See the agents-mesh page of the EKS User Guide.
  EOT
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "ambient"], var.mesh_mode)
    error_message = "mesh_mode must be one of: none, ambient. There is no sidecar mode; see the agents-mesh page of the EKS User Guide."
  }
}

# --- the three layers you can turn on one at a time --------------------------
#
# THESE THREE ARE THE WHOLE OF THE EGRESS STORY, and each one is independently optional:
#
#   enable_network_policy   the boundary. An allowlist an agent cannot widen.
#   enable_gateway          the one destination that boundary points at, which holds the
#                           credentials and can see the request.
#   mesh_mode               whether arrival at that destination is enforced or agreed.
#
# Only the network policy is on by default: enable_gateway defaults to false and mesh_mode to
# "none", and each is turned on later, one at a time. Each combination is a real configuration
# rather than a half-built one, and the agents page of the EKS
# User Guide has the combinations and what each gives up.
#
# WHY THESE ARE TERRAFORM VARIABLES AND NOT JUST CHART VALUES. Two of the three are more than a
# rendering decision. The gateway is three Argo CD Applications, two of which install upstream
# charts, and the mesh is four more -- and an Application cannot decline to install itself. So
# Terraform renders the root Application's `directory.exclude` from these values and the files are
# never synced. Set them here; setting only the chart value leaves the component running and
# unreferenced, which is the worst of both.
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
    and nothing makes the gateway unavoidable. Set it false only where something else provides the
    boundary. Note one asymmetry: turning it off removes the ConfigMap but does NOT disable
    enforcement on a cluster where it was once enabled, because that ConfigMap belongs to the
    cluster rather than to this release.
  EOT
  type        = bool
  default     = true
}

variable "enable_gateway" {
  description = <<-EOT
    Deploy the in-cluster egress gateway and point the network policy at it.

    Off means no gateway is deployed, no gateway IAM role or audit log group is created, and the
    network policy permits `bedrock-runtime` in this region instead of the gateway namespace -- so
    agents call Amazon Bedrock directly with their own Pod Identity credential. The boundary still
    holds; what you give up is everything that needs the request in view (token budgets, model
    failover, tool policy, one audit point) and credentials held outside the pod.

    THE DEFAULT AGENT IMAGE DOES NOT START WITH THIS OFF. agents/reasoning reaches a model only
    through the gateway. Deploy agents/reasoning-direct instead, which calls Bedrock on the agent's
    own role -- an option, not the sample's default (the agents-application-setup page of the EKS User
    Guide, the model route).
  EOT
  type        = bool
  default     = false
}

variable "enable_bedrock_marketplace_subscribe" {
  description = <<-EOT
    With enable_gateway, let the gateway's role accept the one-time AWS Marketplace subscription an Anthropic model on
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

variable "enable_observability" {
  description = <<-EOT
    The agents' telemetry: the OpenTelemetry collector, Prometheus, Grafana and the agent dashboard
    (gitops/platform/open-source/templates/50-observability.yaml). The same switch as the AWS services path's,
    where it is the ADOT collector, CloudWatch and the dashboard there.

    Off means the file is not synced, agents are given no OTLP endpoint and no egress to a
    collector, and they export nothing. Grafana's admin Secret and the collector's Langfuse export
    header are not generated. Needed by enable_langfuse, whose traces arrive through the collector.
  EOT
  type        = bool
  default     = false
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
    endpoint is public (cluster_endpoint_public_access, or the existing cluster's own setting).

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
  description = "The bastion's instance type. It runs kubectl, helm and git, not workloads."
  type        = string
  default     = "t3.small"
}

variable "bastion_kubectl_version" {
  description = <<-EOT
    The kubectl release the bastion installs, as a `v1.33.0`-style tag. Keep it within one minor of
    kubernetes_version: kubectl supports one minor of skew either way, and a wider gap fails on
    resources it cannot parse rather than on connection.
  EOT
  type        = string
  default     = "v1.36.6"
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

variable "agent_turns_per_person_per_minute" {
  description = <<-EOT
    Turns a minute an agent serves for each person a turn is for, so one signed-in person cannot
    exhaust an agent that many people share: the gateway's model budget is keyed on the calling
    agent, which every person behind it shares. The person is the one the verified caller names
    (the sub of the person token it forwards, else its user_id, which the chat UI sets to the
    signed-in person). Over the limit, the agent answers 429 with Retry-After. Counted in each
    agent's pod, by the reference agent's server. 0 turns it off.
  EOT
  type        = number
  default     = 20

  validation {
    condition     = var.agent_turns_per_person_per_minute >= 0 && floor(var.agent_turns_per_person_per_minute) == var.agent_turns_per_person_per_minute
    error_message = "agent_turns_per_person_per_minute is a whole number of turns, 0 or more (0 turns the limit off)."
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
    Let an agent act with a person's own authority (terraform/modules/person-access). By default
    the gateway makes both kinds of call: it signs the agent's AWS calls as one role scoped to that
    person's data (person_access_via_gateway), and exchanges the person's token and the agent's own
    for one delegated token a tool verifies (person_access_delegated_token). Creates the pool's
    `api` client, an IAM OIDC provider for the pool, a bucket holding each person's data under
    people/<sub>/, and one role per agent. Needs enable_ingress with ingress_idp cognito or oidc,
    because the person's tokens are the ingress user pool's, and by default enable_gateway.
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
    Give a tool ONE token naming the person and the agent, instead of the person's own token beside
    an agent identity the tool cannot see (terraform/modules/person-delegation). The gateway
    exchanges the person's access token and the calling agent's own token at the user pool (RFC 8693
    delegation) and sends the tool the result: sub is the person, aud is the tools, act.sub is the
    agent. The person's own token does not reach the tool, and the tool refuses it. Switches the
    pool's sign-in pages to managed login, which Cognito's token exchange requires. On by default
    with enable_person_access, which then needs enable_gateway and enable_platform_secrets. false
    passes the person's own token through to the tool, which a tool should not accept as issued to
    it: for development only.
    See the agents-identity-on-behalf-of page of the EKS User Guide.
  EOT
  type        = bool
  default     = true

  validation {
    condition     = !(var.enable_person_access && var.person_access_delegated_token) || (var.enable_gateway && var.enable_platform_secrets)
    error_message = "enable_person_access gives a tool one delegated token (person_access_delegated_token, on by default), which needs enable_gateway (which exchanges the person's token) and enable_platform_secrets (which delivers the exchanger's secret to the gateway). Turn both on. person_access_delegated_token = false passes the person's own token to the tool instead, for development only."
  }
}

variable "person_access_via_gateway" {
  description = <<-EOT
    Let an agent reach a person's own data in S3 THROUGH the egress gateway, signed with that
    person's authority for that agent: the gateway verifies the person's ID token (x-person-token)
    and the agent's own token, then assumes the agent's person role itself with session tags
    person (the token's sub) and agent, and IAM scopes the call to people/<sub>/<agent>/. One route
    per agent in person_access_agents, /aws/<agent>/s3/. The person roles then trust only the
    gateway, so a person's token the agent holds cannot be exchanged for AWS credentials.
    AgentGateway cannot hand the person's token to STS, so on this path STS trusts the gateway's
    verification rather than the token itself, and the gateway sets the person tag. On by default
    with enable_person_access, which then needs enable_gateway. false lets the agent exchange the
    person's ID token with STS itself: for development only.
    See the agents-identity-on-behalf-of page of the EKS User Guide.
  EOT
  type        = bool
  default     = true

  validation {
    condition     = !(var.enable_person_access && var.person_access_via_gateway) || var.enable_gateway
    error_message = "enable_person_access sends a person's AWS calls through the gateway (person_access_via_gateway, on by default), which needs enable_gateway (which signs the calls). Turn it on. person_access_via_gateway = false lets the agent exchange the person's ID token with STS itself instead, for development only."
  }
}

variable "identity_change_alerts" {
  description = <<-EOT
    With enable_person_access, publish every change to what decides who an agent acts for to an SNS
    topic, <name>-identity-changes (terraform/modules/identity-change-alerts): the gateway's role and
    each person role (trust, policies, boundary, deletion), a Pod Identity association on the
    cluster, and the user pool's clients, identity providers and resource servers. With
    person_access_via_gateway, IAM trusts the gateway's session tag for the person, so these are the
    changes that could make an agent act for someone else. Needs an active CloudTrail trail that
    records global service events. Subscribe with identity_change_alert_emails or your own tooling.
  EOT
  type        = bool
  default     = true
}

variable "identity_change_alert_emails" {
  description = "Addresses subscribed to the identity-changes topic (identity_change_alerts). Each confirms by email first."
  type        = list(string)
  default     = []
}

variable "person_access_gateway_services" {
  description = <<-EOT
    AWS services besides S3 that agents reach through the gateway with a person's authority
    (person_access_via_gateway), keyed by the service's SigV4 signing name, for example dynamodb.
    Each gets a route per agent, /aws/<agent>/<service>/, signed as that agent's person role tagged
    with the verified person. `statements` are added to every agent's person role, with {agent}
    replaced by the agent's name: key them on $${aws:PrincipalTag/person} so the person scopes the
    access. `host` defaults to <service>.<region>.amazonaws.com.
    See the agents-identity-on-behalf-of page of the EKS User Guide.
  EOT
  type = map(object({
    host = optional(string, "")
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
    condition     = length(var.person_access_gateway_services) == 0 || var.person_access_via_gateway
    error_message = "person_access_gateway_services needs person_access_via_gateway."
  }
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
  validation {
    condition     = var.ingress_idp != "oidc-direct" || var.enable_platform_secrets
    error_message = "ingress_idp = \"oidc-direct\" needs enable_platform_secrets = true: the client secret reaches the ingress namespace through gitops/charts/platform-secrets."
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

variable "gateway_guardrail" {
  description = <<-EOT
    An Amazon Bedrock guardrail the gateway applies to every model request and every response,
    whatever the agent asked for: AgentGateway's Bedrock Guardrails processor rejects a request or
    response the guardrail blocks, and fails closed when the guardrail service doesn't answer. Name a
    published version, not DRAFT, so the checks don't change whenever someone edits the guardrail.
    Needs enable_gateway. Null applies none.
  EOT
  type = object({
    arn     = string
    version = string
  })
  default = null

  validation {
    condition     = var.gateway_guardrail == null || try(upper(var.gateway_guardrail.version) != "DRAFT" && var.gateway_guardrail.version != "", false)
    error_message = "gateway_guardrail.version must name a published version, not DRAFT."
  }
  validation {
    condition     = var.gateway_guardrail == null || var.enable_gateway
    error_message = "gateway_guardrail needs enable_gateway: the gateway is what applies it."
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

# --- an existing cluster --------------------------------------------------------------------
variable "create_cluster" {
  description = <<-EOT
    Create the EKS cluster, or attach to one that already exists.

    false makes this root a TENANT of a cluster somebody else owns. `name` is then the existing
    cluster's name, and kubernetes_version, vpc_id, subnet_ids, az_count and single_nat_gateway are
    ignored -- the network, the cluster IAM, the node role and the access entries are all the
    owner's. Everything this stack brings is still created: the capabilities, the permissions
    boundary, the ECR repositories, the gateway, and every object in gitops/.

    The cluster must be EKS Auto Mode.

    THREE THINGS IT INSTALLS ARE CLUSTER-WIDE and reach workloads that are not agents: the
    amazon-vpc-cni ConfigMap turns network policy enforcement on for the whole cluster, the
    eks-agents-gp3 StorageClass becomes default, and four Admin-tier ClusterNetworkPolicies are
    evaluated ahead of every namespaced policy. scripts/teardown.sh removes all three -- and the
    ConfigMap only if this stack created it. Read the Clean up section of the agents-cluster-setup
    page of the EKS User Guide first.
  EOT
  type        = bool
  default     = true
}

variable "enable_evaluations" {
  description = <<-EOT
    Agent evaluation with Strands Evals (gitops/charts/agent-evals): a CronJob that grades a sample
    of recent sessions from Langfuse and writes the grades back to Langfuse, and an on-demand
    experiment that runs declared cases against deployed agents as a release gate.

    Creates the judge's IAM role (assumed by the gateway, scoped to evaluation_judge_model_arns),
    renders its /judge route and subject check into the gateway, copies the Langfuse project keys
    into the runner's namespace, and stops excluding 52-agent-evals.yaml from the root Application.

    Needs the gateway (the judge's only route to a model), platform secrets (the Langfuse keys) and
    enable_langfuse. Off by default, and the right order is to turn it
    on second: grade by hand while the audience is small.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_evaluations || var.enable_langfuse
    error_message = "enable_evaluations needs enable_langfuse on this path: the runner reads sessions from Langfuse and writes its grades back there."
  }

  validation {
    condition     = !var.enable_evaluations || (var.enable_gateway && var.enable_platform_secrets)
    error_message = "enable_evaluations needs enable_gateway (the judge reaches its model only through the gateway's /judge route) and enable_platform_secrets (the Langfuse project keys the runner reads and writes with)."
  }

  validation {
    condition     = !var.enable_evaluations || length(var.evaluation_judge_model_arns) > 0
    error_message = "enable_evaluations needs evaluation_judge_model_arns: the judge's role is scoped to them, and with none every grade fails with AccessDenied."
  }
}

variable "evaluation_judge_model_arns" {
  description = <<-EOT
    The models the evaluation judge may invoke: the inference profile ARN AND the foundation-model
    ARNs it routes to in each Region, as for an agent's modelArns -- the profile alone is refused on
    the underlying model. Must cover evaluation_judge_model_id (or the agents' model, when that is
    empty).
  EOT
  type        = list(string)
  default     = []
}

variable "evaluation_judge_model_id" {
  description = <<-EOT
    The Bedrock model id the judge's gateway backend calls. Empty uses the agents' model. A judge on
    a different model from the agents it grades is a common choice: a stronger model, or one from
    another provider, so the agent is not grading itself.
  EOT
  type        = string
  default     = ""
}

variable "enable_consolidation" {
  description = <<-EOT
    Memory rung 3, consolidation, as a library inside the agent: Mem0 (mem0ai, through mem0-strands)
    deciding what is worth keeping across sessions, stored in the pgvector tier. Gives every Agent
    the read on the memory tier's login in Secrets Manager, the egress rule for it, an embeddings
    route on the gateway, and the environment the reference agent reads to turn the store on.

    Needs the semantic-recall tier underneath it: enable_semantic_recall. Also needs the gateway, which carries the
    extraction and embedding model calls, and the platform secrets, which generate the login.

    No Mem0 server is deployed. The published server image is stale (see
    gitops/platform/open-source/alternatives/mem0-server), and as a library the extraction calls
    are made on the agent's own identity, through the same gateway, budget and audit as its turns.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_consolidation || (var.enable_gateway && var.enable_platform_secrets && var.enable_semantic_recall)
    error_message = "enable_consolidation needs enable_gateway (Mem0's extraction and embedding calls go through the gateway on the agent's own token), enable_platform_secrets (which generates the memory tier's login) and enable_semantic_recall (the pgvector tier Mem0 stores in)."
  }
}

variable "consolidation_embedding_model_id" {
  description = "The Bedrock embedding model the gateway serves on each agent's /llm/<agent>/embeddings route when enable_consolidation is on. Its output size must match consolidation_embedding_dims, and the pgvector table is created at that size on first write."
  type        = string
  default     = "amazon.titan-embed-text-v2:0"
}

variable "consolidation_embedding_dims" {
  description = "Vector size for the consolidation store. 1024 is Titan Text Embeddings V2's default; changing it after the first write needs a new table."
  type        = number
  default     = 1024
}

variable "enable_langfuse" {
  description = <<-EOT
    Langfuse (gitops/platform/open-source/templates/51-langfuse.yaml): traces with the agent's trajectory,
    prompts, and the store evaluation grades are written to. Brings its own tiers -- ClickHouse with
    a Keeper quorum through the ClickHouse operator (and cert-manager for that operator's webhooks),
    Postgres, Valkey and an object store -- all installed by the same file's Applications, in order.

    Also switches the collector's traces pipeline to export to it (collector-values.yaml), so that
    half needs no separate hand edit. Needs enable_platform_secrets, which generates
    Langfuse's own secrets and its project keys.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !var.enable_langfuse || var.enable_platform_secrets
    error_message = "enable_langfuse needs enable_platform_secrets: Langfuse reads its salt, NextAuth secret, encryption key and first project's keys from Secrets it generates."
  }

  validation {
    condition     = !var.enable_langfuse || var.enable_observability
    error_message = "enable_langfuse needs enable_observability: agents' traces reach Langfuse through the OpenTelemetry collector, and with no collector Langfuse receives nothing."
  }
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

variable "enable_session_state" {
  description = <<-EOT
    Session state between turns: an in-cluster Valkey (gitops/platform/open-source/templates/60-memory.yaml)
    with a generated password, and SESSION_STATE_ENDPOINT on every agent. For agents that keep
    working state outside the pod, such as a Deployment with more than one replica, or an MCP server
    holding no session in the pod. Off in the base: the default runtime is one Sandbox per agent,
    and the reference agent saves its conversation with enable_checkpoints, not here.
  EOT
  type        = bool
  default     = false
}

variable "enable_semantic_recall" {
  description = <<-EOT
    Memory rung 2, semantic recall: the CloudNativePG operator and a pgvector cluster
    (gitops/platform/open-source/templates/61-semantic-recall.yaml). Off in the base, where the file is
    excluded from the sync entirely, so neither Application exists. Needed by enable_consolidation.
  EOT
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access" {
  description = "Open the cluster's API endpoint to the internet, restricted to cluster_endpoint_public_access_cidrs, so kubectl and the scripts can run from your workstation instead of the bastion. Off by default: the endpoint is private. Requests are still authenticated with IAM and authorized by access entries. Applies only when the stack creates the cluster (agents-cluster-setup)."
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
      agents and the gateway  bedrock-runtime (the gateway's and direct agents' model calls), sts,
                              secretsmanager (brokered credentials, platform secrets), sqs (task
                              queues, with enable_agent_tasks)
      nodes                   ecr-api, ecr-dkr, eks-auth (Pod Identity)
      tokens                  oidc-eks (the cluster's OIDC issuer, which every service account
                              token check reads)
      bastion                 ssm, ssmmessages, ec2messages; eks, elasticloadbalancing and
                              bedrock for the scripts run there (the EKS API, load balancer and
                              inference profile lookups)
    With eks listed, oidc-eks is added for you: the eks endpoint's private DNS zone covers the OIDC
    issuer's host name, which then resolves only through the oidc-eks endpoint. Route 53
    (ExternalDNS) has no VPC endpoint.
    S3 already has a gateway endpoint. Each interface endpoint is billed per hour in each
    Availability Zone. Created only when the stack creates the VPC, or when vpc_id and vpc_cidr are
    set.
  EOT
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.vpc_endpoints : contains(["bedrock-runtime", "sts", "secretsmanager", "sqs", "ecr-api", "ecr-dkr", "eks-auth", "oidc-eks", "ssm", "ssmmessages", "ec2messages", "eks", "elasticloadbalancing", "bedrock", "logs", "monitoring", "xray"], e)])
    error_message = "Supported vpc_endpoints on this path: bedrock-runtime, sts, secretsmanager, sqs, ecr-api, ecr-dkr, eks-auth, oidc-eks, ssm, ssmmessages, ec2messages, eks, elasticloadbalancing, bedrock, logs, monitoring, xray."
  }

  # The endpoints' security group admits the VPC's CIDR, which Terraform knows only for a VPC it
  # created or one you name.
  validation {
    condition     = length(var.vpc_endpoints) == 0 || var.create_cluster || var.vpc_id != ""
    error_message = "vpc_endpoints on an existing cluster needs vpc_id and vpc_cidr set to that cluster's VPC."
  }
}
