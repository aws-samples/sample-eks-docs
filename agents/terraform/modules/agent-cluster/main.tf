# The cluster both paths start from.
#
# What this module owns:
#   - an EKS Auto Mode cluster, which is where the isolated-sandbox RuntimeClass, the DNS-aware
#     network policy enforcement and the EKS Pod Identity agent come from with nothing to install
#   - the EKS Capabilities the platform team interface is built on: Argo CD, kro and ACK, each run
#     off-cluster by EKS
#   - ECR repositories for agent images
#   - the cluster's own IAM roles and access entries
#
# What it deliberately does not own:
#   - a VPC. An agent platform belongs in the network the organization already operates.
#   - anything that runs inside the cluster. Everything in-cluster is reconciled from Git by
#     Argo CD; see ../../../gitops. A platform team that applies in-cluster manifests from
#     Terraform ends up with two systems that both believe they own cluster state.
#   - any per-agent object. Those are ../agent-identity in Terraform, or the agent resource
#     definition in gitops/base/templates when the platform team drives them from the cluster.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# THE CLUSTER, WHICHEVER WAY IT ARRIVED. Every reference below goes through these locals rather than
# at `aws_eks_cluster.this` directly, so that "create it" and "attach to one" are a single line of
# difference rather than a fork running through the module.
data "aws_eks_cluster" "existing" {
  count = var.create_cluster ? 0 : 1
  name  = var.name

  # AN EXISTING CLUSTER MUST BE ONE THE AGENTS CAN RUN ON. Agent pods run in Nitro sandboxes, whose
  # runtime classes exist only on EKS Auto Mode clusters at Kubernetes 1.36 or later, and the
  # NodeClass reads Auto Mode's node role. On any other cluster the apply succeeds and every agent
  # pod is refused or stays Pending, so the plan stops here instead.
  lifecycle {
    postcondition {
      condition     = try(self.compute_config[0].enabled, false)
      error_message = "Cluster ${var.name} is not an EKS Auto Mode cluster. Agent pods run in Nitro sandboxes, which need EKS Auto Mode: turn Auto Mode on for the cluster, or let this stack create one (create_cluster = true)."
    }
    postcondition {
      condition     = try(tonumber(split(".", self.version)[0]) > 1 || tonumber(split(".", self.version)[1]) >= 36, false)
      error_message = "Cluster ${var.name} runs Kubernetes ${self.version}. Nitro sandboxes need 1.36 or later: upgrade the cluster's control plane, or let this stack create one (create_cluster = true)."
    }
  }
}

locals {
  cluster_name = var.create_cluster ? one(aws_eks_cluster.this[*].name) : one(data.aws_eks_cluster.existing[*].name)
  cluster_arn  = var.create_cluster ? one(aws_eks_cluster.this[*].arn) : one(data.aws_eks_cluster.existing[*].arn)

  # The Auto Mode node role, which the NodeClass in gitops/base needs. On an existing cluster this
  # is the role the cluster already launches nodes with -- read from computeConfig rather than
  # created, because a NodeClass naming a role the cluster has no access entry for produces nodes
  # that join nothing, and the symptom is a pod that stays Pending with no mention of IAM.
  node_role_name = var.create_cluster ? one(aws_iam_role.node[*].name) : reverse(split("/", one(data.aws_eks_cluster.existing[*].compute_config[0].node_role_arn)))[0]
  node_role_arn  = var.create_cluster ? one(aws_iam_role.node[*].arn) : one(data.aws_eks_cluster.existing[*].compute_config[0].node_role_arn)
}

locals {
  tags = merge(var.tags, {
    "app.kubernetes.io/part-of" = "eks-agents-paved-paths"
    ManagedBy                   = "terraform/modules/agent-cluster"
  })

  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  # The name prefix per-agent roles get, from both the Terraform module and the kro resource
  # definition. Used to scope the pathless ARN that ACK's pre-create iam:GetRole is evaluated
  # against; keep it in step with the role name in gitops/base/templates/40-agent-rgd.yaml.
  agent_role_name_prefix = "${var.name}-agent-"

  # Scope every ACK permission by the namespace the resource was created in. The managed ACK
  # capability sets eks:kubernetes-namespace as a session tag on every AWS call it makes, so this
  # condition is the difference between "ACK may create IAM roles" and "ACK may create IAM roles
  # when asked from a namespace agents actually run in".
  ack_namespace_condition = {
    test     = "StringEquals"
    variable = "aws:PrincipalTag/eks:kubernetes-namespace"
    values   = var.agent_namespaces
  }
}

# ---------------------------------------------------------------------------
# Cluster IAM role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  count = var.create_cluster ? 1 : 0

  name               = "${var.name}-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json
  tags               = local.tags
}

