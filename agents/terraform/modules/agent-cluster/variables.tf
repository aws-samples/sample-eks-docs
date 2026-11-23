variable "name" {
  description = "Name prefix for the cluster and every resource this module creates."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$", var.name))
    error_message = "name must be a DNS label of at most 32 characters: lower-case letters, digits and dashes, starting and ending alphanumeric. It is used as a prefix for cluster, role and ECR names."
  }
}

variable "kubernetes_version" {
  description = <<-EOT
    EKS control plane version. The Nitro Sandbox runtime classes are present on every EKS Auto Mode
    cluster from the version the feature launched on. Both root modules default to 1.36, so the two
    paths create the same control plane. Raise it deliberately, not by tracking latest, and move
    bastion_kubectl_version with it.
  EOT
  type        = string
  default     = "1.36"
}

variable "vpc_id" {
  description = "VPC the cluster runs in. This module does not create a VPC: an agent platform belongs inside the network perimeter the organization already operates, not in a new one a template invented."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the cluster's ENIs and for Auto Mode nodes. Pass private subnets only. A public subnet here puts agent pods on nodes with public IPs, which is the exposure the agents-ingress page of the EKS User Guide calls out."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two Availability Zones."
  }
}

variable "auto_mode_node_pools" {
  description = <<-EOT
    EKS Auto Mode built-in node pools to enable. "general-purpose" is what sandboxed agent pods land
    on: the isolated-sandbox RuntimeClass carries its own scheduling constraints and Auto Mode brings
    up a sandbox-capable instance on demand, so there is no node pool, label or taint to configure for
    the sandbox itself. Add "system" if you run platform components that must not share nodes with
    tenant agents.
  EOT
  type        = list(string)
  default     = ["general-purpose", "system"]
}

variable "cluster_admin_principal_arns" {
  description = "IAM principal ARNs that get AmazonEKSClusterAdminPolicy through an access entry. Keep this to the platform team's own role; an agent never appears here."
  type        = list(string)
  default     = []
}

variable "enable_capability_argocd" {
  description = "Create the EKS Capability for Argo CD (type ARGOCD). EKS runs Argo CD off-cluster and manages it, so the GitOps control plane is not itself a workload on the cluster it reconciles. NEEDS AN IAM IDENTITY CENTER INSTANCE in this account and region, because CreateCapability requires configuration.argoCd.awsIdc even on a cluster where nobody will sign in to the UI. This module discovers the instance and creates the admin group, the users and the role mapping; the instance itself is one `aws sso-admin create-instance` call, because the AWS provider has no resource for it."
  type        = bool
  default     = false
}

# --- the Argo CD capability's configuration ----------------------------------
#
# ARGOCD is the one capability type that REQUIRES a configuration block. KRO and ACK take a name and
# a role and nothing else; creating ARGOCD without one fails at the API, not at plan time:
#
#   InvalidParameterException: Configuration is required for ARGOCD capability type
#
# `enable_capability_argocd` therefore defaults to false, so the rest of the stack applies on a
# cluster with no Identity Center, and turning it on tells you what it needs. Defaulting it to true
# without a configuration block makes `terraform apply` fail on every cluster.

