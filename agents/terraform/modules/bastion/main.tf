# The only thing that can reach this cluster's API server.
#
# The control plane endpoint is private-only and that is deliberate -- see the vpc_config block in
# terraform/modules/agent-cluster. The consequence is that nothing outside the VPC can run kubectl
# against it, which includes every command in this repository's own README: bootstrapping GitOps,
# the four verification checks, and all of scripts/exercise.sh. Without something inside the VPC,
# `terraform apply` hands back a cluster whose documented next step cannot be performed.
#
#
# REACHED THROUGH SSM, NOT SSH. There is no key pair, no public IP, and the security group below has
# NO INBOUND RULES AT ALL. Session Manager works by the agent polling outbound, so inbound access is
# not merely closed, it is unnecessary -- which is the only shape that belongs on a host holding
# cluster-admin.

data "aws_partition" "current" {}
data "aws_region" "current" {}

# Amazon Linux 2023, resolved rather than pinned: a bastion is cattle, and a stale AMI is a host
# missing security patches for the sake of reproducibility nobody needs here.
#
# THE ARCHITECTURE HAS TO MATCH THE NODES, not the cheapest instance family. The README's deployment
# flow ends with "build and push the agent images", and this host is the only place inside the VPC
# that can do it -- so a `docker build` here has to produce an image the cluster can run. EKS Auto
# Mode's default node pool is x86_64, and an arm64 bastion silently builds arm64 images that the
# nodes refuse with `exec format error` after a pull that succeeded: the nodes come up amd64 while
# the bastion is aarch64.
#
# Set architecture = "arm64" (and a Graviton instance_type) when the cluster's node pools are
# Graviton, which is the case worth having the variable for.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${var.architecture}"
}

locals {
  tags = merge(var.tags, { "eks-agents/cluster" = var.cluster_name })

  # EC2 FORBIDS `/` IN A TAG KEY, and nothing else here does.
  #
  #   InvalidParameterValue: 'eks-agents/path' is not a valid tag key. Tag keys must match pattern
  #   ([0-9a-zA-Z\-_+=,.@:]{1,255})
  #
  # Found at RunInstances, which is late: the security group, both IAM objects and the access entry
  # are already created by then, so the apply half-succeeds and leaves the instance missing. Every
  # other resource in this module takes `eks-agents/cluster` as-is -- IAM and EKS both allow `/` --
  # so this is the one place the key has to change.
  #
  # `/` becomes `.`, giving `eks-agents.cluster`. THE TEARDOWN SWEEP HAS TO KNOW BOTH FORMS: it
  # queries the tagging API for `eks-agents/cluster`, which an EC2 instance can never carry, so a
  # sweep that knows only the slashed key reports clean while leaving the bastion and its security
  # group running. scripts/teardown.sh queries both.
  ec2_tags = { for k, v in local.tags : replace(k, "/", ".") => v }
}

# --- Network -----------------------------------------------------------------
#
# Egress only. 443 covers the SSM endpoints, the EKS API, ECR and the chart registries; the host
# needs nothing else, and nothing needs to reach the host.
resource "aws_security_group" "this" {
  name        = "${var.cluster_name}-bastion"
  description = "SSM-managed bastion for ${var.cluster_name}. Egress only; no inbound rules by design."
  vpc_id      = var.vpc_id

  tags = merge(local.ec2_tags, { Name = "${var.cluster_name}-bastion" })

  lifecycle {
    create_before_destroy = true
  }
}

# Deliberately not an `ingress` block. A bastion that accepts inbound connections is a bastion with
# an attack surface; this one is reached by the SSM agent dialling out.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "SSM, the EKS API, ECR and chart registries"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
  tags              = local.ec2_tags
}

# DNS to the VPC resolver. Scoped to the VPC rather than the internet: the host resolves cluster and
# AWS endpoints, and has no reason to query an outside resolver.
resource "aws_vpc_security_group_egress_rule" "dns_udp" {
  security_group_id = aws_security_group.this.id
  description       = "DNS to the VPC resolver"
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = var.vpc_cidr
  tags              = local.ec2_tags
}

resource "aws_vpc_security_group_egress_rule" "dns_tcp" {
  security_group_id = aws_security_group.this.id
  description       = "DNS to the VPC resolver"
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = var.vpc_cidr
  tags              = local.ec2_tags
}

