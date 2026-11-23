# The AWS services path of the reference sample, in Terraform.
#
# Everything shared with the other path is the same module: the cluster, the capabilities, ECR, the
# checkpoint bucket, per-agent identity. What differs is who operates the egress gateway and the
# credential brokering behind it, and where observability, evaluation and memory come from.
#
# In cluster, reconciled from Git rather than from here:
#   ../../gitops/bootstrap/aws-services/    the root Application
#   ../../gitops/platform/aws-services/     agent-sandbox, the ADOT collector, Istio if the team
#                                           wants arrival enforced rather than agreed
#   ../../gitops/base/                      the admission policy, the cluster-scoped egress policy,
#                                           the agent resource definition
#
# One thing to be clear about before adopting this path. AgentCore Gateway brokers credentials and
# searches a tool catalogue in a managed service, with no proxy fleet to run. Nothing in AWS forces
# an agent's traffic to reach it. On this path the enforcement is still in the cluster — the cluster-scoped network policy
# that permits DNS and the gateway and nothing else, with Istio ambient capture on top where the
# team needs an unmodified agent to run under the same controls. See the agents page of the EKS
# User Guide.

data "aws_caller_identity" "current" {}

# The IAM role behind the caller's assumed-role session (or the IAM user), for the default cluster
# admin: an access entry names a role, never an sts session ARN.
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

# The inference profile agents call with no gateway, read for the ARNs an Agent's modelArns must
# list: the profile and the foundation model in every Region it routes to.
data "aws_bedrock_inference_profile" "direct" {
  inference_profile_id = var.direct_model_id
}
data "aws_partition" "current" {}

locals {
  # The ingress namespace: its browser-gated routes and rules, and the direct OIDC client
  # secret. Written into the base chart's values as namespaces.ingress and handed to
  # platform-secrets, so the routes, the Secret and the eks:managed grant agree on one name.
  ingress_namespace = "ingress"

  # The one mode that needs a Kubernetes Secret, and with it the secret sync.
  ingress_direct_oidc = var.enable_ingress && var.ingress_idp == "oidc-direct"

  # The Strands Evals runner's namespace and service account (gitops/charts/agent-evals). Its Pod
  # Identity association, the base chart's namespace and per-agent ingress rule, and the chart all
  # read these.
  evals_namespace       = "agent-evals"
  evals_service_account = "agent-evals"
}

locals {
  tags = merge(var.tags, {
    "eks-agents/path" = "aws-services"
  })

  # Every agent service account, fully qualified, which is what the gateway's inbound authorization
  # admits. Derived rather than listed, because a namespace prefix here would admit any service
  # account a tenant creates in that namespace and there is no audience allowlist at token fetch
  # time to catch it.
  # The gateway's allowlist is stated by the platform team, not derived from agents this
  # configuration creates -- because it does not create any. Agents are declared in the cluster as
  # `Agent` resources and composed by kro, so Terraform cannot know them at gateway-create time.
  #
  # Keeping the allowlist explicit is what preserves the per-agent match: a namespace prefix here
  # would admit any service account a tenant creates in that namespace, and there is no audience
  # allowlist at token fetch time to catch it. `var.agents` remains available for the case where a
  # team does want Terraform to own an agent's identity, and its subjects are folded in so that
  # case still works without listing them twice.
  agent_subjects = distinct(concat(
    var.allowed_agent_subjects,
    [
      for k, v in var.agents :
      "system:serviceaccount:${v.namespace}:${coalesce(v.service_account, k)}"
    ],
  ))

  # The network the rest of this configuration builds on: yours if you supplied one, the one this
  # root created otherwise. Everything downstream reads these rather than the variables, so a module
  # cannot accidentally be wired to an empty vpc_id.
  # The two optional layers' outputs, read once here so every consumer agrees on the "off" value:
  # the empty string, never null, because the chart tests these for emptiness.
  telemetry_log_group = try(module.observability[0].telemetry_log_group_name, "")
  gateway_model_url   = try(module.gateway[0].model_endpoint, "")

  vpc_id     = var.vpc_id != "" ? var.vpc_id : module.network[0].vpc_id
  subnet_ids = length(var.subnet_ids) > 0 ? var.subnet_ids : module.network[0].private_subnet_ids

}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------
#
# Created only when vpc_id is empty. `count` on a module rather than a flag variable, so bringing
# your own network means this module is not in the plan at all -- no placeholder resources, nothing
# to import, and `terraform destroy` never touches a network it did not create.

module "network" {
  source = "../modules/network"
  count  = var.vpc_id == "" ? 1 : 0

  name   = var.name
  region = var.region

  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  single_nat_gateway = var.single_nat_gateway

  enable_flow_logs         = var.enable_vpc_flow_logs
  flow_logs_retention_days = var.vpc_flow_logs_retention_days

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Public API endpoint, limited to this machine
# ---------------------------------------------------------------------------
#
# Only with cluster_endpoint_public_access and no CIDRs named: the public IPv4 address of the machine
# running Terraform, as a /32. Looked up on every plan, so an apply from a new address moves it.
# A network that leaves through a pool of NAT addresses can answer with a different one per
# connection, and repeating the lookup within a plan returns the same one, so such a network names
# its pool in cluster_endpoint_public_access_cidrs instead.
data "http" "terraform_host_ip" {
  # Two lookups, because they can disagree: on a VPN that leaves through a pool of addresses,
  # checkip.amazonaws.com can report one address while EKS sees the one api.ipify.org reports.
  # Both are allowed as /32s; a pool is still better named outright.
  for_each = length(var.cluster_endpoint_public_access_cidrs) == 0 && (var.cluster_endpoint_public_access || (var.enable_ingress && var.ingress_scheme == "internet-facing" && length(var.ingress_allowed_cidrs) == 0)) ? toset(["https://checkip.amazonaws.com", "https://api.ipify.org"]) : toset([])
  url      = each.value

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && can(cidrnetmask("${chomp(self.response_body)}/32"))
      error_message = "Could not read this machine's public IPv4 address from ${self.url}. Set cluster_endpoint_public_access_cidrs instead."
    }
  }
}

locals {
  cluster_public_access_cidrs = length(var.cluster_endpoint_public_access_cidrs) > 0 ? var.cluster_endpoint_public_access_cidrs : distinct([for d in values(data.http.terraform_host_ip) : "${chomp(d.response_body)}/32"])

  # An internet-facing ingress admits the API endpoint's callers unless told otherwise: the point of
  # it is that the same workstation runs every step.
  ingress_internet_facing = var.enable_ingress && var.ingress_scheme == "internet-facing"
  ingress_allowed_cidrs   = length(var.ingress_allowed_cidrs) > 0 ? var.ingress_allowed_cidrs : local.cluster_public_access_cidrs

  # Where the ingress load balancer's ENIs go: the private subnets for an internal one (Auto Mode
  # picks them by tag), the public subnets for an internet-facing one, named explicitly so the
  # CIDRs the agents' network policy admits are the ones the load balancer actually uses.
  ingress_subnet_ids = local.ingress_internet_facing ? (length(module.network) > 0 ? module.network[0].public_subnet_ids : data.aws_subnets.public[0].ids) : local.subnet_ids
}

# The public subnets of a VPC this root did not create, for an internet-facing ingress: the ones
# tagged for internet-facing load balancers.
data "aws_subnets" "public" {
  count = local.ingress_internet_facing && length(module.network) == 0 ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
  tags = {
    "kubernetes.io/role/elb" = "1"
  }

  lifecycle {
    postcondition {
      condition     = length(self.ids) > 0
      error_message = "ingress_scheme = \"internet-facing\" found no subnet tagged kubernetes.io/role/elb = 1 in this VPC. Tag its public subnets, or keep the ingress internal."
    }
  }
}

# THE BASTION IS REQUIRED WITH A PRIVATE-ONLY ENDPOINT. Without it, and with no public endpoint,
# apply returns a cluster whose every next step -- kubectl, the GitOps bootstrap, the checks --
# cannot be run from anywhere this stack knows about.
resource "terraform_data" "operator_access" {
  input = var.enable_bastion ? "bastion" : "workstation"

  lifecycle {
    precondition {
      condition     = var.enable_bastion || module.cluster.endpoint_public_access
      error_message = "enable_bastion = false needs the public API endpoint (cluster_endpoint_public_access = true): with a private-only endpoint the bastion is the only path to kubectl. Set cluster_endpoint_public_access = true to run everything from this machine, or keep the bastion."
    }
  }
}

module "cluster" {
  source = "../modules/agent-cluster"

  # The platform team's permission sets, and one per task agent for its own queues.
  agent_permission_sets = merge(var.agent_permission_sets, local.task_permission_sets)

  # Identity Center is regional and its region is frequently not the cluster's; see versions.tf.
  providers = {
    aws     = aws
    aws.idc = aws.idc
  }

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = local.vpc_id
  subnet_ids = local.subnet_ids

  endpoint_public_access       = var.cluster_endpoint_public_access
  endpoint_public_access_cidrs = local.cluster_public_access_cidrs

  cluster_admin_principal_arns = length(var.cluster_admin_principal_arns) > 0 ? var.cluster_admin_principal_arns : [data.aws_iam_session_context.current.issuer_arn]
  agent_namespaces             = var.agent_namespaces
  gitops_repo_url              = var.gitops_repo_url

