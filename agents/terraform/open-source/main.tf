# The open source path of the reference sample, in Terraform.
#
# What this root module provisions is the AWS footprint: the EKS Auto Mode cluster, the EKS
# Capabilities the platform team interface runs on, ECR, the checkpoint bucket, each agent's IAM
# role and Pod Identity association, and the gateway's role and brokered credentials.
#
# What runs inside the cluster is not here. Argo CD reconciles it from Git:
#
#   ../../gitops/bootstrap/open-source/   the root Application
#   ../../gitops/platform/open-source/    Istio, AgentGateway, agent-sandbox, Prometheus, Grafana,
#                                         Langfuse, Redis, pgvector, Mem0
#   ../../gitops/base/                    the admission policy, the cluster-scoped egress policy,
#                                         and the agent resource definition
#
# Two systems that both believe they own in-cluster state is the failure this split avoids. The
# boundary is: if it is an AWS API call, it is here; if it is a Kubernetes object, it is in Git.
#
# Two properties are worth knowing before adopting this: the
# mesh issues the workload identity, so it is scoped to this cluster, and per-agent AWS authority
# comes from the gateway's mapping to these roles rather than from an IAM policy condition.

# Every subnet the existing cluster registered, so the private ones can be told from the public.
data "aws_subnet" "existing_cluster" {
  for_each = var.create_cluster ? toset([]) : toset(data.aws_eks_cluster.existing[0].vpc_config[0].subnet_ids)
  id       = each.value
}

# REFUSE RATHER THAN PLACE AGENTS ON A PUBLIC SUBNET.
#
# A `check` block is the WRONG TOOL: check blocks only ever emit WARNINGS. They never fail a plan
# or an apply, so such a guard prints a caution and then places the agents' nodes on public
# subnets anyway.
#
# A `precondition` on a resource DOES fail the plan, so the guard hangs off a `terraform_data` that
# exists for no other purpose. It is created only in the case being guarded, so a cluster this root
# creates and an explicit `subnet_ids` both skip it entirely.
resource "terraform_data" "private_subnet_guard" {
  count = !var.create_cluster && length(var.subnet_ids) == 0 ? 1 : 0

  input = length(local.cluster_private_subnet_ids)

  lifecycle {
    precondition {
      condition     = length(local.cluster_private_subnet_ids) > 0
      error_message = "Attaching to ${var.name}, but every subnet it registers has MapPublicIpOnLaunch = true, so there is no private subnet to place the agents' nodes in -- and those pods run untrusted model-written code. Set `subnet_ids` to the private subnets you want them in. List the candidates with: aws ec2 describe-subnets --filters Name=vpc-id,Values=<the cluster's vpc> --query 'Subnets[?!MapPublicIpOnLaunch].[SubnetId,AvailabilityZone]' --output text"
    }
  }
}

# The cluster this root is attaching to, when it is not creating one. Read here as well as in the
# module because the network locals below need it before the module is instantiated.
data "aws_eks_cluster" "existing" {
  count = var.create_cluster ? 0 : 1
  name  = var.name
}

locals {
  # The ingress namespace: its browser-gated routes and rules, and the direct OIDC client
  # secret. Written into the base chart's values as namespaces.ingress and handed to
  # platform-secrets, so the routes, the Secret and the eks:managed grant agree on one name.
  ingress_namespace = "ingress"

  # The evaluation runner's namespace and service account (gitops/charts/agent-evals). The gateway
  # binds /judge/<serviceAccount> to exactly this subject, the base chart creates the namespace and
  # admits it on each agent's network policy, and platform-secrets syncs the Langfuse keys into it --
  # four consumers, one name.
  evals_namespace       = "agent-evals"
  evals_service_account = "agent-evals"
}