# --- Identity ----------------------------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = "${var.cluster_name}-bastion"
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  permissions_boundary = var.permissions_boundary_arn != "" ? var.permissions_boundary_arn : null
  tags                 = local.tags
}

# The managed policy Session Manager requires. Nothing else: this role's reach into the cluster comes
# from the EKS access entry below, not from an IAM policy.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# `aws eks update-kubeconfig` needs DescribeCluster. `aws eks get-token` signs locally and does not
# need the call, so without this grant kubectl works only from a kubeconfig written by hand.
data "aws_iam_policy_document" "describe_cluster" {
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [var.cluster_arn]
  }

  # WHAT scripts/exercise.sh READS, because this is the host it runs on.
  #
  # The telemetry phase has nothing in-cluster to read on the aws-services path -- the ADOT
  # collector exports to CloudWatch and X-Ray and publishes no Prometheus endpoint -- so it asserts
  # against CloudWatch instead. Without these it degrades to
  #
  #   ! could not read CloudWatch (no permission from here, or no metrics yet); nothing concluded
  #
  # which is a security-adjacent check reporting nothing on a thin credential rather than failing.
  # The phase then skips against a cluster whose metrics have in fact arrived.
  # The ingress phase reads the live load balancer's scheme for the same reason, and the identity
  # phase confirms the Pod Identity associations the agent resource composed.
  #
  # All reads, all list-shaped, so none of them is resource-scopable in a useful way: ListMetrics
  # and DescribeLoadBalancers take no resource, and DescribeLogStreams is scoped below.
  statement {
    sid    = "ExerciseReads"
    effect = "Allow"
    actions = [
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "elasticloadbalancing:DescribeLoadBalancers",

      # scripts/teardown.sh's "load balancers released" check reads the tagging API. Without this the
      # check fails on the bastion and the teardown sleeps its full 240 s cap instead ("cannot check
      # load balancers ... released from here (exit 2): sleeping 240s").
      "tag:GetResources",

      # THE TARGET GROUP READS, and they are not optional for the ingress phase. Without them the
      # only view of why an exposed agent is unreachable is gone: a target can be registered,
      # reachable and `unhealthy` because the health check path is wrong, and nothing in the cluster
      # says so -- the Gateway is Programmed and the route Accepted. Without them the phase's
      # target-health read comes back AccessDenied on this role and the diagnosis has to be done
      # from outside the VPC, which is the one place the private endpoint rules out.
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeRules",

      # Teardown lists the account's repositories to find this stack's, so this one is a list call.
      # DescribeImages, which reads back what the bastion pushed, is in the ECR policy below, on
      # this stack's repositories only.
      "ecr:DescribeRepositories",

      # The decisions phase finds the policy decisions dashboard by its title. GetDashboard is
      # scoped below.
      "cloudwatch:ListDashboards",
    ]
    resources = ["*"]
  }

  # The identity phase confirms the Pod Identity associations the agent resource composed: this
  # cluster's associations only.
  statement {
    sid       = "ExercisePodIdentityReads"
    effect    = "Allow"
    actions   = ["eks:ListPodIdentityAssociations"]
    resources = [var.cluster_arn]
  }

  statement {
    sid     = "ExercisePodIdentityDescribe"
    effect  = "Allow"
    actions = ["eks:DescribePodIdentityAssociation"]
    resources = [
      "arn:${data.aws_partition.current.partition}:eks:*:*:podidentityassociation/${var.cluster_name}/*",
    ]
  }

  # This stack's dashboards are all named <name>-..., the same prefix the reads above use.
  statement {
    sid       = "ExerciseDashboardRead"
    effect    = "Allow"
    actions   = ["cloudwatch:GetDashboard"]
    resources = ["arn:${data.aws_partition.current.partition}:cloudwatch::*:dashboard/${var.cluster_name}-*"]
  }

  # THE STACK'S BUCKETS' SECURITY SETTINGS, read-only, by name prefix: scripts/exercise.sh checks that
  # each bucket still has its public access block, BucketOwnerEnforced and the TLS-only policy. A
  # bad refresh can make an apply delete all three on a live bucket, and nothing in the cluster
  # changes when they go, so it is checked rather than assumed.
  statement {
    sid    = "BucketSecurityReads"
    effect = "Allow"
    actions = [
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketOwnershipControls",
      "s3:GetBucketPolicy",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketVersioning",
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.cluster_name}-*"]
  }

  # The delegation phase confirms the identity-change alerts (identity_change_alerts): the topic and
  # the rules that publish to it, in this region and the IAM rule's forward from us-east-1.
  statement {
    sid       = "IdentityAlertReads"
    effect    = "Allow"
    actions   = ["sns:GetTopicAttributes"]
    resources = ["arn:${data.aws_partition.current.partition}:sns:*:*:${var.cluster_name}-identity-changes"]
  }
  statement {
    sid       = "IdentityAlertRuleReads"
    effect    = "Allow"
    actions   = ["events:DescribeRule"]
    resources = ["arn:${data.aws_partition.current.partition}:events:*:*:rule/${var.cluster_name}-identity-*"]
  }
  # exercise.sh's ingress phase compares the web ACL the LoadBalancerConfiguration declares with the
  # one actually associated with the load balancer (enable_ingress_waf). GetWebACLForResource also
  # needs GetWebACL on the web ACL it returns, and the load balancer's own GetLoadBalancerWebACL. The
  # load balancer is named by the controller, not with the cluster's prefix, so it is any application
  # load balancer here; the web ACL is this stack's.
  statement {
    sid       = "IngressWebAclReads"
    effect    = "Allow"
    actions   = ["wafv2:GetWebACL"]
    resources = ["arn:${data.aws_partition.current.partition}:wafv2:*:*:regional/webacl/${var.cluster_name}-*/*"]
  }
  # GetWebACLForResource is authorized against every web ACL (regional/webacl/*/*), because the
  # caller doesn't know which one is associated until the answer: a grant scoped to this stack's
  # names is refused with "no identity-based policy allows ... on regional/webacl/*/*".
  statement {
    sid       = "IngressWebAclLookup"
    effect    = "Allow"
    actions   = ["wafv2:GetWebACLForResource"]
    resources = ["arn:${data.aws_partition.current.partition}:wafv2:*:*:regional/webacl/*/*"]
  }
  statement {
    sid       = "IngressLoadBalancerWebAclReads"
    effect    = "Allow"
    actions   = ["elasticloadbalancing:GetLoadBalancerWebACL"]
    resources = ["arn:${data.aws_partition.current.partition}:elasticloadbalancing:*:*:loadbalancer/app/*/*"]
  }
  statement {
    sid    = "IdentityAlertTargetReads"
    effect = "Allow"
    # ListRuleNamesByTarget takes no resource.
    actions   = ["events:ListRuleNamesByTarget"]
    resources = ["*"]
  }

  statement {
    sid    = "ExerciseLogReads"
    effect = "Allow"
    # FilterLogEvents: the decisions phase reads a DENY verdict and an admission refusal back.
    actions   = ["logs:DescribeLogGroups", "logs:DescribeLogStreams", "logs:FilterLogEvents"]
    resources = ["arn:${data.aws_partition.current.partition}:logs:*:*:log-group:/aws/eks/${var.cluster_name}/*"]
  }
}