  # On by default (enable_argocd), and on whenever an Identity Center instance is supplied. The
  # capability's API requires the IdC configuration, so an account with none fails the apply rather
  # than the plan, with the call that creates one.
  enable_capability_argocd           = var.enable_argocd || var.argocd_idc_instance_arn != ""
  argocd_idc_instance_arn            = var.argocd_idc_instance_arn
  argocd_idc_region                  = var.argocd_idc_region
  argocd_rbac_role_mappings          = var.argocd_rbac_role_mappings
  argocd_manage_admin_group          = var.argocd_manage_admin_group
  argocd_admin_group_name            = var.argocd_admin_group_name
  argocd_admin_users                 = var.argocd_admin_users
  argocd_admin_existing_user_names   = var.argocd_admin_existing_user_names
  argocd_vpce_ids                    = var.argocd_vpce_ids
  argocd_codecommit_repository_arns  = var.argocd_codecommit_repository_arns
  argocd_codeconnections_arns        = var.argocd_codeconnections_arns
  argocd_secrets_manager_secret_arns = var.argocd_secrets_manager_secret_arns
  argocd_ecr_pull                    = var.argocd_ecr_pull
  argocd_cluster_access_policy_arn   = var.argocd_cluster_access_policy_arn
  ecr_repository_names               = local.ecr_repository_names
  ecr_force_delete                   = var.ecr_force_delete

  # The cluster-level setting the ingress Gateway needs. Without it the Gateway and
  # GatewayClass are accepted by the API server and claimed by no controller, so routes never
  # program and the symptom is a route that looks fine and serves nothing.
  enable_gateway_api = var.enable_ingress

  # The control plane's log group, so `terraform destroy` takes it and it has a retention. An
  # EKS-created one has neither.
  log_retention_days       = var.cluster_log_retention_days
  log_kms_key_arn          = var.kms_key_arn == null ? "" : var.kms_key_arn
  enable_cluster_log_types = var.enable_cluster_log_types

  tags = local.tags

  # The on-behalf-of exchange for a person's tools (person_access_delegated_token).
  allow_person_delegation = var.enable_person_access && var.person_access_delegated_token
}

# ---------------------------------------------------------------------------
# Ingress: the name, the certificate and the identity provider
# ---------------------------------------------------------------------------

# The subnets the ingress load balancer places its ENIs in, read back for their CIDRs.
#
# WHY THE CIDRS ARE NEEDED AT ALL: an `ip` target group health-checks and forwards to the pod IP
# FROM THE LOAD BALANCER'S OWN ENIs, which are VPC addresses and not pods. The agent's namespaced
# ApplicationNetworkPolicy selects the pod for Ingress, so with no rule naming those addresses every
# inbound connection is dropped -- the target sits `unhealthy / Target.Timeout` and a caller gets a
# 504.
#
# `ipBlock` is the only source that can express this: the policy API's `from` takes ipBlock,
# namespaceSelector or podSelector, and a load balancer is none of the latter two.
data "aws_subnet" "ingress" {
  # KEYED BY POSITION, NOT BY ID. When this configuration creates the VPC the subnet ids are unknown
  # until apply, and a set of unknown strings cannot key a for_each -- so enabling ingress on
  # a net-new cluster would fail at PLAN with "Invalid for_each argument". The
  # count of subnets is known either way, so their positions are valid keys.
  for_each = var.enable_ingress ? { for i, id in local.ingress_subnet_ids : tostring(i) => id } : {}
  id       = each.value
}

# TURNING INGRESS OFF TAKES TWO APPLIES, AND THE FIRST ONE KEEPS ITS AWS RESOURCES. The ingress load
# balancer is the cluster's (the EKS Auto Mode controller makes it from the Gateway the base chart
# renders), and it serves this module's certificate and signs people in through its Cognito pool. An
# apply that destroys them with the load balancer still up waits 12 minutes on ACM refusing to
# delete a certificate in use, while the sync that removes the load balancer can only run after the
# apply. So the module stays while the cluster still has that load
# balancer: the first apply renders ingress off, the sync removes the Gateway and its load balancer,
# and the next apply finds none and destroys the rest.
data "aws_lbs" "ingress" {
  tags = {
    "eks:eks-cluster-name"                = var.name
    "gateway.eks.amazonaws.com.alb/stack" = "${var.agent_namespaces[0]}/agent-ingress"
  }
}

# The ingress load balancer's web ACL (enable_ingress_waf). The chart names it on the
# LoadBalancerConfiguration (wafV2.webACL), and EKS Auto Mode's load balancer controller associates
# it when it creates the load balancer.
module "ingress_waf" {
  source = "../modules/waf"
  # KEPT WHILE THE LOAD BALANCER EXISTS, like the ingress module below. Turning ingress off renders
  # the load balancer away first, and AWS refuses to delete a web ACL still associated with it
  # (WAFAssociatedItemException), so the web ACL goes with the apply after the load balancer has.
  count = var.enable_ingress_waf && (var.enable_ingress || length(data.aws_lbs.ingress.arns) > 0) ? 1 : 0

  name              = "${var.name}-ingress"
  description       = "Requests to the agents ingress load balancer on ${var.name}"
  rate_limit_per_ip = var.ingress_waf_rate_limit_per_ip
  tags              = local.tags
}

module "ingress" {
  count  = var.enable_ingress || length(data.aws_lbs.ingress.arns) > 0 ? 1 : 0
  source = "../modules/ingress"

  name         = var.name
  vpc_id       = local.vpc_id
  cluster_name = module.cluster.cluster_name
  cluster_arn  = module.cluster.cluster_arn

  domain_name             = var.ingress_domain_name
  certificate_arn         = var.ingress_certificate_arn
  public_zone_id          = var.ingress_public_zone_id
  self_signed_certificate = var.ingress_self_signed_certificate

  # internet-facing: a public agents' zone delegated from public_zone_id, and the load balancer's
  # own security group admitting HTTPS from the allowlist only.
  scheme        = local.ingress_internet_facing ? "internet-facing" : "internal"
  allowed_cidrs = local.ingress_internet_facing ? local.ingress_allowed_cidrs : []

  # Who signs in. The module always creates a Cognito pool; ingress_idp decides whether the load
  # balancer uses it (cognito, oidc -- the provider federated into the pool) or calls the provider
  # itself (oidc-direct). ingress_oidc's extra attributes -- jwks_uri, name, scopes -- are dropped
  # by direct_oidc's narrower type; only federation uses them.
  federated_oidc = var.ingress_idp == "oidc" ? var.ingress_oidc : null
  direct_oidc    = var.ingress_idp == "oidc-direct" ? var.ingress_oidc : null

  # One callback per exposed hostname. Derived from the agents that declare a route, plus the apex
  # for a route that claims it.
  cognito_callback_hosts = distinct(concat(
    [var.ingress_domain_name],
    [for k, v in var.agents : "${k}.${var.ingress_domain_name}"],
    var.ingress_hostnames,
    var.enable_chat_ui ? ["chat.${var.ingress_domain_name}"] : [],
  ))

  tags = local.tags

  # Cognito's token exchange requires managed login on the domain (person_access_delegated_token).
  managed_login = var.enable_person_access && var.person_access_delegated_token
}

# An agent acting with a person's own authority (enable_person_access). The person's tokens come from
# the ingress user pool, so this exists only with ingress. See terraform/modules/person-access.
# Agents that run as tasks (enable_agent_tasks): queues per agent and KEDA's role. The agent's own
# role reaches its queues through the tasks-<agent> permission set below.
module "agent_tasks" {
  count  = var.enable_agent_tasks ? 1 : 0
  source = "../modules/agent-tasks"

  name                       = var.name
  cluster_name               = module.cluster.cluster_name
  agents                     = var.task_agents
  visibility_timeout_seconds = var.task_visibility_timeout_seconds
  tags                       = local.tags
}

locals {
  # Built from the queue NAMES rather than the module's outputs, because module.cluster needs these
  # sets to write the boundary and module.agent_tasks needs the cluster: the names are the contract.
  task_permission_sets = var.enable_agent_tasks ? { for a in var.task_agents : "tasks-${a}" => {
    statements = [
      {
        sid       = "TakeOwnTasks"
        actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"]
        resources = ["arn:${data.aws_partition.current.partition}:sqs:${var.region}:${data.aws_caller_identity.current.account_id}:${var.name}-${a}-tasks"]
      },
      {
        sid       = "SendOwnResults"
        actions   = ["sqs:SendMessage"]
        resources = ["arn:${data.aws_partition.current.partition}:sqs:${var.region}:${data.aws_caller_identity.current.account_id}:${var.name}-${a}-results"]
      },
    ]
    namespaces = [var.agent_namespaces[0]]
  } } : {}
}

# The bastion may start a task agent's work and read its results, so scripts/exercise.sh (the
# tasks phase) and an operator can drive one by hand. Nothing else in the cluster gets this.
resource "aws_iam_role_policy" "bastion_tasks" {
  count = var.enable_agent_tasks && var.enable_bastion ? 1 : 0

  name = "agent-tasks"
  role = element(split("/", module.bastion[0].role_arn), length(split("/", module.bastion[0].role_arn)) - 1)
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "SendTasks"
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [for a, q in module.agent_tasks[0].queues : q.tasks_arn]
      },
      {
        Sid      = "ReadResults"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [for a, q in module.agent_tasks[0].queues : q.results_arn]
      },
      # exercise.sh's tasks phase reads each dead-letter queue's depth before and after, so a task
      # that was redriven there rather than answered can't pass as "deleted once answered".
      {
        Sid      = "ReadDeadLetterDepth"
        Effect   = "Allow"
        Action   = ["sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = [for a, q in module.agent_tasks[0].queues : q.dlq_arn]
      },
    ]
  })
}