locals {
  tags = merge(var.tags, {
    "eks-agents/path" = "open-source"
  })

  # Every agent's role, which is also exactly the set the gateway may assume. Deriving it rather
  # than listing it twice is what keeps an agent from being added to the cluster and silently left
  # out of the gateway's trust, which would fail at the first model call rather than at apply.
  agent_role_arns = [for k, m in module.agent_identity : m.role_arn]

  # The network the rest of this configuration builds on, in precedence order: yours if you supplied
  # one; the EXISTING CLUSTER'S if you are attaching to one; the one this root created otherwise.
  # Everything downstream reads these rather than the variables, so a module cannot accidentally be
  # wired to an empty vpc_id.
  #
  # THE EXISTING CLUSTER'S NETWORK IS NOT OPTIONAL WHEN create_cluster IS FALSE. A cluster lives in
  # exactly one VPC, and a second VPC with no peering to it is not a configuration anything in this
  # stack can use: the bastion could not reach the API endpoint, a NodeClass naming those subnets
  # would launch nodes that join nothing, and the apply would succeed. So this derives the network
  # from the cluster rather than building one.
  vpc_id = var.vpc_id != "" ? var.vpc_id : (
    var.create_cluster ? module.network[0].vpc_id : data.aws_eks_cluster.existing[0].vpc_config[0].vpc_id
  )
  # PRIVATE ONLY, and this is a security boundary rather than a preference.
  #
  # A cluster's vpc_config lists every subnet its owner registered for control-plane ENIs, and on an
  # eksctl-built cluster that is frequently ALL PUBLIC. These same subnet ids are handed to
  # nodeClass.subnetIds below, so taking the set wholesale launches the agents' nodes -- the ones
  # running untrusted model-written code -- into public subnets with public IPs. The create path
  # uses the network module's private_subnet_ids, so attaching to a cluster is the only way to get
  # a public one, and it would happen silently.
  #
  # An eksctl-created cluster, for example, can register only its public subnets
  # (eksctl-...-cluster/SubnetPublic<AZ>), all with MapPublicIpOnLaunch = true.
  #
  # MapPublicIpOnLaunch is the discriminator. It is a property of the subnet rather than an
  # inference from route tables, so it is cheap and it is what actually decides whether a node gets
  # a public address. It is a convention, not a guarantee -- a subnet can route to an internet
  # gateway with this false -- which is why the precondition below REFUSES rather than guessing, and
  # why `subnet_ids` remains the explicit override.
  cluster_private_subnet_ids = var.create_cluster ? [] : [
    for s in data.aws_subnet.existing_cluster : s.id if !s.map_public_ip_on_launch
  ]

  subnet_ids = length(var.subnet_ids) > 0 ? var.subnet_ids : (
    var.create_cluster ? module.network[0].private_subnet_ids : local.cluster_private_subnet_ids
  )

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
  # No network module when attaching to a cluster: it already has one, and the locals above
  # read it from the cluster.
  count = var.vpc_id == "" && var.create_cluster ? 1 : 0

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
      error_message = "enable_bastion = false needs the public API endpoint (cluster_endpoint_public_access = true, or an existing cluster whose endpoint is already public): with a private-only endpoint the bastion is the only path to kubectl. Set cluster_endpoint_public_access = true to run everything from this machine, or keep the bastion."
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

  create_cluster = var.create_cluster

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
  enable_capability_argocd         = var.enable_argocd || var.argocd_idc_instance_arn != ""
  argocd_idc_instance_arn          = var.argocd_idc_instance_arn
  argocd_idc_region                = var.argocd_idc_region
  argocd_rbac_role_mappings        = var.argocd_rbac_role_mappings
  argocd_manage_admin_group        = var.argocd_manage_admin_group
  argocd_admin_group_name          = var.argocd_admin_group_name
  argocd_admin_users               = var.argocd_admin_users
  argocd_admin_existing_user_names = var.argocd_admin_existing_user_names

  # The cluster-level setting the ingress Gateway needs. Without it the Gateway and
  # GatewayClass are accepted by the API server and claimed by no controller, so routes never
  # program and the symptom is a route that looks fine and serves nothing.
  enable_gateway_api                 = var.enable_ingress
  argocd_vpce_ids                    = var.argocd_vpce_ids
  argocd_codecommit_repository_arns  = var.argocd_codecommit_repository_arns
  argocd_codeconnections_arns        = var.argocd_codeconnections_arns
  argocd_secrets_manager_secret_arns = var.argocd_secrets_manager_secret_arns
  argocd_ecr_pull                    = var.argocd_ecr_pull
  argocd_cluster_access_policy_arn   = var.argocd_cluster_access_policy_arn
  ecr_repository_names               = local.ecr_repository_names
  ecr_force_delete                   = var.ecr_force_delete

  tags = local.tags
}

# ---------------------------------------------------------------------------
# The host that can reach the cluster
# ---------------------------------------------------------------------------
#
# ON BY DEFAULT, because without it `terraform apply` hands back a cluster whose documented next
# step is impossible. The API endpoint is private-only by design, so every kubectl command in the
# README -- bootstrapping GitOps, the four verification checks, all of scripts/exercise.sh -- needs
# something inside the VPC to run from. This is that host: SSM-only, no public IP, no inbound
# security group rules.
#
# enable_bastion = false is accepted only with the public endpoint on (cluster_endpoint_public_access,
# or an existing cluster whose endpoint is already public): everything then runs from the
# workstation. With a private-only endpoint the bastion is the way in.
#
# Not created when you supply your own subnets without a private one -- see the precondition.

# ---------------------------------------------------------------------------
# Interface VPC endpoints (vpc_endpoints)
# ---------------------------------------------------------------------------
module "vpc_endpoints" {
  source = "../modules/vpc-endpoints"
  count  = length(var.vpc_endpoints) > 0 ? 1 : 0

  name       = var.name
  region     = var.region
  vpc_id     = local.vpc_id
  vpc_cidr   = length(module.network) > 0 ? module.network[0].vpc_cidr : var.vpc_cidr
  subnet_ids = local.subnet_ids

  # The issuer's endpoint comes with eks: the eks endpoint's private DNS zone covers
  # oidc.eks.<region>.amazonaws.com, which the oidc-eks endpoint's own zone answers.
  endpoints = setunion(var.vpc_endpoints, contains(var.vpc_endpoints, "eks") ? ["oidc-eks"] : [])

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