resource "aws_iam_role_policy" "describe_cluster" {
  name   = "describe-cluster"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.describe_cluster.json
}

# Push access to the stack's own image repositories, so the documented build-and-push step can be
# done on the host that can already reach the cluster. GetAuthorizationToken has no resource scope --
# the API takes none -- so it is granted on `*` and the repository-scoped statement is what bounds
# what can actually be written.
data "aws_iam_policy_document" "ecr" {
  count = length(var.ecr_repository_arns) > 0 ? 1 : 0

  statement {
    sid       = "AuthToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PushPullStackRepos"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = var.ecr_repository_arns
  }
}

resource "aws_iam_role_policy" "ecr" {
  count  = length(var.ecr_repository_arns) > 0 ? 1 : 0
  name   = "ecr-push"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.ecr[0].json
}

# Teardown steps 8 and 9 (scripts/teardown.sh), so the whole teardown short of `terraform destroy`
# runs on the one host that reaches the cluster. See var.teardown_access for why. DeleteRepository
# and the S3 deletes are scoped to this stack's own repositories and bucket; the two List calls take
# no resource, and are what the steps use to find them and to prove this credential can see.
# The bucket itself is never deletable from here: that stays terraform's.
locals {
  teardown_repos  = var.teardown_access ? var.ecr_repository_arns : []
  teardown_bucket = var.teardown_access ? var.checkpoint_bucket_arn : ""
}