module "person_access" {
  count  = var.enable_person_access ? 1 : 0
  source = "../modules/person-access"

  name          = var.name
  region        = var.region
  account_id    = data.aws_caller_identity.current.account_id
  user_pool_id  = module.ingress[0].cognito_user_pool_id
  agents        = var.person_access_agents
  callback_urls = var.person_access_callback_urls
  force_destroy = var.checkpoint_bucket_force_destroy
  tags          = local.tags

  allow_password_auth = var.person_access_password_auth
}

# ONE DELEGATED TOKEN per tool call (person_access_delegated_token), from AgentCore Identity's
# on-behalf-of token exchange. See terraform/modules/person-delegation-agentcore.
module "person_delegation" {
  count  = var.enable_person_access && var.person_access_delegated_token ? 1 : 0
  source = "../modules/person-delegation-agentcore"

  name          = var.name
  user_pool_id  = module.ingress[0].cognito_user_pool_id
  issuer        = module.person_access[0].issuer
  tool_audience = "${var.name}-tools"
  agents        = var.person_access_agents
  tags          = local.tags

  # The ingress module's domain switches to managed login in the same apply; the exchange is
  # refused until it has.
  depends_on = [module.ingress]
}

# Managed login serves no page for a client without a style, so the api client gets Cognito's
# default one when it signs people in through the hosted UI (person_access_callback_urls).
resource "aws_cognito_managed_login_branding" "person_api" {
  count = var.enable_person_access && var.person_access_delegated_token && length(var.person_access_callback_urls) > 0 ? 1 : 0

  user_pool_id                = module.ingress[0].cognito_user_pool_id
  client_id                   = module.person_access[0].api_client_id
  use_cognito_provided_values = true
}

# The delegation phase of scripts/exercise.sh reads CloudTrail on the bastion to prove the audit
# record names the agent and the person. LookupEvents is read-only and has no resource scope.
# exercise.sh's telemetry phase looks for its own turn's spans in aws/spans, the account's
# Transaction Search log group, which the bastion module's log grant (this cluster's /aws/eks/
# groups) doesn't cover. The group is the account's single one, so this lets the bastion read every
# workload's spans in the account, not only this cluster's: IAM can't narrow FilterLogEvents by
# content. It is granted only when this stack turns Transaction Search on.
resource "aws_iam_role_policy" "bastion_span_reads" {
  count = var.enable_observability && var.enable_transaction_search && var.enable_bastion ? 1 : 0

  name = "exercise-span-reads"
  role = element(split("/", module.bastion[0].role_arn), length(split("/", module.bastion[0].role_arn)) - 1)
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "ReadTurnSpans"
      Effect   = "Allow"
      Action   = ["logs:FilterLogEvents"]
      Resource = "arn:${data.aws_partition.current.partition}:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:aws/spans:*"
    }]
  })
}

resource "aws_iam_role_policy" "bastion_person_audit" {
  count = var.enable_person_access && var.enable_bastion ? 1 : 0

  name = "person-access-audit"
  role = element(split("/", module.bastion[0].role_arn), length(split("/", module.bastion[0].role_arn)) - 1)
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "ReadAuditRecord", Effect = "Allow", Action = ["cloudtrail:LookupEvents"], Resource = "*" },
      # exercise.sh's delegation phase reads each person role's trust policy, to show that only the
      # expected principal may assume it rather than infer it from an AccessDenied.
      { Sid = "ReadPersonRoleTrust", Effect = "Allow", Action = ["iam:GetRole"], Resource = values(module.person_access[0].role_arns) },
    ]
  })
}

# The model phase of scripts/exercise.sh reads this stack's gateway on the bastion: its guardrail
# policies, to know whether to send a prompt-injection attempt, and its resource policy, to know
# whether a call from outside the VPC endpoint must be refused. Read-only, on this gateway and its
# policy engine only.
resource "aws_iam_role_policy" "bastion_gateway_reads" {
  count = var.enable_gateway && var.enable_bastion ? 1 : 0

  name = "gateway-reads"
  role = element(split("/", module.bastion[0].role_arn), length(split("/", module.bastion[0].role_arn)) - 1)
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "ReadGateway"
        Effect   = "Allow"
        Action   = ["bedrock-agentcore:GetGateway", "bedrock-agentcore:GetResourcePolicy", "bedrock-agentcore:ListGatewayTargets"]
        Resource = module.gateway[0].gateway_arn
      }],
      module.gateway[0].policy_engine_arn == "" ? [] : [{
        Sid      = "ListGatewayPolicies"
        Effect   = "Allow"
        Action   = ["bedrock-agentcore:ListPolicies"]
        Resource = module.gateway[0].policy_engine_arn
      }],
    )
  })
}

# ---------------------------------------------------------------------------
# The ingress direct OIDC client secret
# ---------------------------------------------------------------------------
#
# Only for ingress_idp = "oidc-direct". The load balancer's authenticate-oidc rule reads the client
# secret from a Kubernetes Secret in the ingress namespace, and the cluster's API endpoint is
# private, so Terraform cannot write it there: the same Secrets Store CSI sync the open source path
# uses for its platform secrets carries it instead (gitops/platform/aws-services/templates/45-platform-secrets.yaml,
# excluded from the sync otherwise). None of the open source path's five component secrets are made.
module "platform_secrets" {
  count  = local.ingress_direct_oidc ? 1 : 0
  source = "../modules/platform-secrets"