  # The first private subnet. A bastion is not an availability-sensitive workload: if its AZ is
  # down, recreate it.
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

# ---------------------------------------------------------------------------
# Per-agent identity
# ---------------------------------------------------------------------------

# One instance per agent. Each one is four objects: the role, its trust policy, its permission
# policy and the association. A platform team that would rather declare agents from the cluster
# uses the agent resource definition in gitops/base/templates instead and leaves var.agents empty; the
# two are alternatives and should not both own the same agent.
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

  bedrock_model_arns            = each.value.bedrock_model_arns
  bedrock_inference_profile_ids = each.value.bedrock_inference_profile_ids
  bedrock_guardrail_arn         = each.value.bedrock_guardrail_arn
  bedrock_guardrail_version     = each.value.bedrock_guardrail_version

  checkpoint_bucket_arn  = each.value.needs_checkpoints && var.enable_checkpoints ? module.checkpoints[0].bucket_arn : null
  checkpoint_kms_key_arn = each.value.needs_checkpoints ? var.kms_key_arn : null

  # The gateway may assume this agent's role, bound to this agent's mesh identity. An
  # execution-tier agent sets reached_through_gateway to false: it has no network device, so there
  # is nothing for a gateway to be in the path of.
  # CONSTRUCTED, NOT READ FROM THE MODULE, and that is a dependency decision rather than a style
  # one. The gateway's IAM policy enumerates the agent roles it may assume, and each agent's trust
  # policy names the gateway role -- so reading `module.gateway`'s output here makes each module
  # wait for the other. With `count` on the gateway module that is a whole-module dependency and the
  # graph becomes a cycle ("module.gateway (close) -> ... -> module.agent_identity (close)").
  #
  # The name is this root's to choose and the module derives it the same way, so composing the ARN
  # breaks the edge without weakening anything. scripts/validate.sh asserts the two agree.
  #
  # reached_through_gateway with no gateway deployed is a contradiction rather than a default: there
  # is no role to assume the agent's identity, so it resolves to "assumable by nobody".
  assumable_by_role_arns = each.value.reached_through_gateway && var.enable_gateway ? [local.gateway_role_arn] : []
  gateway_identity_claim = each.value.reached_through_gateway ? "spiffe://${var.mesh_trust_domain}/ns/${each.value.namespace}/sa/${coalesce(each.value.service_account, each.key)}" : null

  session_policy_json = each.value.session_policy_json
  extra_policy_json   = each.value.extra_policy_json

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Egress: AgentGateway
# ---------------------------------------------------------------------------

module "gateway" {
  source = "../modules/egress-agentgateway"

  # NO GATEWAY, NO GATEWAY IAM. With enable_gateway = false there is nothing to hold the role or the
  # third-party secrets, and creating them anyway would leave a role that can
  # assume every agent identity with no workload entitled to use it. That is a standing credential
  # for a component that is not deployed.
  count = var.enable_gateway ? 1 : 0

  name         = var.name
  cluster_name = module.cluster.cluster_name
  cluster_arn  = module.cluster.cluster_arn

  agent_role_arns = local.agent_role_arns

  guardrail_arn = var.gateway_guardrail == null ? "" : var.gateway_guardrail.arn

  # When no agents are declared here, the agent resource definition composes them in-cluster and
  # their roles do not exist at apply time. Grant by path instead; see the variable's documentation.
  agent_role_path_arn     = length(var.agents) == 0 ? "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role${module.cluster.agent_role_path}*" : ""
  third_party_credentials = var.third_party_credentials

  credential_kms_key_arn = var.kms_key_arn
  # The admins, plus the one reader that projects these secrets into the gateway's namespace
  # (module.platform_secrets, below). By name rather than by reference: the reader's policy names
  # these secrets, so a reference each way would be a cycle.
  credential_admin_principal_arns = concat(
    var.credential_admin_principal_arns,
    length(var.third_party_credentials) > 0 && var.enable_platform_secrets ? [local.gateway_secret_reader_arn] : [],
  )

  enable_mesh_private_ca = var.enable_mesh_private_ca
  mesh_trust_domain      = var.mesh_trust_domain

  enable_bedrock_marketplace_subscribe = var.enable_bedrock_marketplace_subscribe

  # The evaluation judge, a gateway principal with its own role. See the module's judge note.
  judge = var.enable_evaluations ? {
    model_arns               = var.evaluation_judge_model_arns
    role_path                = module.cluster.agent_role_path
    permissions_boundary_arn = module.cluster.agent_permissions_boundary_arn
  } : null

  tags = local.tags
}

# ---------------------------------------------------------------------------
# What the GitOps side needs to know
# ---------------------------------------------------------------------------

# The one place the two halves meet. Argo CD reconciles Kubernetes objects that have to name AWS
# resources Terraform created: the gateway's Bedrock region, the checkpoint bucket, each agent's
# role ARN. Rendering them into a file the GitOps side reads is the alternative to hand-copying
# ARNs into manifests, which is where a stack like this usually drifts.
#
# Commit the rendered file. It carries no secret: role ARNs, a bucket name and hostnames, all of
# which appear in the cluster anyway. The brokered credential values are in Secrets Manager and
# never pass through here.
# ---------------------------------------------------------------------------
# Cost allocation tags
# ---------------------------------------------------------------------------
#
# The gateway stamps `agent` and `cluster` as session tags on every model call it signs, and the
# agent roles permit sts:TagSession -- but a user-defined tag reaches the Cost and Usage Report only
# once it is ACTIVATED, and until then per-agent model spend is recorded on each session and
# reported nowhere. Activation is not retroactive, so the cost before it stays unsplit.
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
  #   On this path the gateway signs as the CALLING AGENT, so iamPrincipal/agent splits Bedrock
  #   spend per agent.
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