variable "argocd_idc_instance_arn" {
  description = <<-EOT
    ARN of the AWS IAM Identity Center instance the managed Argo CD authenticates people against.

    LEAVE IT EMPTY. Discovery runs in argocd_idc_region, so it finds the instance whether or not it
    is in the cluster's region, and the group, users and memberships are created beside it. Setting
    argocd_idc_region is the whole of the cross-region configuration.

    Set this only to pin a specific instance rather than discover one.
  EOT
  type        = string
  default     = ""
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

variable "argocd_namespace" {
  description = "Namespace the managed Argo CD reconciles into."
  type        = string
  default     = "argocd"
}

variable "argocd_rbac_role_mappings" {
  description = "Who gets which Argo CD role, keyed on an Identity Center identity rather than on IAM. `role` is one of ADMIN, EDITOR, VIEWER; `identity_type` is SSO_USER or SSO_GROUP (not USER); `identity_id` is the Identity Store id, from `aws identitystore list-users` or `list-groups`. Prefer a group: a mapping to a user has to be edited when people change."
  type = list(object({
    role          = string
    identity_type = string
    identity_id   = string
  }))
  default = []

  validation {
    condition     = alltrue([for m in var.argocd_rbac_role_mappings : contains(["ADMIN", "EDITOR", "VIEWER"], m.role)])
    error_message = "role must be ADMIN, EDITOR or VIEWER -- the API rejects lowercase Argo CD role names such as \"admin\"."
  }

  validation {
    condition     = alltrue([for m in var.argocd_rbac_role_mappings : contains(["SSO_USER", "SSO_GROUP"], m.identity_type)])
    error_message = "identity_type must be SSO_USER or SSO_GROUP -- \"USER\" and \"GROUP\" are rejected."
  }
}

variable "argocd_manage_admin_group" {
  description = <<-EOT
    Create the Identity Center group that holds Argo CD ADMIN, and map it, rather than leaving both
    to the operator.

    ON BY DEFAULT, because the alternative is four manual steps between `terraform apply` and a
    working GitOps control plane: create a group, create or find a user, add the user to the group,
    then write an rbac_role_mapping naming the group's Identity Store id. Each one is an id copied
    by hand into a .tfvars file.

    Set false to manage the group and mappings yourself through argocd_rbac_role_mappings. Mappings
    you declare there are kept either way -- this appends, it does not replace.
  EOT
  type        = bool
  default     = true
}

variable "argocd_admin_group_name" {
  description = "Display name of the Identity Center group holding Argo CD ADMIN. Defaults to <cluster>-argocd-admins."
  type        = string
  default     = ""
}

variable "argocd_admin_users" {
  description = <<-EOT
    Identity Center users to CREATE and add to the Argo CD admin group.

    Identity Center creates a user without a password and has no API to set one: the person sets it
    at first sign-in, from the invitation Identity Center sends to `email`. So creating the user is
    the whole of what automation can do here, and the account is unusable until that sign-in.

    Use argocd_admin_existing_user_names instead for people who are already in the Identity Store,
    which is the normal case in an organization that has used Identity Center before.
  EOT
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
  description = "Identity Store user names that already exist and should hold Argo CD ADMIN. Looked up by user name; a name that matches nothing fails the apply rather than granting nobody."
  type        = list(string)
  default     = []
}

variable "argocd_vpce_ids" {
  description = "VPC endpoint ids that may reach the managed Argo CD, for keeping its API and UI off the internet. Empty leaves the capability's own default reachability."
  type        = list(string)
  default     = []
}

variable "enable_capability_kro" {
  description = "Create the EKS Capability for kro (type KRO). kro is what collapses the per-agent object set in gitops/base/templates into one agent-shaped resource."
  type        = bool
  default     = true
}

variable "enable_capability_ack" {
  description = "Create the EKS Capability for ACK (type ACK). ACK is what lets kro compose the per-agent AWS resources (the agent's IAM role and its Pod Identity association) from inside the cluster."
  type        = bool
  default     = true
}

variable "ack_managed_service_api_groups" {
  description = <<-EOT
    ACK API groups the capability role is permitted to act for, used to scope the role's permissions
    by the eks:kubernetes-api-group session tag that the managed ACK capability sets on every call.
    The default is the two groups the agent resource definition needs: IAM (the agent's role) and EKS
    (its Pod Identity association).

    This is the "simple setup" permission model. For production, move to IAM Role Selectors so each
    namespace assumes its own role and this role holds only sts:AssumeRole; see
    var.ack_assumable_role_arns and the agents-identity-agent page of the EKS User Guide.
  EOT
  type        = list(string)
  default     = ["iam.services.k8s.aws", "eks.services.k8s.aws"]
}

variable "ack_assumable_role_arns" {
  description = "Role ARNs the ACK capability role may assume, for the IAM Role Selector model. When non-empty, no AWS service permissions are attached to the capability role at all and the role scoping happens in these roles instead."
  type        = list(string)
  default     = []
}

variable "agent_permission_sets" {
  description = <<-EOT
    Named IAM permissions an Agent may attach to its own role (Agent spec.permissionSets), for an
    agent that calls an AWS service beyond the model and its checkpoints. The PLATFORM TEAM defines
    each set here; an Agent can only choose names. Each set becomes a managed policy under
    <ack_agent_role_path>permission-sets/ and is added to the agent permissions boundary, so the
    boundary caps every agent at the union of the sets and each agent holds only the sets it names.
    `namespaces` limits which agent namespaces may use a set (empty: every agent namespace).

    Refused here: actions in iam:, sts:, eks:, organizations: and ec2:, which the boundary denies to
    every agent whatever a set says, and "*" as an action.
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

  validation {
    condition     = alltrue([for k, _ in var.agent_permission_sets : can(regex("^[a-z0-9][a-z0-9-]{0,39}$", k))])
    error_message = "agent_permission_sets keys must be 1-40 characters of lowercase letters, digits and -."
  }
  validation {
    condition = alltrue(flatten([for _, v in var.agent_permission_sets : [for st in v.statements : [
      for a in st.actions : a != "*" && !can(regex("^(?i)(iam|sts|eks|organizations|ec2):", a))
    ]]]))
    error_message = "agent_permission_sets may not grant \"*\" or iam:, sts:, eks:, organizations: or ec2: actions: the agent permissions boundary denies those to every agent."
  }
}

variable "ack_agent_role_path" {
  description = "IAM path that per-agent roles are created under. The ACK capability role's iam:* permissions are scoped to this path, so a composed agent resource can create its own agent role and cannot create or alter a role anywhere else in the account."
  type        = string
  default     = "/eks-agents/"

  validation {
    condition     = can(regex("^/([a-zA-Z0-9+=,.@_-]+/)*$", var.ack_agent_role_path))
    error_message = "ack_agent_role_path must be an IAM path: it must start and end with / (for example /eks-agents/)."
  }
}

variable "agent_namespaces" {
  description = "Namespaces agents run in. The ACK capability role's permissions are scoped to these by the eks:kubernetes-namespace session tag, so an ACK resource created in any other namespace gets no AWS authority at all."
  type        = list(string)
  default     = ["agents"]

  validation {
    condition     = length(var.agent_namespaces) > 0
    error_message = "Set at least one agent namespace. An empty list would scope the ACK capability role's permissions to nothing and every composed agent would fail to get its identity."
  }
}

variable "gitops_repo_url" {
  description = "Git repository Argo CD reconciles the cluster from. Recorded as an output for the bootstrap step rather than configured on the capability, because the root Application is itself a Git-managed object (see gitops/bootstrap)."
  type        = string
  default     = ""
}

variable "ecr_repository_names" {
  description = "ECR repositories to create for agent images. Image scanning on push and immutable tags are set on every one: the isolated-sandbox runtime class does not decide which image runs, so the registry and admission control are where image governance lives on this stack."
  type        = list(string)
  default = [
    "agents/reasoning",
    # The same agent built with MODEL_ROUTE=bedrock-direct, for a platform with no egress gateway:
    # it calls Amazon Bedrock on the agent's own role. NOT the default image. See
    # apps/reference/Dockerfile and the agents-application-setup page of the EKS User Guide.
    "agents/reasoning-direct",
    "agents/execution",
    # The MCP server and the chat UI from gitops/examples. They are agent-adjacent workloads rather
    # than agents, and they get the same scan-on-push and immutable tags for the same reason.
    "agents/mcp-server",
    "agents/chat-ui",
    # The evaluation runner (apps/evals), for gitops/charts/agent-evals. Created whether or not
    # evaluation is enabled: an empty repository costs nothing, and enabling evaluation later should
    # not need a repository the build step cannot push to.
    "agents/evals",
    # The OAuth consent receiver (apps/consent-receiver), open source path, oauth_consent.
    "agents/consent-receiver",
  ]
}

variable "ecr_kms_key_arn" {
  description = "Customer-managed KMS key for ECR encryption at rest. Null uses the AES256 default."
  type        = string
  default     = null
}

variable "enable_cluster_log_types" {
  description = <<-EOT
    Control plane log types sent to CloudWatch Logs.

    `audit` IS NOT IN THE DEFAULT, AND THAT IS A COST DECISION rather than a security one. It is by
    far the highest-volume stream -- on an idle cluster most of it is controller chatter -- and this
    repository is a template people stand up to try, where that spend buys nothing. `api` and
    `authenticator` are low volume and still answer who authenticated and what the API server was
    asked.

    TURN IT ON FOR A CLUSTER THAT MATTERS: `["api", "audit", "authenticator"]`. The audit log is how
    a platform team answers which agent called the Kubernetes API, which is the question this stack's
    whole attribution story rests on, and it is the one record that survives an agent deleting its
    own traces. A production agent platform should have it.

    Whatever is enabled lands in `/aws/eks/<cluster>/cluster`, which this module creates so it
    carries a retention and so `terraform destroy` removes it. An EKS-created group has neither.
  EOT
  type        = list(string)
  default     = ["api", "authenticator"]
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "enable_gateway_api" {
  description = <<-EOT
    Enable the Kubernetes Gateway API on the cluster, which is what the agents' ingress in
    gitops/base/templates/45-agent-gateway-api.yaml needs.

    Implemented as a local-exec escape hatch, because the AWS provider cannot express the setting
    (hashicorp/terraform-provider-aws#50737). Needs an AWS CLI new enough to know the field.

    False leaves the Gateway and GatewayClass accepted by the API server and claimed by no
    controller, so routes never program. Leave it false if agents are reached only by other agents
    or by a schedule, which is the expose: cluster case.
  EOT
  type        = bool
  default     = false
}

variable "gateway_api_crds_managed" {
  description = <<-EOT
    Whether AWS owns the lifecycle of the Gateway API CRDs.

    False, deliberately. The CRDs are cluster-wide so exactly one party owns them, and this stack
    installs them pinned while Istio and AgentGateway both register GatewayClasses against them —
    handing ownership to AWS would let it replace CRDs those two depend on.

    True is right for a cluster running neither, and removes the pinned CRD Application from the
    GitOps side. AWS rejects the change if existing CRDs are below v1 rather than altering them.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# What the Argo CD capability may read, and where it may deploy
# ---------------------------------------------------------------------------
#
# THE CAPABILITY ROLE SHIPS WITH NO PERMISSIONS AND THAT IS NOT ENOUGH. Creating the capability
# gives its role a trust policy and nothing else, and it grants itself an EKS access entry carrying
# AmazonEKSArgoCDClusterPolicy, cluster-scoped, and AmazonEKSArgoCDPolicy on the `argocd` namespace.
# The cluster policy covers namespaces, creating CRDs and Argo CD's own kinds, and does not list or
# watch arbitrary resource types. With only that, every Application fails at the cluster-cache
# stage --
#
#   ComparisonError: ... failed to load initial state of resource ClusterRoleBinding...:
#   clusterrolebindings.rbac.authorization.k8s.io is forbidden
#
# -- because Argo CD builds its cache by listing every served API resource. The failure names
# whichever type it reaches first, so it looks like a problem with that type rather than a
# permissions gap; on a cluster with the ACK capability it lands on an ACK CRD and reads as a
# conflict between two capabilities. Chasing it with resource.exclusions does not work: each
# exclusion simply reveals the next unlistable type, and `argocd-cm` edits are not picked up because
# the controller is off-cluster and cannot be restarted.
#
# So two things have to be supplied, and neither is optional:
#
#   1. Repository permissions, below. Which ones depends on where the manifests live.
#   2. Cluster-wide read, and the cluster-scoped write this stack's objects need, via
#      argocd_cluster_access_policy_arn or, with it set to "", RBAC bound to the capability's
#      access entry group.

variable "argocd_codecommit_repository_arns" {
  description = <<-EOT
    CodeCommit repository ARNs the capability may pull from, granting `codecommit:GitPull`.

    This is the only repository source that is both inside the account and needs no stored
    credential: the capability authenticates with IAM, and an Application references the repository
    directly as `https://git-codecommit.<region>.amazonaws.com/v1/repos/<name>` with no Repository
    object at all. For an organization that cannot publish its manifests to a third-party Git host,
    this is the shortest path to a working reconcile.
  EOT
  type        = list(string)
  default     = []
}

variable "argocd_codeconnections_arns" {
  description = <<-EOT
    CodeConnections connection ARNs the capability may use, granting `codeconnections:UseConnection`.

    The path for GitHub, GitLab or Bitbucket, including self-managed servers reachable from a VPC.
    The connection holds the authorization, so no long-lived credential is stored and nothing goes
    in a Kubernetes Secret. Applications use the proxy URL form
    `https://codeconnections.<region>.amazonaws.com/git-http/<account>/<region>/<connection>/<owner>/<repo>.git`.
  EOT
  type        = list(string)
  default     = []
}

variable "argocd_ecr_pull" {
  description = <<-EOT
    Attach `AmazonEC2ContainerRegistryPullOnly` so the capability can read Helm charts and OCI
    artifacts from ECR.

    The in-account option when the manifests are packaged rather than kept in Git. Note the two
    reference forms differ: Helm charts use the registry host with no `oci://` prefix plus a `chart`
    field, while OCI artifacts use `oci://` plus a `path` field.
  EOT
  type        = bool
  default     = false
}

variable "argocd_secrets_manager_secret_arns" {
  description = <<-EOT
    Secrets Manager secret ARNs holding repository credentials, granting `secretsmanager:GetSecretValue`.

    For a Git host none of the direct integrations cover. A Repository Secret in the cluster carries
    only a `secretArn`, so the credential itself never enters Kubernetes and can be rotated through
    IAM without touching the cluster.
  EOT
  type        = list(string)
  default     = []
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

variable "aws_cli_bin" {
  description = <<-EOT
    The `aws` binary the Gateway API escape hatch calls, for the `gateway_api_crds_managed = true`
    case. Only used there; the default case makes no call at all.

    A CLI too old to know `gatewayApi` fails with "Unknown parameter in
    kubernetesNetworkConfig.elasticLoadBalancing", which reads as the feature not existing rather
    than as the CLI being stale. Point this at a newer `aws`, such as a virtualenv's, when the
    default one is too old.
  EOT
  type        = string
  default     = "aws"
}

variable "log_retention_days" {
  description = <<-EOT
    Retention on the control plane's own log group, `/aws/eks/<cluster>/cluster`.

    A group EKS creates for itself has NO retention -- `retentionInDays: None`, never expire -- so
    this is the only place it gets one. With audit logging enabled that is the difference between a
    bounded cost and an unbounded one.
  EOT
  type        = number
  default     = 30
}

variable "log_kms_key_arn" {
  description = "Customer-managed KMS key for the control plane log group. Control plane logs name principals, resources and requests."
  type        = string
  default     = ""
}

# --- an existing cluster, instead of one this module creates ---------------------------------
variable "create_cluster" {
  description = <<-EOT
    Create the EKS cluster, or attach to one that already exists.

    false makes this module a TENANT of a cluster somebody else owns: it creates no cluster, no
    cluster IAM role, no node role, no Pod Identity addon and no access entries, and reads the
    cluster's name, endpoint, CA data, OIDC issuer, security group and Auto Mode node role from the
    cluster itself. Everything that is this stack's own -- the capabilities, the permissions
    boundary, the ECR repositories, and every object in gitops/ -- is still created.

    WHAT IT DOES NOT DO IS MAKE THE STACK INVISIBLE. Three things it installs are cluster-wide and
    affect workloads that are not agents:

      the amazon-vpc-cni ConfigMap           turns network policy enforcement on for the WHOLE
                                             cluster. Every NetworkPolicy on it starts being
                                             enforced, including ones that were inert before.
      the eks-agents-gp3 StorageClass        becomes default, outranking whatever was default
      four Admin-tier ClusterNetworkPolicies evaluated before every namespaced policy, and an
                                             Accept there ends evaluation

    scripts/teardown.sh removes all three, and removes the ConfigMap only if this stack created it.
    Read the "Clean up" section of the agents-cluster-setup page of the EKS User Guide before
    running this against a cluster you care about.

    The cluster must be EKS Auto Mode, like one this module would create. `var.name` is the existing
    cluster's name when this is false, and kubernetes_version, vpc_id, subnet_ids and az_count are
    then ignored.
  EOT
  type        = bool
  default     = true
}

variable "ecr_force_delete" {
  description = "Delete the agent images with the ECR repositories when a repository is deleted -- by terraform destroy, or by an apply that renames or drops one. Off by default: an apply must not be able to drop images as a side effect. Set true on a disposable stack, and terraform destroy needs no separate image cleanup (scripts/teardown.sh step 8)."
  type        = bool
  default     = false
}

variable "endpoint_public_access" {
  description = "Open the cluster's public API endpoint to endpoint_public_access_cidrs. The private endpoint stays on. Applies only when this module creates the cluster."
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "Source CIDRs allowed to reach the public API endpoint when endpoint_public_access is true. 0.0.0.0/0 is refused."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 opens the cluster's API endpoint to the internet. Name the CIDRs that need it."
  }
}

variable "allow_person_delegation" {
  description = "Admit AgentCore Identity's on-behalf-of exchange in the agent permissions boundary: GetWorkloadAccessTokenForJWT and GetResourceOauth2Token on this stack's workload identities (<name>-*) and on-behalf-of providers (<name>-*-on-behalf-of). The AWS services root sets it with person_access_delegated_token."
  type        = bool
  default     = false
}