  name                        = var.name
  cluster_name                = module.cluster.cluster_name
  cluster_arn                 = module.cluster.cluster_arn
  include_platform_components = false
  namespaces                  = { ingress = local.ingress_namespace }
  ingress_oidc = {
    client_id         = var.ingress_oidc.client_id
    client_secret_arn = var.ingress_oidc.client_secret_arn
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# The host that can reach the cluster
# ---------------------------------------------------------------------------
#
# Same reason as the open source path: this root uses the same agent-cluster module, so the API
# endpoint is private-only here too and nothing outside the VPC can run kubectl against it. On this
# path the gateway is off-cluster, which removes some of what you would reach in for -- but the
# admission policy, the egress boundary and the agent resource definition are all in-cluster, so
# verifying any of them still needs a host inside the VPC.

# ---------------------------------------------------------------------------
# Interface VPC endpoints (vpc_endpoints)
# ---------------------------------------------------------------------------
module "vpc_endpoints" {
  source = "../modules/vpc-endpoints"
  count  = length(var.vpc_endpoints) > 0 ? 1 : 0

  name       = var.name
  region     = var.region
  vpc_id     = local.vpc_id
  vpc_cidr   = var.vpc_id != "" ? var.vpc_cidr : module.network[0].vpc_cidr
  subnet_ids = local.subnet_ids

  # THE GATEWAY'S ENDPOINT COMES WITH agentcore. The agentcore endpoint's private DNS zone is
  # bedrock-agentcore.<region>.amazonaws.com, and every gateway's host is
  # <name>.gateway.bedrock-agentcore.<region>.amazonaws.com, so with that zone in the VPC and no
  # gateway endpoint the gateway's host returns NXDOMAIN and every model call fails with "Name or
  # service not known". The agentcore-gateway endpoint's *.gateway zone
  # answers it. THE ISSUER'S ENDPOINT COMES WITH eks, the same way: the eks endpoint's zone covers
  # oidc.eks.<region>.amazonaws.com, which the oidc-eks endpoint's own zone answers.
  endpoints = setunion(
    var.vpc_endpoints,
    var.enable_gateway && contains(var.vpc_endpoints, "agentcore") ? ["agentcore-gateway"] : [],
    contains(var.vpc_endpoints, "eks") ? ["oidc-eks"] : [],
  )
  agentcore_gateway_arns = var.enable_gateway ? [module.gateway[0].gateway_arn] : []

  tags = local.tags
}

# Agent image builds in CodeBuild (enable_image_build): the project scripts/build-images.sh --root
# starts.
module "image_build" {
  source = "../modules/image-build"
  count  = var.enable_image_build && length(module.cluster.ecr_repository_arns) > 0 ? 1 : 0

  name                = var.name
  ecr_repository_arns = module.cluster.ecr_repository_arns
  architecture        = var.image_build_architecture
  kms_key_arn         = var.kms_key_arn
  tags                = local.tags
}

module "bastion" {
  source = "../modules/bastion"
  count  = var.enable_bastion ? 1 : 0

  # The EC2-safe tag keys, because RunInstances refuses a `/` in one. See versions.tf.
  providers = {
    aws = aws.ec2_instance_tags
  }

  cluster_name              = module.cluster.cluster_name
  cluster_arn               = module.cluster.cluster_arn
  cluster_security_group_id = module.cluster.cluster_security_group_id

  vpc_id   = local.vpc_id
  vpc_cidr = var.vpc_id != "" ? var.vpc_cidr : module.network[0].vpc_cidr

  subnet_id = local.subnet_ids[0]

  instance_type       = var.bastion_instance_type
  architecture        = var.bastion_architecture
  kubectl_version     = var.bastion_kubectl_version
  kms_key_arn         = var.kms_key_arn
  ecr_repository_arns = module.cluster.ecr_repository_arns

  # Teardown steps 8-9 on this host: delete this stack's repositories, empty its bucket.
  teardown_access       = var.bastion_teardown_access
  checkpoint_bucket_arn = try(module.checkpoints[0].bucket_arn, "")

  # So the host can clone the repository the bootstrap applies from.
  gitops_codecommit_repository_arns = var.argocd_codecommit_repository_arns

  tags = local.tags

  # So the kubectl steps in the README have the tree they apply from.
  gitops_repo_url = var.gitops_repo_url
}

# ---------------------------------------------------------------------------
# Durable checkpoint storage
# ---------------------------------------------------------------------------

module "checkpoints" {
  count  = var.enable_checkpoints ? 1 : 0
  source = "../modules/durable-storage"

  bucket_name     = coalesce(var.checkpoint_bucket_name, "${var.name}-agent-checkpoints-${data.aws_caller_identity.current.account_id}")
  force_destroy   = var.checkpoint_bucket_force_destroy
  kms_key_arn     = var.kms_key_arn
  organization_id = var.organization_id

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Per-agent identity
# ---------------------------------------------------------------------------

module "agent_identity" {
  source   = "../modules/agent-identity"
  for_each = var.agents

  cluster_name = module.cluster.cluster_name
  cluster_arn  = module.cluster.cluster_arn

  agent_name      = each.key
  namespace       = each.value.namespace
  service_account = each.value.service_account

  role_path                = module.cluster.agent_role_path
  permissions_boundary_arn = module.cluster.agent_permissions_boundary_arn

  # The model scope for calls an agent makes with no gateway (enable_gateway = false): the agent
  # calls Bedrock on its own role, delivered by Pod Identity, and CloudTrail attributes the call to
  # the agent. With the gateway on, the gateway signs model calls with its own role.
  bedrock_model_arns            = each.value.bedrock_model_arns
  bedrock_inference_profile_ids = each.value.bedrock_inference_profile_ids
  bedrock_guardrail_arn         = each.value.bedrock_guardrail_arn
  bedrock_guardrail_version     = each.value.bedrock_guardrail_version

  checkpoint_bucket_arn  = each.value.needs_checkpoints && var.enable_checkpoints ? module.checkpoints[0].bucket_arn : null
  checkpoint_kms_key_arn = each.value.needs_checkpoints ? var.kms_key_arn : null

  session_policy_json = each.value.session_policy_json
  extra_policy_json   = each.value.extra_policy_json

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Egress: AgentCore Gateway
# ---------------------------------------------------------------------------

# Off with enable_gateway = false: agents call Amazon Bedrock directly on their own roles, and the
# network policy names bedrock-runtime instead of this gateway's host name.
# The model permits, generated: one per agent in gateway_permitted_agents, and the judge's whenever
# the release gate is on. Hand-written cedar_policies are merged over them by key.
locals {
  model_permit = "permit(principal == AgentCore::OAuthUser::\"system:serviceaccount:%s:%s\", action in AgentCore::Action::\"bedrock\", resource == AgentCore::Gateway::\"{{gateway_arn}}\");"
  generated_cedar_policies = merge(
    { for a in var.gateway_permitted_agents :
      "permit_model_${replace(replace(a, "/", "_"), "-", "_")}" => {
        description = "Generated from gateway_permitted_agents: ${a} may call the model through the gateway."
        statement   = format(local.model_permit, length(split("/", a)) == 2 ? split("/", a)[0] : "agents", element(split("/", a), length(split("/", a)) - 1))
      }
    },
    var.enable_evaluations ? {
      permit_model_evaluation_judge = {
        description = "Generated with enable_evaluations: the evaluation judge may call the model through the gateway."
        statement   = format(local.model_permit, local.evals_namespace, "agent-evals")
      }
    } : {},
  )
  # Every principal the gateway serves: each agent in gateway_permitted_agents, the judge with
  # evaluations, and gateway_extra_principals.
  gateway_principals = distinct(concat(
    [for a in var.gateway_permitted_agents : format("system:serviceaccount:%s:%s", length(split("/", a)) == 2 ? split("/", a)[0] : "agents", element(split("/", a), length(split("/", a)) - 1))],
    var.enable_evaluations ? [format("system:serviceaccount:%s:agent-evals", local.evals_namespace)] : [],
    var.gateway_extra_principals,
  ))
  # THE BASELINE FORBID. Cedar permits combine: any matching permit allows, so one broad permit
  # (`permit(principal, ...)`, or `principal is AgentCore::OAuthUser`, which is every caller here)
  # opens the gateway to every subject its audience admits. A forbid overrides every permit, so this
  # one keeps any principal not listed above out of every target, whatever else gets attached --
  # by this root, by hand, or by another tool. With a broad permit attached, an unlisted agent's
  # model call is refused by this policy while a listed agent's succeeds. It is created with
  # IGNORE_ALL_FINDINGS because the validator calls any forbid that covers tools no permit covers
  # yet "Overly Restrictive"; that is the point of it.
  baseline_forbid = var.gateway_baseline_forbid ? {
    forbid_unlisted_principals = {
      description     = "Generated: no OAuth caller outside gateway_permitted_agents, the judge and gateway_extra_principals reaches any target, whatever a permit says."
      statement       = format("forbid(principal is AgentCore::OAuthUser, action, resource == AgentCore::Gateway::\"{{gateway_arn}}\") unless { principal in [%s] };", join(", ", [for p in local.gateway_principals : format("AgentCore::OAuthUser::\"%s\"", p)]))
      validation_mode = "IGNORE_ALL_FINDINGS"
    }
  } : {}
  cedar_policies = merge(local.generated_cedar_policies, local.baseline_forbid, var.cedar_policies)

  # THE GUARDRAIL CHECK (gateway_guardrails), on the inference target's chat completions action,
  # which is the route every agent's model call takes. The forbid subtracts from
  # the model permits above, so a caller without a permit is still refused before any guardrail
  # runs. The JSONPaths are the chat completions shapes: a message's content is a string or a list
  # of parts, and a path that matches nothing contributes nothing, so naming both covers either.
  # Only the request is screened. AgentCore Policy's output effect (suppressOutput) can't evaluate a
  # streamed chat completion and refuses every one, and the agents stream every turn.
  # THE PROMPT-ATTACK CHECK READS THE NEWEST MESSAGE ONLY: the user's prompt on a turn's first model
  # call, and each tool result on the calls after it, which is where an injected instruction
  # arrives. Each message is screened once, on the call that adds it. Re-scoring the whole history
  # on every call refused ordinary sessions as they grew: a benign read-back was refused in every
  # one of three delegated turns, while the same prompts passed alone. The system prompt is never
  # the newest message, and it's instructions by design, so the classifier would score it high.
  gateway_chat_action = "AgentCore::Action::\"bedrock___POST:/v1/chat/completions\""
  guardrail_policies = var.gateway_guardrails == null ? {} : merge(
    var.gateway_guardrails.prompt_attack_threshold == null ? {} : {
      guardrail_prompt_attack = {
        description = "Generated from gateway_guardrails: refuse a model call whose newest message scores above ${var.gateway_guardrails.prompt_attack_threshold} for ${join(", ", var.gateway_guardrails.prompt_attack_categories)}."
        statement = format(
          "forbid(principal is AgentCore::OAuthUser, action == %s, resource == AgentCore::Gateway::\"{{gateway_arn}}\") when guardrails { BedrockGuardrails::PromptAttack([%s], [\"$.messages[-1:].content\", \"$.messages[-1:].content[*].text\"]).maxConfidenceScore().greaterThan(decimal(\"%s\")) };",
          local.gateway_chat_action,
          join(", ", [for c in var.gateway_guardrails.prompt_attack_categories : format("\"%s\"", c)]),
          format("%.1f", var.gateway_guardrails.prompt_attack_threshold),
        )
      }
    },
  )
}

module "gateway" {
  source = "../modules/egress-agentcore"
  count  = var.enable_gateway ? 1 : 0

  name         = var.name
  cluster_name = module.cluster.cluster_name

  gateway_log_retention_days = var.log_retention_days

  oidc_issuer_url        = module.cluster.cluster_oidc_issuer_url
  allowed_agent_subjects = local.agent_subjects
  allowed_audiences      = var.gateway_audiences

  enable_policy_engine     = var.enable_policy_engine
  enable_temporal_policies = var.enable_temporal_policies
  policy_engine_mode       = var.policy_engine_mode
  cedar_policies           = local.cedar_policies
  dogwood_policies         = var.dogwood_policies
  dogwood_enforcement_mode = var.dogwood_enforcement_mode
  guardrail_policies       = local.guardrail_policies

  api_key_providers  = var.api_key_providers
  oauth2_providers   = var.oauth2_providers
  mcp_server_targets = var.mcp_server_targets
  open_api_targets   = var.open_api_targets

  lambda_targets = var.lambda_targets
  # Default the invoke grant to the functions actually wired as targets. Stating the ARNs twice is
  # how a target gets created that the gateway may not invoke, and the tool call then fails with an
  # AccessDenied the agent cannot distinguish from a refused tool.
  lambda_target_arns = length(var.lambda_target_arns) > 0 ? var.lambda_target_arns : [for t in var.lambda_targets : t.function_arn]

  inference_model_arns   = var.gateway_inference_model_arns
  gateway_kms_key_arn    = var.kms_key_arn
  policy_kms_key_arn     = var.kms_key_arn
  credential_kms_key_arn = var.kms_key_arn

  tags = local.tags
}

# THE GATEWAY ANSWERS ONLY THROUGH THIS VPC'S ENDPOINT (gateway_require_vpc_endpoint). The gateway's
# endpoint is public, and its authorizer admits any valid token for its audience. A projected agent
# token copied out of a pod would work from anywhere until it expired. With the agentcore-gateway
# endpoint in place, this policy refuses every invocation that doesn't arrive through it, so the
# token works only inside the VPC. The callers present a JWT rather than SigV4, so there is no IAM
# principal to name: the Allow names every principal and the network path decides, and the Deny
# keeps any other policy from widening it.
locals {
  # Known at plan time, unlike the endpoint's id: the agentcore-gateway endpoint exists exactly when
  # the gateway is on and vpc_endpoints lists "agentcore".
  gateway_vpce_only = var.enable_gateway && var.gateway_require_vpc_endpoint && contains(var.vpc_endpoints, "agentcore")
  gateway_vpce_id   = local.gateway_vpce_only ? module.vpc_endpoints[0].endpoint_ids["agentcore-gateway"] : null
}

resource "aws_bedrockagentcore_resource_policy" "gateway" {
  count = local.gateway_vpce_only ? 1 : 0

  resource_arn = module.gateway[0].gateway_arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "InvokeThroughThisVpcEndpoint"
        Effect    = "Allow"
        Principal = "*"
        Action    = "bedrock-agentcore:InvokeGateway"
        Resource  = module.gateway[0].gateway_arn
        Condition = { StringEquals = { "aws:SourceVpce" = local.gateway_vpce_id } }
      },
      {
        Sid       = "RefuseEveryOtherPath"
        Effect    = "Deny"
        Principal = "*"
        Action    = "bedrock-agentcore:InvokeGateway"
        Resource  = module.gateway[0].gateway_arn
        Condition = { StringNotEquals = { "aws:SourceVpce" = local.gateway_vpce_id } }
      },
    ]
  })
}