  # Cognito's token exchange needs managed login on the pool's domain.
  managed_login = var.enable_person_access && var.person_access_delegated_token

  tags = local.tags
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

  allow_password_auth = var.person_access_password_auth

  # The gateway may assume each agent's person role for a verified person (person_access_via_gateway).
  gateway_role_arn = var.person_access_via_gateway ? one(module.gateway[*].gateway_role_arn) : ""
  gateway_services = { for svc, cfg in var.person_access_gateway_services : svc => { statements = cfg.statements } }
  tags             = local.tags
}

# The gateway's side of person_access_via_gateway: it may assume the agents' person roles, and only
# with session tags (the roles' trust requires them). Its own role otherwise reaches only agent roles.
resource "aws_iam_role_policy" "gateway_person_roles" {
  count = var.enable_person_access && var.person_access_via_gateway ? 1 : 0

  name = "assume-person-roles"
  role = element(split("/", one(module.gateway[*].gateway_role_arn)), length(split("/", one(module.gateway[*].gateway_role_arn))) - 1)
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumePersonRolesWithTags"
      Effect   = "Allow"
      Action   = ["sts:AssumeRole", "sts:TagSession"]
      Resource = values(module.person_access[0].role_arns)
    }]
  })
}

# An alert when what decides who an agent acts for changes: the gateway's role, the person roles,
# the Pod Identity associations on the cluster and the user pool (identity_change_alerts).
module "identity_change_alerts" {
  count  = var.enable_person_access && var.identity_change_alerts ? 1 : 0
  source = "../modules/identity-change-alerts"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name         = var.name
  region       = var.region
  account_id   = data.aws_caller_identity.current.account_id
  cluster_name = module.cluster.cluster_name
  user_pool_id = module.ingress[0].cognito_user_pool_id
  role_names = concat(
    [for arn in values(module.person_access[0].role_arns) : element(split("/", arn), length(split("/", arn)) - 1)],
    var.person_access_via_gateway ? [element(split("/", one(module.gateway[*].gateway_role_arn)), length(split("/", one(module.gateway[*].gateway_role_arn))) - 1)] : [],
  )
  emails = var.identity_change_alert_emails
  tags   = local.tags
}

# One token naming the person and the agent (person_access_delegated_token): the gateway exchanges
# the person's access token and the agent's own token at the pool. See
# terraform/modules/person-delegation.
module "person_delegation" {
  count  = var.enable_person_access && var.person_access_delegated_token ? 1 : 0
  source = "../modules/person-delegation"

  name         = var.name
  user_pool_id = module.ingress[0].cognito_user_pool_id
  actor_issuer = module.cluster.cluster_oidc_issuer_url
  # The gateway's audience: the actor is the token the agent already presents to the gateway.
  actor_audience = "agentgateway"
  # The reader that projects it into the gateway's namespace (module.platform_secrets), by name to
  # avoid a cycle, and the administrators.
  secret_reader_arns = concat([local.gateway_secret_reader_arn], var.credential_admin_principal_arns)
  tags               = local.tags

  # The ingress module's domain switches to managed login in the same apply; exchange is refused
  # until it has.
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

# ---------------------------------------------------------------------------
# The platform's own secrets
# ---------------------------------------------------------------------------
#
# Five components read a Kubernetes Secret that nothing created, and each one waits indefinitely
# without it with the reason only in `kubectl describe pod`. This generates the values into Secrets
# Manager; gitops/platform/open-source/templates/45-platform-secrets.yaml projects them into the cluster
# through the Secrets Store CSI driver.
module "platform_secrets" {
  count  = var.enable_platform_secrets ? 1 : 0
  source = "../modules/platform-secrets"

  name         = var.name
  cluster_name = module.cluster.cluster_name
  cluster_arn  = module.cluster.cluster_arn

  # The ingress direct OIDC client, synced into its namespace for the listener rule; and the
  # Langfuse project keys, into the evaluation runner's when evaluation is on.
  namespaces            = { ingress = local.ingress_namespace, evals = local.evals_namespace, gateway = local.gateway_namespace }
  include_evals         = var.enable_evaluations
  include_observability = var.enable_observability
  include_session_state = var.enable_session_state
  include_langfuse      = var.enable_langfuse
  include_memory_db     = var.enable_consolidation