# EKS Auto Mode needs the cluster role to manage compute, storage, networking and load balancing on
# the platform team's behalf. These five are the documented set; dropping one leaves Auto Mode
# unable to bring up nodes, attach volumes or reconcile a load balancer.
resource "aws_iam_role_policy_attachment" "cluster" {
  # Filtered rather than counted: this resource already uses for_each, and the two meta-arguments
  # are mutually exclusive.
  for_each = var.create_cluster ? toset([
    "AmazonEKSClusterPolicy",
    "AmazonEKSComputePolicy",
    "AmazonEKSBlockStoragePolicyV2",
    "AmazonEKSLoadBalancingPolicy",
    "AmazonEKSNetworkingPolicy",
  ]) : toset([])

  role       = one(aws_iam_role.cluster[*].name)
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# ---------------------------------------------------------------------------
# Auto Mode node role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# The node role is the one an agent must never be able to reach. On EKS Auto Mode the instance
# metadata hop limit that keeps ordinary pods away from it is set by EKS and cannot be changed, so
# the remaining route is a pod with host networking: gitops/base/templates/20-admission-sandbox.yaml
# refuses those at admission. Keep this role to the minimum anyway, because it is what an agent
# would inherit if that gate ever failed.
resource "aws_iam_role" "node" {
  count = var.create_cluster ? 1 : 0

  name               = "${var.name}-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  # Filtered rather than counted: this resource already uses for_each, and the two meta-arguments
  # are mutually exclusive.
  for_each = var.create_cluster ? toset([
    "AmazonEKSWorkerNodeMinimalPolicy",
    "AmazonEC2ContainerRegistryPullOnly",
  ]) : toset([])

  role       = one(aws_iam_role.node[*].name)
  policy_arn = "arn:${local.partition}:iam::aws:policy/${each.value}"
}

# ---------------------------------------------------------------------------
# The cluster
# ---------------------------------------------------------------------------

# THE CONTROL PLANE'S LOG GROUP, CREATED HERE SO `terraform destroy` TAKES IT.
#
# EKS creates `/aws/eks/<cluster>/cluster` itself the first time control plane logging writes to it,
# and that group OUTLIVES the cluster: after a full destroy, the teardown sweep reports
# "CloudWatch log groups outliving the cluster: /aws/eks/<cluster>/cluster". One per cluster ever
# created, left behind forever.
#
# Creating it here fixes two things at once. Terraform owns it, so the destroy removes it -- and it
# gets a RETENTION, which an EKS-created group does not: that one comes back `retentionInDays: None`,
# which means never expire. On a cluster with audit logging on, never-expiring control plane logs are
# the kind of cost that is invisible until it is large.
#
# It must exist BEFORE the cluster, or EKS creates it first and this resource fails with
# ResourceAlreadyExistsException. For a cluster that already exists, import it rather than deleting
# logs:  terraform import 'module.cluster.aws_cloudwatch_log_group.control_plane' /aws/eks/<name>/cluster
resource "aws_cloudwatch_log_group" "control_plane" {
  # NOT ON A CLUSTER THIS STACK DID NOT CREATE. EKS made this log group when the owner made the
  # cluster, so an apply here fails with ResourceAlreadyExistsException -- and worse, if it were
  # imported, a later `terraform destroy` of this stack would delete the OWNER'S control-plane logs.
  # Retention on somebody else's log group is their decision, not this stack's.
  #
  # Without the gate, create_cluster = false would contradict its own variable description.
  count = var.create_cluster ? 1 : 0

  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn != "" ? var.log_kms_key_arn : null

  tags = local.tags
}

resource "aws_eks_cluster" "this" {
  count = var.create_cluster ? 1 : 0

  name     = var.name
  role_arn = one(aws_iam_role.cluster[*].arn)
  version  = var.kubernetes_version

  enabled_cluster_log_types = var.enable_cluster_log_types

  # REQUIRED WITH AUTO MODE, and the API rejects the cluster without it:
  #
  #   InvalidParameterException: When EKS Auto Mode is enabled,
  #   bootstrapSelfManagedAddons must be set to false.
  #
  # The provider defaults this to true, which asks EKS to install the self-managed kube-proxy, CNI
  # and CoreDNS add-ons. Auto Mode manages all three itself, so the two settings contradict each
  # other and CreateCluster refuses the pair rather than picking one. `compute_config.enabled` is
  # hardcoded true below, so this is unconditional here.
  #
  # Without it, `terraform apply` fails at CreateCluster, which is late enough that the VPC, both
  # IAM roles and every policy attachment are already created. Nothing in `terraform validate` or
  # `terraform plan` catches it.
  bootstrap_self_managed_addons = false

  access_config {
    # API, not API_AND_CONFIG_MAP. aws-auth is a ConfigMap any principal with RBAC on kube-system
    # can edit, which makes cluster authorization editable from inside the cluster by anything that
    # reaches that namespace. On an agent platform that is the wrong direction for authorization to
    # flow.
    authentication_mode = "API"

    # The creating principal does not silently become a cluster admin. Admin access is granted
    # explicitly below, to the principals var.cluster_admin_principal_arns names, so the access
    # list is reviewable in Git rather than a side effect of whoever ran apply.
    bootstrap_cluster_creator_admin_permissions = false
  }

  compute_config {
    enabled       = true
    node_pools    = var.auto_mode_node_pools
    node_role_arn = local.node_role_arn
  }

  kubernetes_network_config {
    elastic_load_balancing {
      # The load balancing capability runs off-cluster as part of Auto Mode, so the Ingress and
      # Gateway API controllers need nothing installed. The agents-ingress page of the EKS User
      # Guide covers the decisions that still belong to the platform team.
      enabled = true

      # NOTE: Gateway API enablement is not here, because the provider cannot express it yet.
      #
      # Auto Mode turns the Gateway API on through
      # kubernetesNetworkConfig.elasticLoadBalancing.gatewayApi.crds.managed, and the presence of
      # that configuration is what enables the feature. The AWS provider has no such attribute --
      # elastic_load_balancing carries `enabled` and nothing else. hashicorp/terraform-provider-aws#50737
      # adds gateway_api.crds.managed to this resource and the data source.
      #
      # So the enablement is the aws_eks_cluster_gateway_api terraform_data below. Once the provider
      # supports the attribute, add here:
      #
      #   gateway_api {
      #     crds {
      #       managed = false
      #     }
      #   }
      #
      # and remove that resource and its variable.
    }
  }

  storage_config {
    block_storage {
      # The EBS CSI driver, which is what backs an Agent Sandbox workspace volume across a suspend
      # and resume.
      enabled = true
    }
  }

  upgrade_policy {
    support_type = "STANDARD"
  }

  vpc_config {
    subnet_ids = var.subnet_ids

    # Private by default. An agent platform's API server has no reason to be reachable from the
    # internet, and the control plane endpoint is a separate exposure from the agent's own ingress.
    # endpoint_public_access opens the public endpoint to endpoint_public_access_cidrs only -- the
    # root defaults those to the address of the machine running Terraform -- for a team that
    # reaches the cluster from a workstation rather than the bastion. The private endpoint stays on,
    # so nodes and the bastion never use the public one. Requests are still authenticated by IAM
    # and authorized by the access entries; the CIDR list only narrows who can attempt one.
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.endpoint_public_access_cidrs : null
  }

  zonal_shift_config {
    enabled = true
  }

  tags = local.tags

  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_iam_role_policy_attachment.node,

    # The control plane log group, so it exists before EKS would create one itself. Without this
    # Terraform is free to build the cluster concurrently, EKS makes the group, and the apply fails
    # on a group that already exists.
    aws_cloudwatch_log_group.control_plane, # empty when create_cluster is false, which depends_on tolerates
  ]

  lifecycle {
    # EKS treats an empty public_access_cidrs as 0.0.0.0/0, so a public endpoint with no CIDRs would
    # be open to the internet.
    precondition {
      condition     = !var.endpoint_public_access || length(var.endpoint_public_access_cidrs) > 0
      error_message = "endpoint_public_access needs at least one CIDR in endpoint_public_access_cidrs; EKS reads an empty list as 0.0.0.0/0."
    }
  }
}