# PER-AGENT BUDGETS (gateway_rate_limits). Keyed on the caller's token subject, which on this gateway
# is always an agent's service account, so one agent over its budget gets 429 and the others keep
# working. One limit holds the default entry ("*") and one entry per overridden agent.
locals {
  gateway_rate_entries = var.gateway_rate_limits == null ? tolist([]) : tolist(concat(
    [{ subject = "*", rpm = var.gateway_rate_limits.requests_per_minute, tpm = var.gateway_rate_limits.tokens_per_minute }],
    [for a, b in var.gateway_rate_limits.per_agent : {
      subject = format("system:serviceaccount:%s:%s", length(split("/", a)) == 2 ? split("/", a)[0] : "agents", element(split("/", a), length(split("/", a)) - 1))
      rpm     = b.requests_per_minute
      tpm     = b.tokens_per_minute
    }],
  ))
}

resource "awscc_bedrockagentcore_gateway_rate_limit" "per_agent" {
  count = var.enable_gateway && var.gateway_rate_limits != null ? 1 : 0

  gateway_identifier = module.gateway[0].gateway_id
  description        = "Per-agent request and token budgets (gateway_rate_limits)."
  dimension_keys     = ["$.context.jwt.sub"]
  entries = [for e in local.gateway_rate_entries : {
    dimensions = { "$.context.jwt.sub" = e.subject }
    requests   = e.rpm == null ? null : [{ rate = e.rpm, period = "minute" }]
    tokens     = e.tpm == null ? null : [{ rate = e.tpm, period = "minute" }]
  }]
}

# The gateway's web ACL (enable_gateway_waf). No per-IP rate rule: every agent reaches the gateway
# from the same NAT or endpoint addresses, so gateway_rate_limits budgets each agent instead.
module "gateway_waf" {
  source = "../modules/waf"
  count  = var.enable_gateway && var.enable_gateway_waf ? 1 : 0

  name        = "${var.name}-gateway"
  description = "Calls to the AgentCore gateway on ${var.name}"
  tags        = local.tags
}

resource "aws_wafv2_web_acl_association" "gateway" {
  count = var.enable_gateway && var.enable_gateway_waf ? 1 : 0

  resource_arn = module.gateway[0].gateway_arn
  web_acl_arn  = module.gateway_waf[0].web_acl_arn
}

# ---------------------------------------------------------------------------
# Observability
# ---------------------------------------------------------------------------

# Off with enable_observability = false: no telemetry log group, collector role or dashboard, and the
# ADOT collector and cert-manager are left out of the sync (platform_excluded below).
module "observability" {
  source = "../modules/observability-aws"
  count  = var.enable_observability ? 1 : 0

  name         = var.name
  cluster_name = module.cluster.cluster_name
  cluster_arn  = module.cluster.cluster_arn

  enable_transaction_search = var.enable_transaction_search
  log_retention_days        = var.log_retention_days
  log_kms_key_arn           = var.kms_key_arn

  # The policy-decisions dashboard and saved queries.
  enable_network_policy_logs = var.enable_network_policy_logs
  gateway_id                 = var.enable_gateway ? module.gateway[0].gateway_id : ""
  cluster_log_types          = var.enable_cluster_log_types

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Memory
# ---------------------------------------------------------------------------

module "memory" {
  source = "../modules/memory-aws"

  name         = var.name
  cluster_name = module.cluster.cluster_name

  vpc_id                    = local.vpc_id
  subnet_ids                = local.subnet_ids
  client_security_group_ids = [module.cluster.cluster_security_group_id]

  kms_key_arn = var.kms_key_arn

  enable_session_state        = var.enable_session_state
  session_state_user_group_id = var.session_state_user_group_id

  enable_semantic_recall      = var.enable_semantic_recall
  semantic_recall_bucket_name = var.enable_semantic_recall ? coalesce(var.semantic_recall_bucket_name, "${var.name}-agent-vectors-${data.aws_caller_identity.current.account_id}") : null
  semantic_recall_indexes     = var.semantic_recall_indexes

  enable_consolidation                = var.enable_consolidation
  consolidation_event_expiry_duration = var.consolidation_event_expiry_duration
  consolidation_model_arns            = var.consolidation_model_arns
  consolidation_strategies            = var.consolidation_strategies

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Evaluations
# ---------------------------------------------------------------------------

# Grades the spans the observability layer records, so it exists only with that layer: with
# enable_observability off there is no log group to grade, and the variable validations refuse online
# evaluation and the runner without it. And only with evaluation itself on: otherwise observability
# alone would create the online evaluation execution role, which nothing assumes until a
# configuration exists.
module "evaluations" {
  source = "../modules/evaluations-aws"
  count  = var.enable_observability && (var.enable_evaluations || var.enable_online_evaluation) ? 1 : 0

  name         = var.name
  cluster_name = module.cluster.cluster_name

  source_log_group_names = [local.telemetry_log_group]

  # The agents Terraform created, PLUS the ones it did not. `var.agents` is empty in the normal
  # case -- that is what turns the Agent resource definition on -- and the API refuses an empty
  # serviceNames list, so var.agents alone cannot supply it in the documented configuration.
  source_service_names = distinct(concat(keys(var.agents), var.evaluation_service_names))

  judge_model_arns     = var.judge_model_arns
  llm_judge_evaluators = var.llm_judge_evaluators
  builtin_evaluators   = var.evaluation_builtin_evaluators

  enable_online_evaluation = var.enable_online_evaluation
  enable_on_create         = var.enable_online_evaluation_on_create
  sampling_percentage      = var.evaluation_sampling_percentage
  session_timeout_minutes  = var.evaluation_session_timeout_minutes

  kms_key_arn = var.kms_key_arn

  # The Strands Evals runner: reads traces, writes results. No model permission -- its judge calls go
  # through the AgentCore Gateway.
  runner = var.enable_evaluations ? {
    namespace       = local.evals_namespace
    service_account = local.evals_service_account
    cluster_arn     = module.cluster.cluster_arn
  } : null