  # The gateway's third-party credentials (GitHub, Slack...), owned by module.gateway and set out of
  # band, projected into the gateway's namespace as agentgateway-<key> for its secretRef.
  external_secrets = merge(var.enable_gateway ? {
    for k, arn in one(module.gateway[*].third_party_secret_arns) : "agentgateway-${k}" => {
      namespace = local.gateway_namespace
      arn       = arn
      sm_name   = one(module.gateway[*].third_party_secret_names)[k]
      keys      = ["token"]
    }
    } : {},
    # The token-exchange client's secret, for the gateway's oauthTokenExchange on the person-token
    # MCP backend (person_access_delegated_token).
    var.enable_person_access && var.person_access_delegated_token ? {
      agentgateway-token-exchange = {
        namespace = local.gateway_namespace
        arn       = module.person_delegation[0].secret_arn
        sm_name   = module.person_delegation[0].secret_name
        keys      = ["clientSecret"]
      }
  } : {})
  ingress_oidc = var.enable_ingress && var.ingress_idp == "oidc-direct" ? {
    client_id         = var.ingress_oidc.client_id
    client_secret_arn = var.ingress_oidc.client_secret_arn
  } : null

  tags = { "eks-agents/cluster" = var.name }
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
  # The gateway role's ARN, composed rather than read. See the note at assumable_by_role_arns.
  gateway_role_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-agentgateway"

  # The gateway's namespace, and the platform-secrets reader role that syncs the third-party
  # credentials into it (terraform/modules/platform-secrets names it <name>-secrets-gateway).
  gateway_namespace         = "agentgateway-system"
  consent_namespace         = "consent"
  gateway_secret_reader_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-secrets-gateway"
}

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
    var.mesh_mode == "none" ? ["19-istio-namespace.yaml", "20-istio.yaml"] : [],
    # CRD-only Applications, each synced with the component that needs it and not before: the base
    # chart composes no Gateway API kind unless the gateway or ingress is on (rendered and
    # checked by scripts/validate.sh), and the gateway.k8s.aws kinds are the ingress alone.
    # On a full install these two are the slowest Applications to converge.
    var.enable_gateway || var.enable_ingress ? [] : ["10-gateway-api-crds.yaml"],
    # Session state (valkey), and the secret sync, which is installed only when something reads a
    # generated or synced secret.
    var.enable_session_state ? [] : ["60-memory.yaml"],
    # Semantic recall (pgvector) and its operator. Excluded rather than gated by a commented-out
    # sync, so the base's Argo CD shows no Application for it at all.
    var.enable_semantic_recall ? [] : ["61-semantic-recall.yaml"],
    local.platform_secrets_in_use ? [] : ["45-platform-secrets.yaml"],
    var.enable_gateway ? [] : [
      "29-agentgateway-crds.yaml",
      "30-agentgateway.yaml",
      "31-agentgateway-config.yaml",
    ],
    # external-dns writes the ingress records and reads a values file Terraform renders only with
    # ingress on; synced without it, the Application fails on the missing file.
    var.enable_ingress ? [] : ["12-external-dns.yaml"],
    # KEDA, which starts a task agent's pods from its queue.
    var.enable_agent_tasks ? [] : ["13-keda.yaml"],
    # The collector, Prometheus, Grafana and the dashboard.
    var.enable_observability ? [] : ["50-observability.yaml"],
    var.enable_langfuse ? [] : ["51-langfuse.yaml"],
    var.enable_evaluations ? [] : ["52-agent-evals.yaml"],
    length(var.oauth_consent) > 0 && var.enable_gateway ? [] : ["46-consent-receiver.yaml"],
  )

  # Argo CD takes ONE pattern, not a list, and brace expansion is how it takes several. A single
  # entry must NOT be braced -- `{a.yaml}` is matched literally and excludes nothing, which is the
  # silent-failure shape: the sync succeeds and syncs the file you meant to leave out.
  # Whether the platform-secrets Application syncs: exactly when the module syncs some secret,
  # read from the module's own map of them rather than a list of readers kept here. A separate list
  # can miss a reader, such as person_access_delegated_token's exchange client, and then the
  # gateway's Secret never arrives and every delegated tool call fails.
  platform_secrets_in_use = var.enable_platform_secrets && one(module.platform_secrets[*].in_use) == true


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

# The collector's traces exporters, rendered from enable_langfuse so that turning Langfuse on also
# points the agents' traces at it. Read by the opentelemetry-collector Application through Argo CD's
# `$values` source. Without it, Langfuse would receive no traces and the evaluation runner would
# find no sessions to grade.
resource "local_file" "collector_values" {
  count = var.write_gitops_values ? 1 : 0

  filename        = "${dirname(abspath(path.module))}/../gitops/platform/open-source/collector-values.yaml"
  file_permission = "0644"

  content = join("\n", [
    "# Written by terraform/open-source from enable_langfuse. Do not edit by hand: the next apply",
    "# overwrites it. Read by the opentelemetry-collector Application in 50-observability.yaml.",
    "#",
    "# The placeholder in Git is the Langfuse-off form. Nothing here is account-specific.",
    yamlencode(merge(
      {
        config = { service = { pipelines = { traces = {
          exporters = var.enable_langfuse ? ["debug", "otlphttp/langfuse"] : ["debug"]
        } } } }
      },
      # The export header, REQUIRED rather than optional: the pod waits for the Secret instead of
      # starting without it and being refused by Langfuse (see 50-observability.yaml).
      var.enable_langfuse ? {
        extraEnvs = [{
          name      = "LANGFUSE_OTLP_AUTHORIZATION"
          valueFrom = { secretKeyRef = { name = "langfuse-otlp", key = "authorization" } }
        }]
      } : {},
    )),
  ])
}