# ---------------------------------------------------------------------------
# Access entries
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "cluster_admin" {
  # NOT THIS STACK'S TO GRANT ON A CLUSTER IT DID NOT CREATE. Access is the owner's, and an access
  # entry for a principal that already has one fails with ResourceInUseException -- which on a
  # shared cluster is the apply failing because somebody else already did the right thing.
  for_each = var.create_cluster ? toset(var.cluster_admin_principal_arns) : toset([])

  cluster_name  = local.cluster_name
  principal_arn = each.value
  type          = "STANDARD"
  tags          = local.tags
}

resource "aws_eks_access_policy_association" "cluster_admin" {
  # NOT THIS STACK'S TO GRANT ON A CLUSTER IT DID NOT CREATE. Access is the owner's, and an access
  # entry for a principal that already has one fails with ResourceInUseException -- which on a
  # shared cluster is the apply failing because somebody else already did the right thing.
  for_each = var.create_cluster ? toset(var.cluster_admin_principal_arns) : toset([])

  cluster_name  = local.cluster_name
  principal_arn = each.value
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.cluster_admin]
}

# ---------------------------------------------------------------------------
# EKS Pod Identity agent
# ---------------------------------------------------------------------------

# The EKS Pod Identity agent, which delivers each agent's role credentials and the session tags
# its IAM policy conditions on.
resource "aws_eks_addon" "pod_identity" {
  count = var.create_cluster ? 1 : 0

  cluster_name = local.cluster_name
  addon_name   = "eks-pod-identity-agent"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  tags = local.tags
}

# ---------------------------------------------------------------------------
# EKS Capabilities: the platform team interface
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "capability_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["capabilities.eks.amazonaws.com"]
    }
  }
}

# --- Argo CD -----------------------------------------------------------------

resource "aws_iam_role" "capability_argocd" {
  count = var.enable_capability_argocd ? 1 : 0

  name               = "${var.name}-capability-argocd"
  assume_role_policy = data.aws_iam_policy_document.capability_assume_role.json
  tags               = local.tags
}

# IAM PROPAGATION, AND WITHOUT THIS THE FIRST APPLY ALWAYS FAILS.
#
# CreateCapability validates the role's trust policy synchronously, and IAM is eventually
# consistent, so a role created moments earlier in the same apply reads as not yet trusting the
# service:
#
#   InvalidParameterException: The trust policy for the provided role is invalid. The policy
#   must include sts:AssumeRole and sts:TagSession actions granting access to the AWS service
#   capabilities.eks.amazonaws.com
#
# The message points at the policy, which sends you to read a policy that is already correct --
# the role's trust policy is byte-for-byte what the error asks for. The tell is that a second
# `terraform apply` succeeds with no changes to anything: the role has propagated by then. ACK and
# KRO use the same trust policy and are not affected, because each has an inline role policy
# between the role and the capability that costs enough time to hide this.
#
# A fixed wait is the only tool here: there is nothing to poll, since the failure is a read of IAM
# by a service in another account.
resource "time_sleep" "capability_argocd_role_propagation" {
  count = var.enable_capability_argocd ? 1 : 0

  depends_on      = [aws_iam_role.capability_argocd]
  create_duration = "20s"
}

# --- the Identity Center wiring the Argo CD capability needs ------------------
#
# ZERO MANUAL STEPS IS THE TARGET. Without this block, setup is a list of console and CLI actions:
# find the instance ARN, create a group, create a user, add the user to the group, then hand-write
# an rbac_role_mapping with the group's Identity Store id.
#
# All of that is below. What remains manual is the EXISTENCE of the Identity Center instance: the
# AWS provider has no `aws_ssoadmin_instance` resource -- only the `aws_ssoadmin_instances` data
# source -- so an account with none runs one API call first. The precondition on the capability
# prints that command.
#
# The resource is absent from the provider's schema under the `~> 6.73` pin, and the provider has
# no `r/ssoadmin_instance` docs page while its siblings `ssoadmin_application` and
# `ssoadmin_instance_access_control_attributes` and the `ssoadmin_instances` data source all have
# one. hashicorp/terraform-provider-aws#45878 requests it. Once the provider has the resource, this
# block can create the instance too.
#
# A local-exec calling `aws sso-admin create-instance` was considered and rejected: it would create
# an account-level, organization-visible resource that Terraform does not own, cannot plan and would
# not destroy. An account setting with that blast radius belongs in an operator's hands.

# The instance in the CLUSTER's account and region, when one was not named explicitly. Same account
# and region is also what the EKS Workshop requires of this capability, so it is the shape to make
# work rather than a simplification.
data "aws_ssoadmin_instances" "this" {
  # Identity Center lives in its own region; see configuration_aliases in versions.tf.
  provider = aws.idc

  # READ WHENEVER THE CAPABILITY IS ON, including when the instance is named. It is also where the
  # instance's identity store comes from, and the admin group is created in that store: skipping the
  # read for a named instance leaves no store id, so no group and no ADMIN mapping, and the plan
  # fails the no-administrator precondition below. That is the cross-region case, for example an
  # instance in us-east-1 for a cluster in us-west-2, which the agents page of the EKS User Guide
  # covers.
  count = var.enable_capability_argocd ? 1 : 0
}

locals {
  # LENGTH CHECKS RATHER THAN `one()`, and the difference is not cosmetic. `one([])` returns NULL,
  # and `try()` does not convert a null into the fallback -- it only catches errors. So
  # `try(one(x), "")` on an account with no Identity Center instance yields null, `null != ""` is
  # true, and every guard below passes: the group is planned with a null identity_store_id and the
  # apply fails with "Missing required argument", while the precondition that should have caught it
  # never fires. That is the plan on an account whose only instance is in another region.
  argocd_idc_arns         = try(data.aws_ssoadmin_instances.this[0].arns, [])
  argocd_idc_store_ids    = try(data.aws_ssoadmin_instances.this[0].identity_store_ids, [])
  argocd_idc_discovered   = length(local.argocd_idc_arns) > 0 ? local.argocd_idc_arns[0] : ""
  argocd_idc_instance_arn = var.argocd_idc_instance_arn != "" ? var.argocd_idc_instance_arn : local.argocd_idc_discovered
  # The store that belongs to the instance in use, matched by ARN rather than taken first, so a
  # named instance gets its own store. Empty when the named instance is not visible from this
  # account (an organization instance managed elsewhere): no group is created, and the precondition
  # below asks for argocd_rbac_role_mappings instead.
  argocd_idc_store_by_arn  = zipmap(local.argocd_idc_arns, local.argocd_idc_store_ids)
  argocd_identity_store_id = lookup(local.argocd_idc_store_by_arn, local.argocd_idc_instance_arn, "")
  argocd_manage_identities = var.enable_capability_argocd && var.argocd_manage_admin_group && local.argocd_identity_store_id != ""

  # The ADMIN mapping this module composes, appended to anything the caller declared. A GROUP, not
  # a user: a mapping to a user has to be edited every time people change.
  argocd_group_mapping = local.argocd_manage_identities ? [{
    role          = "ADMIN"
    identity_type = "SSO_GROUP"
    identity_id   = aws_identitystore_group.argocd_admins[0].group_id
  }] : []

  argocd_rbac_role_mappings = concat(var.argocd_rbac_role_mappings, local.argocd_group_mapping)
}