  tags = local.tags
}

# ---------------------------------------------------------------------------
# What the GitOps side needs to know
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Cost allocation tags
# ---------------------------------------------------------------------------
#
# Each agent's Pod Identity session carries `agent` and `cluster` session tags (model.sessionTags
# in gitops/base/values.yaml), and the agent roles permit sts:TagSession -- but a user-defined tag
# reaches the Cost and Usage Report only once it is ACTIVATED, and until then per-agent spend is
# recorded on each session and reported nowhere. Activation is not retroactive, so the cost before it stays unsplit.
#
# OFF BY DEFAULT, and not because it is optional. Two constraints make it unsafe to assume:
#
#   - It is a BILLING-level setting, so it has to be applied with credentials for the payer
#     (management) account. A member-account apply fails with AccessDenied.
#   - A user-defined key can only be activated once it has appeared in the tag inventory, which
#     happens after tagged usage has been observed. Activating on the first apply, before any agent
#     has made a model call, can fail on a key the account has never seen.
#
# So: run the first apply without it, let agents make some calls, then set
# `activate_cost_allocation_tags = true` with payer credentials. One apply, no console.
resource "aws_ce_cost_allocation_tag" "agent_tags" {
  # THE KEYS AS BILLING SEES THEM in the account's tag inventory. Activating `agent` and `cluster`,
  # which are the Pod Identity SESSION tag names, does not work -- session tags reach billing
  # prefixed, as iamPrincipal/agent and iamPrincipal/cluster. Plain `agent` and `cluster` never
  # appear in the inventory, so the switch could only fail, or activate keys no usage carries.
  #
  #   iamPrincipal/agent, iamPrincipal/cluster   usage signed by an agent's role, per agent. These
  #                                              follow model.sessionTags in gitops/base/values.yaml;
  #                                              change both if you rename the session tag keys.
  #   ON THIS PATH THE MODEL CALL IS SIGNED BY THE GATEWAY'S ROLE, not the agent's, so
  #   iamPrincipal/agent attributes an agent's OWN AWS calls -- checkpoints, session state,
  #   S3 Vectors, AgentCore Memory -- and not its Bedrock spend. Per-agent model spend on this
  #   path is in the gateway's GenAI metrics and the dashboard, not the bill.
  #   aws:eks:cluster-name                       AWS-generated: per-cluster cost of what EKS and
  #                                              Auto Mode create, the nodes included.
  #   eks-agents/path, eks-agents.path           this stack's resources, by path. EC2 instances
  #                                              carry the dotted form; RunInstances refuses `/`.
  for_each = var.activate_cost_allocation_tags ? toset([
    "iamPrincipal/agent",
    "iamPrincipal/cluster",
    "aws:eks:cluster-name",
    "eks-agents/path",
    "eks-agents.path",
  ]) : toset([])

  tag_key = each.value
  status  = "Active"
}

# ---------------------------------------------------------------------------
# The bootstrap objects, rendered
# ---------------------------------------------------------------------------
#
# WHY THESE ARE RENDERED RATHER THAN EDITED. The three objects under gitops/bootstrap hand the
# cluster to Argo CD, and Argo CD cannot deliver them itself: it has no destination, no project and
# no repository until something outside creates them. That seam is structural in every GitOps
# install. What is NOT structural is filling in the values by hand -- the committed templates carry
# CLUSTER_ARN, CLUSTER_NAME, CLUSTER_CA_DATA and REPO_URL, and Terraform knows all four, along with
# the repositories argocd_extra_source_repos adds to the AppProject.
#
# So the templates stay as placeholders in Git, and the applyable copies land beside them as
# `*.local.yaml`, which .gitignore already excludes -- a rendered cluster secret carries this
# cluster's ARN and CA data and has no business in a shared repository.
#
# `kubectl apply -f gitops/bootstrap/<path>/` would also pick up the placeholder templates, so
# next_steps names the rendered files explicitly.
locals {
  bootstrap_dir = "${path.module}/../../gitops/bootstrap/${var.path_name_for_bootstrap}"

  # WHICH PLATFORM APPLICATIONS ARE LEFT OUT: the platform chart renders every file in
  # gitops/platform/<path>/templates/ except the ones named here, which the root Application passes as
  # `excluded`. This is how a layer is left OUT rather than installed and made inert: with
  # mesh_mode = "none" and no entry here, the cluster would get four Istio Applications and a ztunnel
  # on every node with no namespace enrolled.
  #
  # Keep this list and the chart's own `enabled` values in step -- they are rendered from the same
  # variables a few lines below, which is what keeps them from drifting.
  platform_excluded = concat(
    var.mesh_mode == "none" ? ["54-istio-namespace.yaml", "55-istio.yaml"] : [],
    # CRD-only Applications, synced with ingress that needs them: on this path the gateway is
    # managed and off-cluster, so nothing else composes a Gateway API or gateway.k8s.aws kind.
    var.enable_ingress ? [] : ["10-gateway-api-crds.yaml"],
    # The Secrets Store CSI driver and the secret sync, which this path needs only to carry a direct
    # OIDC client secret into the ingress namespace -- so only with ingress_idp = "oidc-direct".
    #
    # KEYED ON THE IdP MODE, not on enable_ingress. Keying on enable_ingress would spare a
    # root-app.local.yaml re-apply when switching cognito -> oidc-direct, but every component change
    # already re-applies it (agents-capabilities-setup, "Turn on a component later", and
    # bootstrap-gitops.sh --sync), and keying on the ingress would install the CSI driver, its AWS
    # provider and the syncer -- a DaemonSet pod per node -- under cognito and oidc, where the chart
    # renders nothing.
    local.ingress_direct_oidc ? [] : ["45-platform-secrets.yaml"],
    # external-dns writes the ingress records and reads a values file Terraform renders only with
    # ingress on; synced without it, the Application fails on the missing file.
    var.enable_ingress ? [] : ["12-external-dns.yaml"],
    # KEDA, which starts a task agent's pods from its queue.
    var.enable_agent_tasks ? [] : ["13-keda.yaml"],
    var.enable_evaluations ? [] : ["52-agent-evals.yaml"],
    length(var.agentcore_consent) > 0 && var.enable_gateway ? [] : ["46-consent-receiver.yaml"],
    # The ADOT collector and the operator behind it, and cert-manager, which is here only to certify
    # that operator's webhooks.
    var.enable_observability ? [] : ["45-cert-manager.yaml", "50-adot.yaml"],
  )

  # Argo CD takes ONE pattern. Brace expansion is how it takes several, and a single entry must NOT
  # be braced: `{a.yaml}` is matched literally and excludes nothing, so the sync succeeds and syncs
  # the file you meant to leave out.

  bootstrap_rendered = {
    "cluster-secret.local.yaml" = replace(replace(replace(
      file("${local.bootstrap_dir}/cluster-secret.yaml"),
      "CLUSTER_ARN", module.cluster.cluster_arn),
      "CLUSTER_NAME", module.cluster.cluster_name),
    "CLUSTER_CA_DATA", module.cluster.cluster_certificate_authority_data)

    "root-app.local.yaml" = replace(replace(replace(replace(
      file("${local.bootstrap_dir}/root-app.yaml"),
      "REPO_URL", var.gitops_repo_url),
      "REPO_REVISION", var.gitops_repo_revision),
      "REPO_PATH", var.gitops_repo_path),
    "PLATFORM_EXCLUDED", jsonencode(local.platform_excluded))

    # The project's sourceRepos: the platform repository over REPO_URL, the chart repositories the
    # template lists, and argocd_extra_source_repos in place of the EXTRA_SOURCE_REPOS line.
    "appproject.local.yaml" = replace(replace(
      file("${local.bootstrap_dir}/appproject.yaml"),
      "REPO_URL", var.gitops_repo_url),
      "    # EXTRA_SOURCE_REPOS", join("\n", concat(
        ["    # argocd_extra_source_repos"],
    [for r in var.argocd_extra_source_repos : "    - ${jsonencode(r)}"])))
  }
}

resource "local_file" "bootstrap" {
  for_each = local.bootstrap_rendered

  filename        = "${local.bootstrap_dir}/${each.key}"
  content         = each.value
  file_permission = "0644"
}

# The external-dns Application's values, rendered here for the same reason terraform-values.yaml is:
# the zone id, the domain and nothing else it needs are Terraform's outputs. The Application reads
# this through Argo CD's `$values` second source, so no ARN or zone id is ever hand-copied into a
# manifest.
#
# Written next to the Application rather than wherever gitops_values_path points, because the
# Application names it by repository path.
resource "local_file" "external_dns_values" {
  count = var.enable_ingress && var.write_gitops_values ? 1 : 0

  filename        = "${dirname(abspath(path.module))}/../gitops/platform/aws-services/external-dns-values.yaml"
  file_permission = "0644"

  content = yamlencode({
    provider = { name = "aws" }

    # Gateway API, not Ingress: the address is on the Gateway and the hostnames are on the
    # HTTPRoutes, so this source reads both and writes one record per route hostname.
    sources = ["gateway-httproute"]

    # `sync`, so a record is REMOVED when its route is. upsert-only leaves a name resolving to a
    # load balancer after the agent behind it is gone.
    policy = "sync"

    # The TXT registry is what makes `sync` safe: the controller deletes only records it can prove
    # it created, identified by this owner id.
    registry   = "txt"
    txtOwnerId = module.ingress[0].agent_zone_id

    domainFilters = [var.ingress_domain_name]

    # THIS STACK'S ZONE ONLY, by ID. domainFilters matches every zone of that name the role can
    # list, and another stack in the account can own a private zone with the same name. The
    # controller then fails its whole run on that zone (ListResourceRecordSets: AccessDenied, since
    # the role may read only this one) and writes no record at all. The chart has no zoneIdFilters
    # value (external-dns chart 1.15.2 ignores it), so the flag goes through extraArgs.
    extraArgs = ["--zone-id-filter=${module.ingress[0].agent_zone_id}"]

    serviceAccount = {
      create = true
      name   = module.ingress[0].dns_reconciler_service_account

      # NO ROLE ANNOTATION. Pod Identity is not IRSA: the association is an AWS-side object this
      # root creates, and the credential arrives as environment variables injected at pod
      # admission. An eks.amazonaws.com/role-arn annotation would be inert and would read as the
      # identity being configured when it is not.
      annotations = {}
    }

    # One replica. The association is injected at ADMISSION from what the control plane can see at
    # that moment, so a pod created in the same reconcile as its association runs with no credential
    # and nothing reports it -- a restart is the fix, and with one replica it is cheap.
    replicaCount = 1

    # A record changes only when a route or a Gateway does, so the default minute-by-minute polling
    # is Route 53 calls for nothing.
    interval = "5m"
    logLevel = "info"

    resources = {
      requests = { cpu = "50m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }
  })
}

resource "local_file" "gitops_values" {
  count = var.write_gitops_values ? 1 : 0

  filename        = var.gitops_values_path
  file_permission = "0644"

  content = yamlencode({
    # Written by terraform/aws-services. Do not edit by hand: the next apply overwrites it.
    accountId = data.aws_caller_identity.current.account_id
    partition = data.aws_partition.current.partition

    # The capability role names, so the base chart can grant kro the Kubernetes RBAC it needs to
    # compose an agent. Without that binding the resource definition never reconciles, and the
    # failure is silent.
    capabilities = {
      kro = { roleName = module.cluster.capability_role_names.kro }
      ack = { roleName = module.cluster.capability_role_names.ack }
    }
    path    = "aws-services"
    cluster = module.cluster.cluster_name
    region  = var.region

    oidcIssuerUrl = module.cluster.cluster_oidc_issuer_url

    # The ingress direct OIDC client secret, the only platform secret this path syncs. Off
    # unless ingress_idp = "oidc-direct", and its Application syncs only then.
    platformSecrets = local.ingress_direct_oidc ? {
      enabled                   = true
      secrets                   = module.platform_secrets[0].chart_values
      namespaces                = module.platform_secrets[0].namespaces
      externallyOwnedNamespaces = [local.ingress_namespace]
    } : { enabled = false, secrets = {}, namespaces = [], externallyOwnedNamespaces = [] }

    # Only the ingress and the evaluation runner's namespaces are Terraform's to name; the
    # chart's defaults hold the rest.
    namespaces = { ingress = local.ingress_namespace, evals = local.evals_namespace }

    # Agent evaluation, read by the base chart (the runner's namespace and each agent's ingress rule
    # for it) and by agent-evals. The judge calls the same inference endpoint the agents do, under
    # the same model name, on its own projected token.
    evals = {
      enabled        = var.enable_evaluations
      namespace      = local.evals_namespace
      serviceAccount = local.evals_service_account
      backend        = "agentcore"
      judge = {
        baseUrl  = local.gateway_model_url
        model    = coalesce(var.evaluation_judge_model_id, var.gateway_model_id, "unset")
        audience = var.gateway_audiences[0]
      }
      agentcore = {
        logGroup    = local.telemetry_log_group
        region      = var.region
        resultsName = "${var.name}-release-gate"
      }
    }

    # THE AGENTS' OWN NODES, and the reason this is rendered rather than left to the operator.
    #
    # `networkPolicy: DefaultDeny` on the NodeClass selects the node agent's STRICT enforcement
    # mode, where a pod's traffic is denied until its policies are programmed. On the cluster
    # default, `DefaultAllow`, a pod whose first instruction is an outbound call can leave before its
    # policies are programmed; DefaultDeny closes that window. The mode is read when the
    # NODE boots, so this cannot be a patch applied afterwards -- it has to be the NodeClass the
    # agents' nodes were launched with.
    #
    # It is a dedicated NodeClass rather than an edit to the cluster's `default`, because on a
    # DefaultDeny node a pod that no policy selects loses DNS as well as egress, which would break
    # every workload on a shared cluster that is not an agent.
    nodeClass = {
      roleName         = module.cluster.node_role_name
      subnetIds        = local.subnet_ids
      securityGroupIds = [module.cluster.cluster_security_group_id]
    }

    # "none" unless the team adds Istio on this path, which is the default here: a namespace label
    # is inert without a data plane, and emitting one would suggest a capture that is not happening.
    # Set mesh_mode and install the mesh together -- gitops/platform/aws-services/ISTIO-DECISION.md
    # explains why it is optional on this path and what it buys.
    model = {
      # The name an agent asks for, from the connector's catalogue rather than from Bedrock.
      gatewayModelId = var.gateway_model_id
      # What an agent calls with no gateway (direct_model_id).
      directModelId = var.direct_model_id
    }

    # The first of the layers, rendered here so the chart and the root Application's exclude glob
    # are decided by one variable rather than two that can disagree.
    networkPolicy = {
      enabled              = var.enable_network_policy
      adminTierDefaultDeny = var.network_policy_admin_tier_default_deny
      # needsClusterApi's one destination, from the cluster's own service CIDR.
      kubernetesApiServiceIp = module.cluster.kubernetes_service_ip
      # NO IN-CLUSTER DESTINATIONS ON THIS PATH. The chart's default list is the open source memory
      # ladder -- Valkey and pgvector Services in an agent-memory namespace -- and this path has no
      # such namespace: session state is ElastiCache, recall S3 Vectors, consolidation AgentCore
      # Memory, each reached by hostname and named by its own rule only when it is turned on. The
      # chart's default would name Services in a namespace that does not exist here.
      inClusterDestinations = []
    }

    mesh = {
      mode        = var.mesh_mode
      trustDomain = "cluster.local"
    }

    # The consent receiver in AgentCore mode: completes 3LO session binding for the named agent.
    consent = {
      enabled        = length(var.agentcore_consent) > 0 && var.enable_gateway
      namespace      = "consent"
      serviceAccount = "consent-receiver"
      publicBaseUrl  = var.consent_public_base_url
      port           = 8765
      clients = {
        for k, v in var.agentcore_consent : k => {
          mode           = "agentcore"
          agent          = v.agent
          agentNamespace = var.agent_namespaces[0]
          audience       = var.gateway_audiences[0]
          mcpUrl         = try(module.gateway[0].mcp_endpoint, "")
          tool           = v.tool
          toolArguments  = v.tool_arguments
        }
      }
      syncer = { namespace = "", deployment = "" }
    }

    gateway = {
      # enable_gateway. Off, the chart names bedrock-runtime as the model destination and injects no
      # gateway endpoint; the fields below are then empty.
      enabled  = var.enable_gateway
      url      = try(module.gateway[0].gateway_url, "")
      hostname = try(module.gateway[0].gateway_hostname, "")
      arn      = try(module.gateway[0].gateway_arn, "")

      # The two endpoints an agent is configured with, kept separate because one gateway serves
      # tools and models on different paths. Each carries its scheme and path, so an agent is never
      # handed a bare hostname.
      modelEndpoint = local.gateway_model_url
      mcpEndpoint   = try(module.gateway[0].mcp_endpoint, "")

      # enable_temporal_policies: every agent sends its session as the policy session, which a
      # temporal policy requires on every request (apps/reference/app.py, _policy_session_headers).
      policySessions = var.enable_gateway && var.enable_policy_engine && var.enable_temporal_policies

      # The audience the agent's projected token is minted for, taken from what the gateway is
      # configured to accept so the two cannot drift. The variable is validated non-empty, so this
      # index is safe.
      audience = var.gateway_audiences[0]
    }

    # enable_observability. Off, agents get no OTLP endpoint and no egress to a collector, and the
    # ADOT Applications are excluded from the sync, so nothing reads the empty fields.
    observability = {
      enabled                 = var.enable_observability
      collectorNamespace      = try(module.observability[0].collector_namespace, "")
      collectorServiceAccount = try(module.observability[0].collector_service_account, "")
      collectorRoleArn        = try(module.observability[0].collector_role_arn, "")
      telemetryLogGroup       = local.telemetry_log_group

      # Both evaluations grade what the agent said, read from the spans, so with either one on the
      # collector keeps prompt and completion content on them (collector.keepPromptContent in
      # gitops/charts/adot-collector, false by default, strips it otherwise).
      evaluationsReadSpans = var.enable_evaluations || var.enable_online_evaluation
    }

    memory = {
      sessionStateEndpoint = module.memory.session_state_endpoint

      # The identity half. The endpoint says where, these say who -- an agent authenticates to the
      # cache with a signed token from its own role rather than a shared password.
      sessionStateUserArn  = module.memory.session_state_user_arn
      sessionStateCacheArn = module.memory.session_state_cache_arn
      vectorBucketArn      = module.memory.semantic_recall_bucket_arn
      vectorIndexes        = join(",", sort(keys(var.semantic_recall_indexes)))
      memoryId             = module.memory.memory_id
      memoryNamespaces     = join(",", distinct(flatten([for s in values(var.consolidation_strategies) : s.namespaces])))
    }

    storage = {
      checkpointBucket = var.enable_checkpoints ? module.checkpoints[0].bucket_name : ""
    }

    agentResource = {
      enabled                = length(var.agents) == 0
      rolePath               = module.cluster.agent_role_path
      permissionsBoundaryArn = module.cluster.agent_permissions_boundary_arn
      # What spec.permissionSets may name: set -> namespaces it is offered to (empty: all).
      permissionSets = { for k, v in module.cluster.agent_permission_sets : k => v.namespaces }
    }

    # Agents that run as tasks (enable_agent_tasks).
    tasks = {
      enabled                  = var.enable_agent_tasks
      agents                   = var.enable_agent_tasks ? var.task_agents : []
      visibilityTimeoutSeconds = var.task_visibility_timeout_seconds
    }

    # WHERE THE AGENT IMAGES COME FROM, and the one place to change it.
    #
    # Default: the ECR repositories this configuration creates, which you build into. Set
    # `agent_image_registry` to a registry you choose that already holds the images, and every
    # consumer follows, because `registry` is the only place an image URI is named. No manifest,
    # example or chart carries one.
    ingress = var.enable_ingress ? {
      enabled        = true
      namespace      = var.agent_namespaces[0]
      certificateArn = module.ingress[0].certificate_arn
      wafWebAclArn   = length(module.ingress_waf) > 0 ? module.ingress_waf[0].web_acl_arn : ""
      scheme         = var.ingress_scheme
      domainName     = module.ingress[0].domain_name

      # The provider the listener rule sends a caller to. The client secret is not here: it is a
      # Kubernetes Secret the rule names, so the value never passes through these values.
      #
      # RENAMED FIELD BY FIELD, NOT PASSED THROUGH. Terraform objects are snake_case and the chart
      # reads camelCase; passed through, only `issuer` would match, and the chart would render the
      # authenticated route (issuer being non-empty is what selects it) with empty endpoints. A
      # listener rule with no authorization endpoint is the gate configured to send a caller nowhere.
      oidc = {
        issuer                = module.ingress[0].oidc.issuer
        authorizationEndpoint = module.ingress[0].oidc.authorization_endpoint
        tokenEndpoint         = module.ingress[0].oidc.token_endpoint
        userInfoEndpoint      = module.ingress[0].oidc.user_info_endpoint
        clientId              = module.ingress[0].oidc.client_id
      }

      # The CIDRs the load balancer's ENIs live in, so the agent's own network policy can admit
      # the health check and the forwarded request. Without this ingress is programmed
      # correctly and every request times out at the target.
      loadBalancerCidrs = sort([for s in data.aws_subnet.ingress : s.cidr_block])

      # Internet-facing only: pin the load balancer to the public subnets whose CIDRs are admitted
      # above, behind the Terraform-owned group that admits the allowlist. Internal leaves both
      # empty, and the controller picks the private subnets by tag and makes its own group.
      subnetIds        = local.ingress_internet_facing ? local.ingress_subnet_ids : []
      securityGroupIds = local.ingress_internet_facing ? [module.ingress[0].load_balancer_security_group_id] : []

      # The Cognito form of the same decision. Set whenever ingress is, except with
      # ingress_idp = "oidc-direct", where it is null and the chart renders authenticate-oidc
      # from `oidc` above instead.
      cognito = module.ingress[0].cognito

      # The controller that writes the agents' DNS records. Terraform cannot: the record is an alias
      # to a load balancer that does not exist until the chart syncs and the Gateway programs.
      dnsReconciler = {
        namespace      = module.ingress[0].dns_reconciler_namespace
        serviceAccount = module.ingress[0].dns_reconciler_service_account
        roleArn        = module.ingress[0].dns_reconciler_role_arn
        zoneId         = module.ingress[0].agent_zone_id
      }
      } : {
      # Same attribute set with ingress off, because a conditional in Terraform must return
      # one type. An absent `ingress` block would also work, but an explicit `enabled: false`
      # keeps the chart's own default from being the only thing that says so.
      enabled           = false
      namespace         = var.agent_namespaces[0]
      certificateArn    = ""
      wafWebAclArn      = ""
      scheme            = var.ingress_scheme
      domainName        = ""
      oidc              = null
      cognito           = null
      dnsReconciler     = null
      loadBalancerCidrs = []
      subnetIds         = []
      securityGroupIds  = []
    }


    # The chat UI, rendered by the base chart when enable_chat_ui is on. Its hostname prefix stays the
    # chart's default (`chat`), which is the name added to the callback list above.
    chatUi = {
      enabled = var.enable_chat_ui
      agents  = var.chat_ui_agents
    }

    # Acting with a person's own authority (enable_person_access). The agent pod gets the role and
    # bucket; the chat UI forwards a signed-in person's access token; a tool verifies a person's
    # token against the issuer for either client. Empty map with it off, never null (see ingress).
    personAccess = var.enable_person_access ? {
      enabled = true
      # One role per agent in person_access_agents; an agent not listed gets an empty
      # AGENT_PERSON_ROLE_ARN (gitops/base/templates/_agent-pod.tpl).
      agents        = module.person_access[0].agents
      roleArnPrefix = module.person_access[0].role_arn_prefix
      bucket        = module.person_access[0].bucket
      issuer        = module.person_access[0].issuer
      clientIds     = compact([module.person_access[0].api_client_id, try(module.ingress[0].cognito.userPoolClientId, "")])
      # The agent's AgentCore on-behalf-of exchange (person_access_delegated_token): the audience a
      # delegated token names, the issuer its actor comes from, which Cognito client is which
      # agent, and the prefix of each agent's credential provider and workload identity.
      tokenExchange = var.person_access_delegated_token ? {
        enabled        = true
        mode           = "agentcore"
        audience       = module.person_delegation[0].tool_audience
        actorIssuer    = module.person_access[0].issuer
        actorClients   = module.person_delegation[0].actor_clients
        resourcePrefix = module.person_delegation[0].provider_name_prefix
        } : {
        enabled        = false
        mode           = ""
        audience       = ""
        actorIssuer    = ""
        actorClients   = {}
        resourcePrefix = ""
      }
      } : {
      enabled       = false
      agents        = []
      roleArnPrefix = ""
      bucket        = ""
      issuer        = ""
      clientIds     = []
      tokenExchange = {
        enabled        = false
        mode           = ""
        audience       = ""
        actorIssuer    = ""
        actorClients   = {}
        resourcePrefix = ""
      }
    }

    registry = var.agent_image_registry == "" ? module.cluster.ecr_repository_urls : {
      for repo, _ in module.cluster.ecr_repository_urls :
      repo => "${trimsuffix(var.agent_image_registry, "/")}/${repo}"
    }

    agents = {
      for k, m in module.agent_identity : k => {
        namespace          = m.namespace
        serviceAccount     = m.service_account
        roleArn            = m.role_arn
        checkpointPrefix   = m.checkpoint_prefix
        sessionTagsEnabled = m.session_tags_enabled
      }
    }
  })
}


# ---------------------------------------------------------------------------
# The consent receiver's identity (AgentCore mode)
# ---------------------------------------------------------------------------
#
# CompleteResourceTokenAuth, and read access to the OAuth client secrets AgentCore exchanges the code
# with on this role's credentials. It holds no token; the token stays in AgentCore Identity's vault.
resource "aws_iam_role" "consent" {
  count = length(var.agentcore_consent) > 0 && var.enable_gateway ? 1 : 0
  name  = "${var.name}-consent-receiver"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "pods.eks.amazonaws.com" }, Action = ["sts:AssumeRole", "sts:TagSession"] }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy" "consent" {
  count = length(var.agentcore_consent) > 0 && var.enable_gateway ? 1 : 0
  name  = "complete-resource-token-auth"
  role  = aws_iam_role.consent[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "CompleteSessionBinding"
      Effect   = "Allow"
      Action   = ["bedrock-agentcore:CompleteResourceTokenAuth"]
      Resource = ["arn:${data.aws_partition.current.partition}:bedrock-agentcore:${var.region}:${data.aws_caller_identity.current.account_id}:*"]
      },
      # CompleteResourceTokenAuth exchanges the provider's code ON THE CALLER'S CREDENTIALS: AgentCore
      # reads the OAuth client secret as this role, and without the grant the binding fails with
      # "Access denied when retrieving the provided secret".
      {
        Sid      = "ReadOAuthClientSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [for _, p in var.oauth2_providers : "arn:${data.aws_partition.current.partition}:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${p.secret_id}-*"]
    }]
  })
}

