variable "cluster_name" {
  description = "The cluster this bastion administers. Also the name prefix on every resource here."
  type        = string
}

variable "cluster_arn" {
  description = "The cluster's ARN, which scopes the one IAM read this host is granted (eks:DescribeCluster)."
  type        = string
}

variable "vpc_id" {
  description = "The VPC the cluster's API endpoint is reachable in."
  type        = string
}

variable "vpc_cidr" {
  description = "The VPC's CIDR, used to scope DNS egress to the VPC resolver rather than the internet."
  type        = string
}

variable "subnet_id" {
  description = <<-EOT
    A PRIVATE subnet. The host has no public IP and reaches SSM through the NAT gateway, so a public
    subnet buys nothing and costs an unnecessary route to the internet inbound.
  EOT
  type        = string
}

variable "instance_type" {
  description = <<-EOT
    Small on purpose. This host runs kubectl, helm, git and container builds, not workloads.

    The default is x86_64 to match EKS Auto Mode's default node pool, because an image built here
    has to run there. Change it together with `architecture`.
  EOT
  type        = string
  default     = "t3.small"
}

variable "kubectl_version" {
  description = <<-EOT
    The kubectl release the host installs, as a `v1.33.0`-style tag.

    Keep it within one minor of the cluster: kubectl supports one minor version of skew in either
    direction, and a wider gap fails on resources it cannot parse rather than on connection.
  EOT
  type        = string
  default     = "v1.36.6"
}

variable "permissions_boundary_arn" {
  description = "Optional permissions boundary for the instance role, for accounts that require one."
  type        = string
  default     = ""
}

variable "kms_key_arn" {
  description = "Optional CMK for the root volume. Empty uses the account's EBS default key."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags applied to every resource here."
  type        = map(string)
  default     = {}
}

variable "cluster_security_group_id" {
  description = <<-EOT
    The cluster's own security group, from the agent-cluster module's cluster_security_group_id
    output.

    The module adds one ingress rule to it: 443 from this bastion. Without that rule the host is
    inside the VPC and still cannot reach the API server -- the cluster security group admits only
    itself, so the request is dropped and kubectl hangs rather than failing.
  EOT
  type        = string
}

variable "architecture" {
  description = <<-EOT
    The bastion's CPU architecture, as the AL2023 AMI alias spells it: `x86_64` or `arm64`.

    MATCH THE CLUSTER'S NODES. This host is where the README's "build and push the agent images"
    step happens, and a `docker build` here produces an image for this architecture. EKS Auto Mode's
    default node pool is x86_64, so an arm64 bastion builds images the nodes refuse with
    `exec format error` -- after a pull that succeeded, which makes it look like an application fault
    rather than an architecture mismatch.

    Change this together with instance_type; the two have to agree.
  EOT
  type        = string
  default     = "x86_64"

  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "architecture must be x86_64 or arm64, spelled as the AL2023 AMI alias does."
  }
}

variable "ecr_repository_arns" {
  description = <<-EOT
    The stack's image repositories, from the agent-cluster module's ecr_repository_arns output.

    Grants this host push access to exactly those repositories, so the build-and-push step in the
    README can be performed from inside the VPC. Empty grants no ECR access at all, which is correct
    when images are built in CI rather than here.
  EOT
  type        = list(string)
  default     = []
}

variable "checkpoint_bucket_arn" {
  description = "The checkpoint bucket, from the durable-storage module. With teardown_access, this host may empty it (not delete it). Empty when enable_checkpoints is off."
  type        = string
  default     = ""
}

variable "teardown_access" {
  description = <<-EOT
    Let this host run steps 8 and 9 of scripts/teardown.sh: delete THIS stack's image repositories
    (ecr_repository_arns) and empty THIS stack's checkpoint bucket (checkpoint_bucket_arn) -- the
    two things `terraform destroy` refuses to do while they hold anything. Scoped to those
    resources only, plus the two account-wide list calls the steps use to find them.

    Without it the teardown splits across two credentials: steps 0-7 need kubectl, so they run
    here, and steps 8-9 need account writes this host lacks. Skipping steps 8-9 leaves
    `terraform destroy` failing on RepositoryNotEmptyException and BucketNotEmpty. With it, the whole in-cluster and pre-destroy teardown runs on this host.

    Off means this host can read and push images and nothing more; run steps 8-9 elsewhere.
  EOT
  type        = bool
  default     = true
}

variable "gitops_codecommit_repository_arns" {
  description = <<-EOT
    CodeCommit repository ARNs this host may clone, for the GitOps repository the bootstrap applies
    from.

    The bootstrap is three `kubectl apply`s from a clone of the repository, and this is the host
    they have to run on -- so without this the documented next step fails on the first command,
    with a bare `403` on the URL and nothing naming the missing permission.

    CodeCommit only, because that is the only Git host reachable with an IAM grant. For GitHub,
    GitLab or Bitbucket, leave it empty and put a deploy key or token on the host yourself; there is
    nothing Terraform can create for those.
  EOT
  type        = list(string)
  default     = []
}

variable "gitops_repo_url" {
  description = <<-EOT
    Repository to clone onto the host at /opt/eks-agents.

    Every kubectl step in this repository's README runs on this host, and all of them apply a file
    from the tree -- the bootstrap objects, scripts/install-platform.sh, the examples. Without the
    clone, "run this on the bastion" hides a step: getting the tree there.

    The clone is non-fatal. An unreachable or private URL leaves an explanation in
    /var/log/bastion-clone.log and the host still comes up, because it is also how you reach a
    cluster whose GitOps you are not using. This host holds no git credential by design.
  EOT
  type        = string
  default     = ""
}