resource "aws_identitystore_group" "argocd_admins" {
  # Identity Center lives in its own region; see configuration_aliases in versions.tf.
  provider = aws.idc

  count = local.argocd_manage_identities ? 1 : 0

  identity_store_id = local.argocd_identity_store_id
  display_name      = var.argocd_admin_group_name != "" ? var.argocd_admin_group_name : "${var.name}-argocd-admins"
  description       = "Argo CD ADMIN for the ${var.name} EKS cluster. Managed by Terraform."
}

# Users this module creates. Identity Center creates a user WITHOUT a password and has no API to set
# one -- the first sign-in sets it -- so creating the user is the whole of what automation can do.
resource "aws_identitystore_user" "argocd_admins" {
  # Identity Center lives in its own region; see configuration_aliases in versions.tf.
  provider = aws.idc

  for_each = local.argocd_manage_identities ? { for u in var.argocd_admin_users : u.user_name => u } : {}

  identity_store_id = local.argocd_identity_store_id
  user_name         = each.value.user_name
  display_name      = each.value.display_name

  name {
    given_name  = each.value.given_name
    family_name = each.value.family_name
  }

  emails {
    value   = each.value.email
    primary = true
  }
}

resource "aws_identitystore_group_membership" "argocd_admins_created" {
  # Identity Center lives in its own region; see configuration_aliases in versions.tf.
  provider = aws.idc

  for_each = local.argocd_manage_identities ? { for u in var.argocd_admin_users : u.user_name => u } : {}

  identity_store_id = local.argocd_identity_store_id
  group_id          = aws_identitystore_group.argocd_admins[0].group_id
  member_id         = aws_identitystore_user.argocd_admins[each.key].user_id
}

# Users that already exist in the Identity Store, named rather than created. Looked up by user name,
# which is what an operator knows; a lookup that finds nothing fails the apply rather than silently
# granting nobody.
data "aws_identitystore_user" "argocd_admins_existing" {
  # Identity Center lives in its own region; see configuration_aliases in versions.tf.
  provider = aws.idc

  for_each = local.argocd_manage_identities ? toset(var.argocd_admin_existing_user_names) : []

  identity_store_id = local.argocd_identity_store_id

  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = each.value
    }
  }
}

resource "aws_identitystore_group_membership" "argocd_admins_existing" {
  # Identity Center lives in its own region; see configuration_aliases in versions.tf.
  provider = aws.idc

  for_each = local.argocd_manage_identities ? toset(var.argocd_admin_existing_user_names) : []

  identity_store_id = local.argocd_identity_store_id
  group_id          = aws_identitystore_group.argocd_admins[0].group_id
  member_id         = data.aws_identitystore_user.argocd_admins_existing[each.value].user_id
}