resource "aws_eks_pod_identity_association" "consent" {
  count           = length(var.agentcore_consent) > 0 && var.enable_gateway ? 1 : 0
  cluster_name    = module.cluster.cluster_name
  namespace       = "consent"
  service_account = "consent-receiver"
  role_arn        = aws_iam_role.consent[0].arn
  tags            = local.tags
}

locals {
  # The agent images this configuration needs a repository for, by component; see
  # var.ecr_repository_names. A repository that exists and is not listed is planned for deletion,
  # which ECR refuses while it holds images (force_delete is off).
  ecr_repository_names = var.ecr_repository_names != null ? var.ecr_repository_names : concat(
    # agents/reasoning and agents/mcp-server are in the base too, though only the gateway's image and
    # the MCP example use them: these hold images a team pushes, and a list that dropped them when
    # enable_gateway goes off would plan their deletion, which ECR refuses while they hold images --
    # the apply would fail after it had already removed the rendered values file.
    # On aws-services the MCP server runs without the gateway, in mcp-servers.
    ["agents/reasoning-direct", "agents/execution", "agents/reasoning", "agents/mcp-server"],
    # A component's own repository is created when the component is turned on and KEPT once it
    # exists: turning the component off would otherwise plan its deletion, which ECR refuses while it
    # holds images, and the apply fails part-way -- after destroying the component's other resources
    # and removing the rendered values file. The
    # teardown script deletes every repository with this cluster's prefix.
    [for repo, on in local.ecr_component_repositories : repo
    if on || contains(coalesce(data.aws_ecr_repositories.existing.names, []), "${var.name}/${repo}")],
  )
  ecr_component_repositories = {
    "agents/chat-ui"          = var.enable_chat_ui
    "agents/evals"            = var.enable_evaluations
    "agents/consent-receiver" = length(var.agentcore_consent) > 0 && var.enable_gateway
  }
}

# Which repositories already exist in the Region, for the components' repositories above.
data "aws_ecr_repositories" "existing" {}