resource "local_file" "gitops_values" {
  count = var.write_gitops_values ? 1 : 0

  filename        = var.gitops_values_path
  file_permission = "0644"

  content = yamlencode({
    # Written by terraform/open-source. Do not edit by hand: the next apply overwrites it.
    accountId = data.aws_caller_identity.current.account_id
    partition = data.aws_partition.current.partition

    # The capability role names, so the base chart can grant kro the Kubernetes RBAC it needs to
    # compose an agent. Without that binding the resource definition never reconciles, and the
    # failure is silent.
    capabilities = {
      kro = { roleName = module.cluster.capability_role_names.kro }
      ack = { roleName = module.cluster.capability_role_names.ack }
    }
    path    = "open-source"
    cluster = module.cluster.cluster_name
    region  = var.region

    # The guardrail agentgateway-config applies to every model request and response
    # (gateway_guardrail). Off renders no processor.
    promptGuard = {
      enabled             = var.gateway_guardrail != null
      guardrailIdentifier = var.gateway_guardrail == null ? "" : var.gateway_guardrail.arn
      guardrailVersion    = var.gateway_guardrail == null ? "1" : var.gateway_guardrail.version
    }

    oidcIssuerUrl = module.cluster.cluster_oidc_issuer_url

    # The Secrets Manager names the SecretProviderClass objects read. Rendering them is also what
    # turns the chart on: it refuses to render a class naming a secret that does not exist, so a
    # cluster where this module is off gets no classes rather than mounts that fail at pod start.
    platformSecrets = var.enable_platform_secrets ? {
      enabled    = true
      secrets    = module.platform_secrets[0].chart_values
      namespaces = module.platform_secrets[0].namespaces
      # The base chart creates the ingress and the evaluation runner's namespaces, and the
      # gateway's charts create its own; this chart only syncs a secret into each.
      externallyOwnedNamespaces = [local.ingress_namespace, local.evals_namespace, local.gateway_namespace]
    } : { enabled = false, secrets = {}, namespaces = [], externallyOwnedNamespaces = [] }

    # Only the ingress and the evaluation runner's namespaces are Terraform's to name; the
    # chart's defaults hold the rest.
    namespaces = { ingress = local.ingress_namespace, evals = local.evals_namespace }

    # The third-party destinations the gateway brokers a credential for, read by agentgateway-config:
    # one per third_party_credentials entry, its credential the Kubernetes Secret the platform-secrets
    # syncer writes (agentgateway-<key>, key `token`), and the one agent allowed to use it.
    # The OAuth consent receiver, when oauth_consent names a client. Each client writes the secret of
    # the third_party_credentials entry with the same key.
    consent = {
      enabled        = length(var.oauth_consent) > 0 && var.enable_gateway
      namespace      = local.consent_namespace
      serviceAccount = "consent-receiver"
      publicBaseUrl  = var.consent_public_base_url
      port           = 8765
      clients = var.enable_gateway ? {
        for k, v in var.oauth_consent : k => {
          authorizeUrl    = v.authorize_url
          tokenUrl        = v.token_url
          clientId        = v.client_id
          clientSecretArn = v.client_secret_arn
          scopes          = v.scopes
          secretId        = one(module.gateway[*].third_party_secret_arns)[k]
          refreshSecretId = aws_secretsmanager_secret.consent_refresh[k].arn
        }
      } : {}
      syncer = { namespace = local.gateway_namespace, deployment = "platform-secrets-syncer" }
    }

    destinations = var.enable_gateway ? {
      for k, v in var.third_party_credentials : k => {
        host       = v.destination
        port       = 443
        secretName = "agentgateway-${k}"
        secretKey  = "token"
        callers    = [v.caller]
      }
    } : {}

    # Agent evaluation, read by three charts: the base chart (the runner's namespace, and the ingress
    # rule each agent composes for it), agentgateway-config (the judge's route, backend and subject
    # check) and agent-evals (the runner). One block so they cannot disagree on a name.
    evals = {
      enabled        = var.enable_evaluations
      namespace      = local.evals_namespace
      serviceAccount = local.evals_service_account
      backend        = "langfuse"
      judge = {
        # The judge's route on the in-cluster gateway. The OpenAI client appends /chat/completions.
        baseUrl        = var.enable_evaluations ? "http://egress.${one(module.gateway[*].gateway_namespace)}.svc.cluster.local:8080/judge/${local.evals_service_account}" : ""
        model          = "judge"
        audience       = var.gateway_audience
        roleArn        = var.enable_evaluations ? one(module.gateway[*].judge_role_arn) : ""
        bedrockModelId = var.evaluation_judge_model_id
      }
      agentcore = { logGroup = "", region = "", resultsName = "" }
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

    # THE FIRST OF THE THREE LAYERS, rendered here so the chart and the root Application's exclude
    # glob are decided by one variable rather than two that can disagree.
    #
    # Only `enabled` is rendered. Everything else under networkPolicy -- the AWS endpoints, the
    # in-cluster destinations, the infrastructure carve-out -- is a platform decision that belongs in
    # the chart's values where a reader can see it beside its comment, not in a Terraform variable.
    networkPolicy = {
      enabled              = var.enable_network_policy
      adminTierDefaultDeny = var.network_policy_admin_tier_default_deny
      # needsClusterApi's one destination, from the cluster's own service CIDR.
      kubernetesApiServiceIp = module.cluster.kubernetes_service_ip
      # The memory tier's Services, each named only while its component is on. The chart's default
      # would add Admin-tier Accept rules to a namespace the base does not have.
      inClusterDestinations = concat(
        var.enable_session_state ? [
          { name = "agent-session-state-valkey-primary", namespace = "agent-memory", ports = [6379] },
          { name = "agent-session-state-valkey-replicas", namespace = "agent-memory", ports = [6379] },
        ] : [],
        var.enable_semantic_recall ? [
          { name = "agent-semantic-recall-cluster-rw", namespace = "agent-memory", ports = [5432] },
          { name = "agent-semantic-recall-cluster-ro", namespace = "agent-memory", ports = [5432] },
        ] : [],
      )
    }

    # One value, read by every template that cares. "none" by default, like every other layer; when
    # the mesh is on, ambient is the recommendation because the per-node proxy is what makes arrival
    # at the gateway enforced rather than agreed.
    mesh = {
      mode        = var.mesh_mode
      trustDomain = var.mesh_trust_domain
    }

    # The public OCI registries a component's charts come from, registered with Argo CD by the base
    # chart only while that component is on (gitops/base/templates/05-oci-repositories.yaml).
    ociRepositories = {
      agentgateway  = var.enable_gateway
      clickhouse    = var.enable_langfuse
      bitnamicharts = var.enable_session_state
    }

    # enable_observability. Off, agents get no OTLP endpoint and no egress to the collector.
    observability = {
      enabled = var.enable_observability
    }

    # enable_consolidation: Mem0 as a library in the agent, on the pgvector tier. Empty secret ARN
    # renders none of the IAM grant, the egress rule, the embeddings route or the environment.
    memory = {
      # enable_session_state. Empty gives no agent an endpoint; the base chart's default names the
      # valkey Service 60-memory.yaml creates.
      sessionStateEndpoint = var.enable_session_state ? "agent-session-state-valkey-primary.agent-memory.svc.cluster.local:6379" : ""
      consolidation = {
        dbSecretArn      = var.enable_consolidation ? module.platform_secrets[0].memory_db_secret_arn : ""
        embeddingModelId = var.consolidation_embedding_model_id
        embeddingDims    = var.consolidation_embedding_dims
      }
    }

    gateway = {
      enabled        = var.enable_gateway
      namespace      = var.enable_gateway ? one(module.gateway[*].gateway_namespace) : "agentgateway-system"
      serviceAccount = var.enable_gateway ? one(module.gateway[*].gateway_service_account) : "egress"
      roleArn        = var.enable_gateway ? one(module.gateway[*].gateway_role_arn) : ""
      trustDomain    = var.mesh_trust_domain
      secretNames    = var.enable_gateway ? one(module.gateway[*].third_party_secret_names) : {}

      # One value, read by both charts: the base chart mints the agent's projected token for this
      # audience, and agentgateway-config checks an inbound token against it. Rendering it here
      # rather than defaulting it in each chart is what keeps them from drifting apart, because a
      # mismatch produces no error on either side -- only a rejected request.
      audience = var.gateway_audience
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
      # Turns a minute for each person a turn is for, in each agent's pod.
      turnsPerPersonPerMinute = var.agent_turns_per_person_per_minute
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

    # What an agent calls with no gateway (direct_model_id).
    model = {
      directModelId = var.direct_model_id
    }

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
      enabled        = false
      namespace      = var.agent_namespaces[0]
      certificateArn = ""
      wafWebAclArn   = ""
      scheme         = var.ingress_scheme
      domainName     = ""
      # EMPTY MAPS, NOT NULLS, and the difference is a failed render.
      #
      # Helm deep-merges maps across values files, but an explicit null REPLACES the chart's map
      # instead of merging into it -- so `oidc: null` here would turn every
      # `.Values.ingress.oidc.<key>` in the base chart into a nil dereference and the whole chart
      # would fail to render:
      #
      #   Error: ... at <.Values.ingress.oidc.issuer>: nil pointer evaluating interface {}.issuer
      #
      # THE TEMPLATES DO NOT DEPEND ON THIS being right -- they parenthesise the map and default
      # it -- but emitting `{}` is still the correct thing to write, because a null in a values file
      # means "delete the chart's default" and that is never what this block intends. It intends
      # "ingress is off, so these carry nothing".
      oidc              = {}
      cognito           = {}
      dnsReconciler     = {}
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
      # S3 through the gateway with the person's authority (person_access_via_gateway): one route
      # per agent, the gateway verifying the person's ID token against the pool for the api client.
      viaGateway = {
        enabled  = var.person_access_via_gateway
        audience = module.person_access[0].api_client_id
        region   = var.region
        # The other services' routes: signing name -> the service's host.
        services = { for svc, cfg in var.person_access_gateway_services : svc => (cfg.host != "" ? cfg.host : "${svc}.${var.region}.amazonaws.com") }
      }
      # One token naming the person and the agent (person_access_delegated_token): the gateway's
      # exchange on the person-token MCP route, and what the tool verifies.
      tokenExchange = var.person_access_delegated_token ? {
        enabled       = true
        tokenUrl      = module.ingress[0].oidc.token_endpoint
        clientId      = module.person_delegation[0].client_id
        secretName    = "agentgateway-token-exchange"
        secretKey     = "clientSecret"
        audience      = module.person_delegation[0].audience
        actorProvider = module.person_delegation[0].actor_provider
        actorIssuer   = module.person_delegation[0].actor_issuer
        } : {
        enabled       = false
        tokenUrl      = ""
        clientId      = ""
        secretName    = ""
        secretKey     = ""
        audience      = ""
        actorProvider = ""
        actorIssuer   = ""
      }
      } : {
      enabled       = false
      agents        = []
      roleArnPrefix = ""
      bucket        = ""
      issuer        = ""
      clientIds     = []
      viaGateway    = { enabled = false, audience = "", region = "", services = {} }
      tokenExchange = {
        enabled       = false
        tokenUrl      = ""
        clientId      = ""
        secretName    = ""
        secretKey     = ""
        audience      = ""
        actorProvider = ""
        actorIssuer   = ""
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
        spiffeId           = "spiffe://${var.mesh_trust_domain}/ns/${m.namespace}/sa/${m.service_account}"
      }
    }
  })
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

  filename        = "${dirname(abspath(path.module))}/../gitops/platform/open-source/external-dns-values.yaml"
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

# ---------------------------------------------------------------------------
# The OAuth consent receiver's identity
# ---------------------------------------------------------------------------
#
# Writes the consented token into the destination's secret, and reads the OAuth app's client secret
# to exchange the code. Nothing else: it does not read the tokens it wrote (the destination secret's
# policy refuses GetSecretValue to all but the gateway and its syncer).
data "aws_iam_policy_document" "consent_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "consent" {
  count              = length(var.oauth_consent) > 0 && var.enable_gateway ? 1 : 0
  name               = "${var.name}-consent-receiver"
  description        = "The OAuth consent receiver: writes consented third-party tokens for the egress gateway."
  assume_role_policy = data.aws_iam_policy_document.consent_assume.json
  tags               = { "eks-agents/cluster" = var.name }
}

data "aws_iam_policy_document" "consent" {
  count = length(var.oauth_consent) > 0 && var.enable_gateway ? 1 : 0
  statement {
    sid       = "WriteConsentedTokens"
    actions   = ["secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
    resources = [for k, _ in var.oauth_consent : one(module.gateway[*].third_party_secret_arns)[k]]
  }
  statement {
    sid       = "KeepRefreshTokens"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
    resources = [for k, _ in var.oauth_consent : aws_secretsmanager_secret.consent_refresh[k].arn]
  }
  statement {
    sid       = "ReadOAuthClientSecrets"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = distinct([for _, v in var.oauth_consent : v.client_secret_arn])
  }
}

resource "aws_iam_role_policy" "consent" {
  count  = length(var.oauth_consent) > 0 && var.enable_gateway ? 1 : 0
  name   = "consent-receiver"
  role   = aws_iam_role.consent[0].id
  policy = data.aws_iam_policy_document.consent[0].json
}

resource "aws_eks_pod_identity_association" "consent" {
  count           = length(var.oauth_consent) > 0 && var.enable_gateway ? 1 : 0
  cluster_name    = module.cluster.cluster_name
  namespace       = local.consent_namespace
  service_account = "consent-receiver"
  role_arn        = aws_iam_role.consent[0].arn
  tags            = { "eks-agents/cluster" = var.name }
}

# The refresh token for each consented credential, where only the receiver reads it. A GitHub App's
# user token expires after 8 hours and its refresh token is single-use, so the receiver keeps the
# refresh token here and writes a new pair before expiry. The gateway never sees this secret.
resource "aws_secretsmanager_secret" "consent_refresh" {
  for_each    = var.enable_gateway ? var.oauth_consent : {}
  name        = "${var.name}/consent/${each.key}-refresh"
  description = "Refresh token for the ${each.key} consent; read and written by the consent receiver only."
  kms_key_id  = var.kms_key_arn

  recovery_window_in_days = 0
  tags                    = { "eks-agents/cluster" = var.name }
}

data "aws_iam_policy_document" "consent_refresh" {
  for_each = var.enable_gateway ? var.oauth_consent : {}
  statement {
    sid       = "OnlyTheReceiver"
    effect    = "Deny"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotEquals"
      variable = "aws:PrincipalArn"
      values   = concat(["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:role/${var.name}-consent-receiver"], var.credential_admin_principal_arns)
    }
  }
}

resource "aws_secretsmanager_secret_policy" "consent_refresh" {
  for_each   = var.enable_gateway ? var.oauth_consent : {}
  secret_arn = aws_secretsmanager_secret.consent_refresh[each.key].arn
  policy     = data.aws_iam_policy_document.consent_refresh[each.key].json
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
    "agents/consent-receiver" = length(var.oauth_consent) > 0 && var.enable_gateway
  }
}

# Which repositories already exist in the Region, for the components' repositories above.
data "aws_ecr_repositories" "existing" {}