resource "aws_eks_capability" "argocd" {
  # WHO CAN ADMINISTER THIS, asked before it is created rather than discovered afterwards.
  #
  # rbac_role_mapping is the ONLY way a person gets access to the managed Argo CD -- reconciliation
  # uses the capability's own IAM role, so an instance with no mapping still syncs perfectly and no
  # human can open it, change a sync policy or read why an Application failed. The apply succeeds,
  # the capability reaches ACTIVE, and nothing reports it.
  #
  # The list has two sources and either may be empty by itself: the group this module creates when
  # argocd_manage_admin_group is on, and whatever argocd_rbac_role_mappings names. BOTH empty is the
  # hole.
  #
  # With both empty, the capability comes up with no administrator and the apply is clean.
  #
  # Identity Center goes through a provider aliased to argocd_idc_region, so the group is created
  # beside the instance and manage_admin_group works cross-region. The precondition is still needed,
  # because a caller can turn the group off and name nothing.
  count = var.enable_capability_argocd ? 1 : 0

  cluster_name    = local.cluster_name
  capability_name = "${var.name}-argocd"
  type            = "ARGOCD"
  role_arn        = aws_iam_role.capability_argocd[0].arn

  depends_on = [time_sleep.capability_argocd_role_propagation]

  # RETAIN, not DELETE. Deleting the capability with DELETE propagation removes the Applications it
  # manages, and on this stack those Applications are the mesh, the gateway and the sandbox
  # controller. Keep the in-cluster objects and let a deliberate Git change remove them.
  delete_propagation_policy = "RETAIN"

  # REQUIRED, and the only capability type that takes one. Omitting it fails at the API rather than
  # at plan time, with "InvalidParameterException: Configuration is required for ARGOCD capability
  # type" -- so a module that leaves it out looks correct until the first apply.
  configuration {
    argo_cd {
      namespace = var.argocd_namespace

      # THE MANAGED ARGO CD AUTHENTICATES PEOPLE THROUGH IDENTITY CENTER, and this is the adoption
      # prerequisite to know about: idc_instance_arn is required, so the capability cannot be
      # created in an organization that has no IdC instance. There is no IAM-only or
      # local-admin mode.
      #
      # The instance is org-wide and single-region, and frequently not in the cluster's region --
      # for example a cluster in us-west-2 with the only instance in us-east-1. Hence idc_region.
      aws_idc {
        idc_instance_arn = local.argocd_idc_instance_arn
        idc_region       = var.argocd_idc_region != "" ? var.argocd_idc_region : null
      }

      # Keep the Argo CD API and UI off the internet. Empty leaves the capability's default.
      dynamic "network_access" {
        for_each = length(var.argocd_vpce_ids) > 0 ? [1] : []
        content {
          vpce_ids = var.argocd_vpce_ids
        }
      }

      # Who may do what, on an Identity Center identity rather than an IAM principal. Roles are
      # ADMIN, EDITOR, VIEWER; identity types are SSO_USER and SSO_GROUP. The API rejects Argo CD's
      # own lowercase role names and the bare "USER", which is why variables.tf validates both.
      # AT LEAST ONE MAPPING, OR NOBODY CAN ADMINISTER IT. Checked in a precondition below, because
      # this list is composed from two sources and either can legitimately be empty on its own.
      dynamic "rbac_role_mapping" {
        for_each = local.argocd_rbac_role_mappings
        content {
          role = rbac_role_mapping.value.role
          identity {
            type = rbac_role_mapping.value.identity_type
            id   = rbac_role_mapping.value.identity_id
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = local.argocd_idc_instance_arn != ""
      error_message = "enable_capability_argocd needs an IAM Identity Center instance, and none was found in this account and region. CreateCapability requires configuration.argoCd.awsIdc even though its only purpose is letting people sign in -- reconciliation uses the capability's own role. Create one with `aws sso-admin create-instance --name eks-agents` and re-apply, and this module then creates the admin group, the users and the role mapping for you. The AWS provider has no resource for the instance itself, which is why this one call is yours. An instance in another region can be named with argocd_idc_instance_arn and argocd_idc_region instead."
    }

    precondition {
      condition     = length(local.argocd_rbac_role_mappings) > 0
      error_message = "The Argo CD capability would be created with no rbac_role_mapping, so NO PERSON could administer it: reconciliation uses the capability's own IAM role, so the instance syncs perfectly and nobody can open it, change a sync policy or read why an Application failed. The apply succeeds and nothing reports it. Either leave argocd_manage_admin_group on, which creates the admin group and maps it -- it works whatever region the Identity Center instance is in, so set argocd_idc_region rather than turning this off -- or name an existing identity in argocd_rbac_role_mappings: [{ role = \"ADMIN\", identity_type = \"SSO_GROUP\", identity_id = \"<group id>\" }]. Find one with: aws identitystore list-groups --identity-store-id <id> --region <idc region>."
    }
  }

  tags = local.tags
}

# --- kro ---------------------------------------------------------------------

# kro needs no IAM permissions at all: it only composes Kubernetes resources, and the AWS resources
# in a composition are created by ACK, which carries its own role. The role exists because a
# capability requires one, and it holds nothing.
resource "aws_iam_role" "capability_kro" {
  count = var.enable_capability_kro ? 1 : 0

  name               = "${var.name}-capability-kro"
  assume_role_policy = data.aws_iam_policy_document.capability_assume_role.json
  tags               = local.tags
}


# --- IAM PROPAGATION, FOR EVERY CAPABILITY AND NOT JUST ARGO CD --------------
#
# CreateCapability validates the role's trust policy at the API, and IAM is eventually consistent --
# so a role created seconds earlier is rejected with a message about the policy being invalid when
# the policy is correct and simply not visible yet:
#
#   InvalidParameterException: The trust policy for the provided role is invalid. The policy must
#   include sts:AssumeRole and sts:TagSession actions granting access to the AWS service
#   capabilities.eks.amazonaws.com
#
# WHY EVERY CAPABILITY NEEDS ONE. On a cluster this module CREATES, the race cannot fire for ACK or
# kro: the cluster takes about ten minutes to come up and the capabilities depend on it, so IAM has
# propagated long before. With create_cluster = false there is no ten-minute wait -- the role and
# the capability are seconds apart -- and ACK fails on the first apply against an existing cluster.
#
# The message names the one thing that is not wrong, which is why this is worth a comment rather
# than a retry: reading it literally sends you to the trust policy, and the trust policy is correct.
resource "time_sleep" "capability_kro_role_propagation" {
  count = var.enable_capability_kro ? 1 : 0

  depends_on      = [aws_iam_role.capability_kro]
  create_duration = "20s"
}

resource "time_sleep" "capability_ack_role_propagation" {
  count = var.enable_capability_ack ? 1 : 0

  # The inline policy too, not only the role: ACK's role carries one, and the capability is refused
  # the same way while either is still propagating.
  depends_on      = [aws_iam_role.capability_ack, aws_iam_role_policy.capability_ack]
  create_duration = "20s"
}

resource "aws_eks_capability" "kro" {
  count = var.enable_capability_kro ? 1 : 0

  depends_on = [time_sleep.capability_kro_role_propagation]

  cluster_name              = local.cluster_name
  capability_name           = "${var.name}-kro"
  type                      = "KRO"
  role_arn                  = aws_iam_role.capability_kro[0].arn
  delete_propagation_policy = "RETAIN"

  tags = local.tags
}

# --- ACK ---------------------------------------------------------------------

resource "aws_iam_role" "capability_ack" {
  count = var.enable_capability_ack ? 1 : 0

  name               = "${var.name}-capability-ack"
  assume_role_policy = data.aws_iam_policy_document.capability_assume_role.json
  tags               = local.tags
}

# Two permission models, and exactly one of them is in effect.
#
# When var.ack_assumable_role_arns is set, this role holds nothing but permission to assume those
# roles, and the scoping lives in them, selected per namespace by an IAMRoleSelector in the cluster.
# That is the shape to move to for production.
#
# Otherwise the role carries the service permissions directly, scoped three ways: to the IAM path
# per-agent roles are created under, to the cluster's own Pod Identity associations, and to the
# namespaces agents run in by the session tag the managed capability sets. That is enough for a
# composed agent resource to create its own identity and nothing else.
data "aws_iam_policy_document" "ack_role_selector" {
  count = var.enable_capability_ack && length(var.ack_assumable_role_arns) > 0 ? 1 : 0

  statement {
    sid       = "AssumeServiceRoles"
    effect    = "Allow"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = var.ack_assumable_role_arns
  }
}

data "aws_iam_policy_document" "ack_direct" {
  count = var.enable_capability_ack && length(var.ack_assumable_role_arns) == 0 ? 1 : 0

  # The agent's own IAM role, under one path and with one name prefix, and nowhere else. Note what
  # is absent: no iam:*Policy action on a managed policy, so a composition attaches inline policy to
  # a role it created and cannot reach a managed policy anyone else relies on.
  #
  # TWO RESOURCE ARNS, AND BOTH ARE NECESSARY.
  #
  # ACK calls iam:GetRole before creating a role, to decide whether it already exists. At that
  # moment the role does not exist, so IAM cannot know what path it will have and evaluates the
  # request against a PATHLESS ARN -- arn:...:role/<name>, not arn:...:role/eks-agents/<name>. A
  # policy scoped only to the path therefore denies the pre-create GetRole, and ACK never gets as
  # far as CreateRole.
  #
  # The symptom is specific and unhelpful: the ACK Role custom resource sits with
  # ACK.ResourceSynced=Unknown and "not authorized to perform: iam:GetRole on resource: role <name>"
  # -- note the resource in that message has no path -- while kro's Agent instance waits forever on
  # agentRole.status.ackResourceMetadata.arn. Nothing points at the path.
  #
  # So the pathless, name-prefixed ARN covers the pre-create read, and the path-scoped ARN covers
  # everything afterwards. The name prefix is what keeps the first one narrow: it matches the names
  # this stack gives agent roles and not an arbitrary role in the account.
  statement {
    sid    = "ManageAgentRoles"
    effect = "Allow"

    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:GetRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListRoleTags",
    ]

    # After creation, and for CreateRole itself, which carries the path in the request.
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.ack_agent_role_path}*"]
  }

  # Before creation, where IAM has no path to evaluate against. READS ONLY: the pathless ARN also
  # names a role at the root path with this prefix, which no boundary Deny below covers, so granting
  # CreateRole or PutRolePolicy here would let a composition create a role outside the path with no
  # permissions boundary. Every write carries the path and is matched by the statement above.
  statement {
    sid    = "ReadAgentRolesBeforeCreate"
    effect = "Allow"

    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListRoleTags",
    ]

    resources = ["arn:${local.partition}:iam::${local.account_id}:role/${local.agent_role_name_prefix}*"]
  }

  # Attaching the platform team's permission sets, and only those: the policy ARN must be under this
  # cluster's permission-set path and name prefix. Any other managed policy in the account -- an
  # AdministratorAccess, another cluster's set -- is refused to the composition.
  statement {
    sid       = "AttachPermissionSetsOnly"
    effect    = "Allow"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.ack_agent_role_path}*"]

    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values   = ["arn:${local.partition}:iam::${local.account_id}:policy${var.ack_agent_role_path}permission-sets/${var.name}-*"]
    }
  }

  # A permissions boundary on every role a composition creates, so an agent role cannot be granted
  # more than the boundary allows even if the composition asks for it. This is the one control that
  # survives a mistake in the resource definition itself.
  statement {
    sid       = "RequireAgentPermissionsBoundary"
    effect    = "Deny"
    actions   = ["iam:CreateRole", "iam:PutRolePolicy"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.ack_agent_role_path}*"]

    condition {
      test     = "StringNotEquals"
      variable = "iam:PermissionsBoundary"
      values   = [aws_iam_policy.agent_permissions_boundary.arn]
    }
  }

  statement {
    sid       = "ReadTheBoundary"
    effect    = "Allow"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
    resources = [aws_iam_policy.agent_permissions_boundary.arn]
  }

  # The agent's Pod Identity association, on this cluster only. This is the second half of what a
  # composed agent needs: the role above, and the association that delivers it to the pod.
  statement {
    sid    = "ManagePodIdentityAssociations"
    effect = "Allow"

    actions = [
      "eks:CreatePodIdentityAssociation",
      "eks:DeletePodIdentityAssociation",
      "eks:DescribePodIdentityAssociation",
      "eks:UpdatePodIdentityAssociation",
      "eks:ListPodIdentityAssociations",
      "eks:TagResource",
      "eks:UntagResource",
    ]

    resources = [
      local.cluster_arn,
      "arn:${local.partition}:eks:${local.region}:${local.account_id}:podidentityassociation/${local.cluster_name}/*",
    ]

    condition {
      test     = local.ack_namespace_condition.test
      variable = local.ack_namespace_condition.variable
      values   = local.ack_namespace_condition.values
    }
  }

  # Creating an association means handing a role to the EKS Pod Identity service. Scope the
  # PassRole to the same path, so a composition cannot associate an arbitrary role in the account
  # with a service account it controls — which would otherwise be a complete privilege escalation
  # out of this permission set.
  statement {
    sid       = "PassAgentRolesToPodIdentityOnly"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:${local.partition}:iam::${local.account_id}:role${var.ack_agent_role_path}*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["pods.eks.amazonaws.com"]
    }
  }

  statement {
    sid    = "RestrictToDeclaredApiGroups"
    effect = "Deny"

    not_actions = ["iam:GetPolicy", "iam:GetPolicyVersion"]
    resources   = ["*"]

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalTag/eks:kubernetes-api-group"
      values   = var.ack_managed_service_api_groups
    }
  }
}