data "aws_iam_policy_document" "teardown" {
  count = var.teardown_access ? 1 : 0

  statement {
    sid       = "FindStackResources"
    effect    = "Allow"
    actions   = ["ecr:DescribeRepositories", "s3:ListAllMyBuckets"]
    resources = ["*"]
  }

  # Step 7's capability access entries, which EKS leaves behind when a capability is deleted. Without
  # the list the step finds nothing and reports "no capability access entries left" while all three
  # are still there. Delete is scoped to this stack's own
  # <cluster>-capability-* roles.
  statement {
    sid       = "ListClusterAccessEntries"
    effect    = "Allow"
    actions   = ["eks:ListAccessEntries"]
    resources = [var.cluster_arn]
  }
  # TEARDOWN STEP 6, AND STEP 7'S argocd NAMESPACE CHECK. Without ListCapabilities the bastion reads
  # an empty list, reports "no EKS capabilities", and then cannot tell whether the ARGOCD capability
  # still uses its namespace, so the namespace stays.
  # Delete is scoped to this stack's three capabilities by name.
  statement {
    sid       = "ListClusterCapabilities"
    effect    = "Allow"
    actions   = ["eks:ListCapabilities"]
    resources = [var.cluster_arn]
  }
  statement {
    sid     = "DeleteStackCapabilities"
    effect  = "Allow"
    actions = ["eks:DescribeCapability", "eks:DeleteCapability"]
    resources = [
      for c in ["ack", "kro", "argocd"] :
      # capability/<cluster>/<type>/<name>/<id>, as list-capabilities reports it.
      "arn:${data.aws_partition.current.partition}:eks:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:capability/${var.cluster_name}/${c}/${var.cluster_name}-${c}/*"
    ]
  }
  statement {
    sid     = "DeleteCapabilityAccessEntries"
    effect  = "Allow"
    actions = ["eks:DeleteAccessEntry"]
    resources = [
      "arn:${data.aws_partition.current.partition}:eks:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:access-entry/${var.cluster_name}/role/${data.aws_caller_identity.current.account_id}/${var.cluster_name}-capability-*",
    ]
  }

  dynamic "statement" {
    for_each = length(local.teardown_repos) > 0 ? [1] : []
    content {
      sid       = "DeleteStackRepositories"
      effect    = "Allow"
      actions   = ["ecr:ListImages", "ecr:BatchDeleteImage", "ecr:DeleteRepository"]
      resources = local.teardown_repos
    }
  }

  dynamic "statement" {
    for_each = local.teardown_bucket != "" ? [1] : []
    content {
      sid       = "ListCheckpointBucket"
      effect    = "Allow"
      actions   = ["s3:ListBucket", "s3:ListBucketVersions"]
      resources = [local.teardown_bucket]
    }
  }

  dynamic "statement" {
    for_each = local.teardown_bucket != "" ? [1] : []
    content {
      sid       = "EmptyCheckpointBucket"
      effect    = "Allow"
      actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
      resources = ["${local.teardown_bucket}/*"]
    }
  }
}

resource "aws_iam_role_policy" "teardown" {
  count  = var.teardown_access ? 1 : 0
  name   = "teardown"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.teardown[0].json
}

# Read access to the GitOps repository, when it is CodeCommit.
#
# THE BOOTSTRAP IS THREE `kubectl apply`s FROM A CLONE OF THE REPOSITORY, and this is the host they
# have to run on, so the host needs to be able to clone it. Without this, the clone fails with a
# bare `403` on the URL and nothing says which credential is missing -- the AWS CLI on the same
# host works, because the failure is the git credential helper calling
# codecommit:GitPull.
#
# CodeCommit only. A GitHub, GitLab or Bitbucket repository is reached with a credential that is not
# an IAM grant, so for those this stays empty and the operator puts a deploy key or token on the
# host themselves -- there is nothing Terraform can create for it.
data "aws_iam_policy_document" "gitops_repo" {
  count = length(var.gitops_codecommit_repository_arns) > 0 ? 1 : 0

  statement {
    sid       = "ClonePlatformRepository"
    effect    = "Allow"
    actions   = ["codecommit:GitPull"]
    resources = var.gitops_codecommit_repository_arns
  }
}