# The platform team's permission sets, one managed policy each, under the path the ACK capability may
# attach from (AttachPermissionSetsOnly above).
locals {
  permission_set_statements = flatten([
    for name, set in var.agent_permission_sets : [
      for i, st in set.statements : { set = name, index = i, actions = st.actions, resources = st.resources, sid = st.sid }
    ]
  ])
}

data "aws_iam_policy_document" "permission_set" {
  for_each = var.agent_permission_sets

  dynamic "statement" {
    for_each = each.value.statements
    content {
      sid       = statement.value.sid
      effect    = "Allow"
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }
}

resource "aws_iam_policy" "permission_set" {
  for_each = var.agent_permission_sets

  name        = "${var.name}-${each.key}"
  path        = "${var.ack_agent_role_path}permission-sets/"
  description = "Agent permission set ${each.key} on cluster ${var.name}. Attached to the role of every Agent that names it in spec.permissionSets; capped by the agent permissions boundary."
  policy      = data.aws_iam_policy_document.permission_set[each.key].json
  tags        = local.tags
}

# The boundary every per-agent role is created inside. It is deliberately narrow: an agent reaches
# AWS to call a model, read and write its own objects in the checkpoint bucket, and nothing else.
# Widen it by passing a different boundary, not by editing an agent's own policy, so the widening
# is one reviewable change rather than one per agent.
resource "aws_iam_policy" "agent_permissions_boundary" {
  name        = "${var.name}-agent-boundary"
  path        = var.ack_agent_role_path
  description = "Permissions boundary for every per-agent IAM role on cluster ${var.name}. Caps what an agent role can hold regardless of what the agent resource definition asks for."
  policy      = data.aws_iam_policy_document.agent_permissions_boundary.json
  tags        = local.tags
}

data "aws_iam_policy_document" "agent_permissions_boundary" {
  statement {
    sid    = "ModelInferenceAndCheckpointStorageOnly"
    effect = "Allow"

    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
      "bedrock:Converse",
      "bedrock:ConverseStream",
      "bedrock:ApplyGuardrail",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:AbortMultipartUpload",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "elasticache:Connect",
      "bedrock-agentcore:GetMemory",
      "bedrock-agentcore:CreateEvent",
      "bedrock-agentcore:ListEvents",
      "bedrock-agentcore:RetrieveMemoryRecords",
      "bedrock-agentcore:ListMemoryRecords",
      "s3vectors:GetVectors",
      "s3vectors:PutVectors",
      "s3vectors:QueryVectors",
      "s3vectors:ListVectors",
      "logs:PutLogEvents",
      "logs:CreateLogStream",
      "xray:PutTraceSegments",
      "xray:PutSpans",
      "xray:PutSpansForIndexing",
    ]

    resources = ["*"]
  }

  # The on-behalf-of exchange for a person's tools (allow_person_delegation, AWS services path). An
  # agent binds a person's token to its workload identity and asks its credential provider for a
  # delegated token. The boundary admits only this stack's own workload identities and on-behalf-of
  # providers; each agent's own policy narrows that to its own pair.
  dynamic "statement" {
    for_each = var.allow_person_delegation ? [1] : []
    content {
      sid    = "OnBehalfOfExchange"
      effect = "Allow"
      actions = [
        "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
        "bedrock-agentcore:GetResourceOauth2Token",
      ]
      resources = [
        "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default",
        "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default/workload-identity/${var.name}-*",
        "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:token-vault/default",
        "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:token-vault/default/oauth2credentialprovider/${var.name}-*-on-behalf-of",
      ]
    }
  }

  # AgentCore reads the provider's client secret from Secrets Manager with the caller's credentials,
  # so the exchange needs the secret it keeps for each of this stack's on-behalf-of providers.
  dynamic "statement" {
    for_each = var.allow_person_delegation ? [1] : []
    content {
      sid       = "OnBehalfOfProviderSecret"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = ["arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:bedrock-agentcore-identity!default/oauth2/${var.name}-*-on-behalf-of-*"]
    }
  }

  # The platform team's permission sets (agent_permission_sets). The boundary admits their union;
  # an agent's role holds only the sets its Agent names, so one agent never gets another's.
  dynamic "statement" {
    for_each = { for i, st in local.permission_set_statements : "${st.set}-${i}" => st }
    content {
      sid       = "PermissionSet${replace(title(replace(statement.value.set, "-", " ")), " ", "")}${statement.value.index}"
      effect    = "Allow"
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }

  # An agent never creates identity. Without this, an agent role whose own policy was written too
  # broadly could mint a second role and escape the per-agent scoping entirely.
  # The memory tier's agent login (rung 3 on the open source path), read by an agent with its own
  # role. By name rather than by ARN: the secret belongs to terraform/modules/platform-secrets, which
  # names it <name>/platform/agent-memory-db, and Secrets Manager appends a random suffix to the ARN.
  statement {
    sid       = "MemoryTierLoginOnly"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = ["arn:${data.aws_partition.current.partition}:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.name}/platform/agent-memory-db-*"]
  }
  statement {
    sid    = "NeverIdentityOrPolicy"
    effect = "Deny"

    actions = [
      "iam:*",
      "sts:AssumeRole",
      "sts:AssumeRoleWithWebIdentity",
      "eks:*",
      "organizations:*",
      "ec2:*",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "capability_ack" {
  count = var.enable_capability_ack ? 1 : 0

  name   = "ack-capability"
  role   = aws_iam_role.capability_ack[0].id
  policy = length(var.ack_assumable_role_arns) > 0 ? data.aws_iam_policy_document.ack_role_selector[0].json : data.aws_iam_policy_document.ack_direct[0].json
}

resource "aws_eks_capability" "ack" {
  count = var.enable_capability_ack ? 1 : 0

  # RETAIN IS A CHOICE BETWEEN TWO RISKS, not a safe default, and it is worth knowing which one you
  # are taking.
  #
  # RETAIN keeps the ACK CRDs when the capability is deleted. That is what this stack wants: an ACK
  # CRD deleted while a custom resource still exists ORPHANS the AWS resource behind it, because the
  # controller that would have reconciled the deletion goes with the CRD. scripts/teardown.sh
  # deletes the Agents first for exactly this reason and refuses to delete the ACK CRDs while any
  # live resource remains.
  #
  # The cost is on the way back IN. Retained CRDs are from the capability version that installed
  # them, and a later capability at an OLDER version tries to downgrade them. The API server rejects
  # that -- `breaking changes detected: Field <x> is newly required` -- and the new capability wedges
  # with CRDsInstalled=false. The recovery is to delete the retained services.k8s.aws CRDs once
  # nothing uses them.
  #
  # So: RETAIN on a cluster you are destroying costs nothing. On a cluster you KEEP, it leaves CRDs
  # that can block a future capability, and the recovery is to delete them once nothing uses them.
  # scripts/teardown.sh does that in step 7 after checking for live resources.
  delete_propagation_policy = "RETAIN"

  cluster_name    = local.cluster_name
  capability_name = "${var.name}-ack"
  type            = "ACK"
  role_arn        = aws_iam_role.capability_ack[0].arn

  tags = local.tags

  depends_on = [aws_iam_role_policy.capability_ack, time_sleep.capability_ack_role_propagation]
}

# ---------------------------------------------------------------------------
# ECR
# ---------------------------------------------------------------------------

# The registry is where image governance lives on this stack. The isolated-sandbox runtime class
# does not decide which image runs inside it. Scan on push, immutable tags, and an admission rule
# on the cluster are the controls that do.
resource "aws_ecr_repository" "agents" {
  for_each = toset(var.ecr_repository_names)

  name                 = "${var.name}/${each.value}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = var.ecr_force_delete

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = var.ecr_kms_key_arn == null ? "AES256" : "KMS"
    kms_key         = var.ecr_kms_key_arn
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Gateway API enablement, through the AWS CLI
# ---------------------------------------------------------------------------

# An escape hatch, and it is marked as one. Once the provider supports gateway_api.crds.managed
# (hashicorp/terraform-provider-aws#50737), set it on the cluster and delete this resource; the
# comment in kubernetes_network_config says what to add.
#
# WHY managed = false IS THE DEFAULT HERE, and it is a real decision rather than caution.
#
# Gateway API CRDs are cluster-wide, so exactly one party owns them. This stack installs them
# itself, pinned, in gitops/platform/*/10-gateway-api-crds.yaml -- and two other components on the
# cluster register GatewayClasses against them: Istio, for the ambient mesh, and AgentGateway, for
# the egress point. Handing ownership to AWS would let it replace CRDs those two depend on.
#
# So: this stack keeps ownership, AWS coexists, and nothing it installs is disturbed. A cluster that
# runs neither Istio nor AgentGateway can set managed = true and stop pinning the CRDs, which is one
# fewer thing to keep current.
#
# What this does NOT do is verify the result. The GatewayClass in gitops/base sits with
# Accepted=Unknown, reason Pending, until a controller claims it, and on an Auto Mode 1.36 cluster
# with load balancing enabled and the CRDs already at v1 the API can return "No changes needed"
# while no controller claims it. Check after apply rather than assuming:
#
#   kubectl get gatewayclass eks-auto-alb \
#     -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}'
# ONLY THE managed = true CASE NEEDS A CALL.
#
# A 1.36 Auto Mode cluster with load balancing enabled already reports
# `elasticLoadBalancing.gatewayApi.crds.managed: false` with no call ever having been made, so
# nothing has configured it:
#
#   "elasticLoadBalancing": { "enabled": true, "gatewayApi": { "crds": { "managed": false } } }
#
# and `UpdateClusterConfig` with that same value refuses with "No changes needed for EKS Auto Mode
# configuration provided". So for the default the call can only do one thing: fail the apply on a
# CLI too old to know the field. It is skipped.
#
# `managed = true` is a real change and still needs the call, which is why the resource survives.
resource "terraform_data" "gateway_api" {
  count = var.enable_gateway_api && var.gateway_api_crds_managed ? 1 : 0

  # Re-runs when the cluster or the setting changes, and not otherwise.
  triggers_replace = [
    local.cluster_name,
    var.gateway_api_crds_managed,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    # Needs an AWS CLI new enough to know the field. A stale CLI fails with
    # "Unknown parameter in kubernetesNetworkConfig.elasticLoadBalancing: gatewayApi, must be one of:
    # enabled", which reads like the feature does not exist rather than like the CLI is old -- so the
    # command checks and says so. `aws_cli_bin` can point at a newer `aws`, such as a virtualenv's.
    command = <<-EOT
      set -euo pipefail
      AWS=${var.aws_cli_bin}

      if ! $AWS eks update-cluster-config help 2>/dev/null | grep -q gatewayApi; then
        echo "note: this aws CLI ($($AWS --version 2>&1 | awk '{print $1}')) may not know the gatewayApi field." >&2
        echo "      If the call below fails with 'Unknown parameter ... gatewayApi', set aws_cli_bin" >&2
        echo "      to a newer one. A CLI on botocore 1.43.127 or later knows it." >&2
      fi

      $AWS eks update-cluster-config \
        --region ${data.aws_region.current.region} \
        --name ${local.cluster_name} \
        --kubernetes-network-config '{"elasticLoadBalancing":{"enabled":true,"gatewayApi":{"crds":{"managed":${var.gateway_api_crds_managed}}}}}' \
        --output text --query 'update.id' \
      || {
        rc=$?
        # "No changes needed" is success: the cluster is already in the requested state. Any other
        # failure is a failure, because leaving Gateway API off silently means every Gateway and
        # route this stack creates is accepted and never programmed.
        $AWS eks update-cluster-config \
          --region ${data.aws_region.current.region} \
          --name ${local.cluster_name} \
          --kubernetes-network-config '{"elasticLoadBalancing":{"enabled":true,"gatewayApi":{"crds":{"managed":${var.gateway_api_crds_managed}}}}}' \
          2>&1 | grep -q "No changes needed" && exit 0
        exit $rc
      }
    EOT
  }
}

# ---------------------------------------------------------------------------
# Argo CD capability: repository access and cluster authority
# ---------------------------------------------------------------------------
#
# See the variable documentation for why none of this is optional. The short version: the capability
# creates its role with a trust policy and no permissions, and its own access entry
# (AmazonEKSArgoCDClusterPolicy, plus AmazonEKSArgoCDPolicy on the `argocd` namespace) cannot list
# arbitrary resource types, which Argo CD's cluster cache needs in order to build.

data "aws_iam_policy_document" "capability_argocd_repositories" {
  count = var.enable_capability_argocd ? 1 : 0

  # CodeCommit. In-account, IAM-authenticated, no stored credential.
  dynamic "statement" {
    for_each = length(var.argocd_codecommit_repository_arns) > 0 ? [1] : []
    content {
      sid       = "PullFromCodeCommit"
      effect    = "Allow"
      actions   = ["codecommit:GitPull"]
      resources = var.argocd_codecommit_repository_arns
    }
  }

  # CodeConnections, for GitHub / GitLab / Bitbucket including self-managed servers.
  dynamic "statement" {
    for_each = length(var.argocd_codeconnections_arns) > 0 ? [1] : []
    content {
      sid       = "UseCodeConnections"
      effect    = "Allow"
      actions   = ["codeconnections:UseConnection"]
      resources = var.argocd_codeconnections_arns
    }
  }

  # Repository credentials held in Secrets Manager, so the credential never enters the cluster.
  dynamic "statement" {
    for_each = length(var.argocd_secrets_manager_secret_arns) > 0 ? [1] : []
    content {
      sid       = "ReadRepositoryCredentials"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.argocd_secrets_manager_secret_arns
    }
  }
}

# Only create the policy when at least one source is configured; an empty policy document is
# rejected by IAM, and an empty one would also be a lie about what this role can reach.
resource "aws_iam_role_policy" "capability_argocd_repositories" {
  count = var.enable_capability_argocd && (
    length(var.argocd_codecommit_repository_arns) > 0 ||
    length(var.argocd_codeconnections_arns) > 0 ||
    length(var.argocd_secrets_manager_secret_arns) > 0
  ) ? 1 : 0

  name   = "argocd-repositories"
  role   = aws_iam_role.capability_argocd[0].id
  policy = data.aws_iam_policy_document.capability_argocd_repositories[0].json
}

resource "aws_iam_role_policy_attachment" "capability_argocd_ecr" {
  count = var.enable_capability_argocd && var.argocd_ecr_pull ? 1 : 0

  role       = aws_iam_role.capability_argocd[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
}

# The authority to deploy. The capability makes its own access entry, so this associates an
# additional policy with that existing entry rather than creating one.
resource "aws_eks_access_policy_association" "capability_argocd" {
  count = var.enable_capability_argocd && var.argocd_cluster_access_policy_arn != "" ? 1 : 0

  cluster_name  = local.cluster_name
  principal_arn = aws_iam_role.capability_argocd[0].arn
  policy_arn    = var.argocd_cluster_access_policy_arn

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_capability.argocd]
}