resource "aws_iam_role_policy" "gitops_repo" {
  count  = length(var.gitops_codecommit_repository_arns) > 0 ? 1 : 0
  name   = "gitops-repo-read"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.gitops_repo[0].json
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.cluster_name}-bastion"
  role = aws_iam_role.this.name
  tags = local.tags
}

# What makes kubectl on the host actually authorized. Without this the host can reach the endpoint
# and every call returns a 403 that looks like a networking problem.
resource "aws_eks_access_entry" "this" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.this.arn
  type          = "STANDARD"
  tags          = local.tags
}

resource "aws_eks_access_policy_association" "this" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.this.arn
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.this]
}

# --- The host ----------------------------------------------------------------

resource "aws_instance" "this" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type

  # A PRIVATE subnet. The host reaches SSM and the internet through the NAT gateway; it is not
  # reachable from either.
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.this.id]
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.this.name

  # IMDSv2 only. A bastion holding cluster-admin is exactly the host where a server-side request
  # forgery reaching the metadata service matters.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
    kms_key_id  = var.kms_key_arn != "" ? var.kms_key_arn : null
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    cluster_name    = var.cluster_name
    region          = data.aws_region.current.region
    kubectl_version = var.kubectl_version
    architecture    = var.architecture
    gitops_repo_url = var.gitops_repo_url
  })

  tags = merge(local.ec2_tags, { Name = "${var.cluster_name}-bastion" })

  # The AMI is read from SSM's "latest AL2023" parameter, so without this every later plan sees a
  # new value and REPLACES the bastion -- a change to any unrelated variable destroys the host an
  # operator is working on. Patch the running host with SSM Patch Manager or
  # taint it deliberately; do not let an image release decide.
  lifecycle {
    ignore_changes = [ami]
  }
}

# WITHOUT THIS THE HOST CAN DO NOTHING, and the failure is a hang rather than an error.
#
# A private API endpoint is reachable only from inside the VPC, and "inside the VPC" is not enough:
# the cluster's own security group admits inbound 443 from ITSELF and nothing else, so a request
# from any other security group is dropped silently. kubectl sits there until it times out, which
# reads as the endpoint being unreachable rather than as a policy decision -- and every
# `aws eks update-kubeconfig` succeeded, so the kubeconfig looks right.
#
# Without this rule, the cluster security group's only ingress rule references itself, and
# `kubectl get nodes` from the bastion never returns.
#
# This is a rule on the CLUSTER's security group rather than the bastion's, because that is the side
# doing the dropping. EKS does not reconcile rules off its cluster security group, so adding one
# here is durable.
resource "aws_vpc_security_group_ingress_rule" "cluster_from_bastion" {
  security_group_id            = var.cluster_security_group_id
  referenced_security_group_id = aws_security_group.this.id
  description                  = "kubectl from the ${var.cluster_name} bastion to the private API endpoint"
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  tags                         = local.ec2_tags
}

# ---------------------------------------------------------------------------
# A staging bucket for scripts/run-stack.sh
# ---------------------------------------------------------------------------
#
# run-stack.sh copies the working tree to the bastion as an archive in S3, fetched through a
# presigned URL. It has its own bucket rather than the checkpoint bucket, which a base-only cluster
# does not have (enable_checkpoints is off by default): without one, the teardown stops at "no
# checkpoint_bucket_name in outputs" and can go on to delete the ACK capability with an Agent still
# present, orphaning the agent's IAM role and, behind it, the permissions boundary. The bucket holds
# archives only, each deleted after its run and expired after a day regardless, so force_destroy is
# safe here as it is not for agent data.
data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "staging" {
  bucket        = "${var.cluster_name}-bastion-staging-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "staging" {
  bucket                  = aws_s3_bucket.staging.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "staging" {
  bucket = aws_s3_bucket.staging.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "staging" {
  bucket = aws_s3_bucket.staging.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "staging" {
  bucket = aws_s3_bucket.staging.id
  rule {
    id     = "expire-build-contexts"
    status = "Enabled"
    filter {}
    expiration {
      days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

data "aws_iam_policy_document" "staging_tls_only" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.staging.arn,
      "${aws_s3_bucket.staging.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "staging" {
  bucket     = aws_s3_bucket.staging.id
  policy     = data.aws_iam_policy_document.staging_tls_only.json
  depends_on = [aws_s3_bucket_public_access_block.staging]
}
