# The smallest configuration that produces a working open-source cluster: the BASE the EKS User
# Guide's agents section starts from. Copy it, set the values marked below, and apply:
#
#   (cd terraform/open-source && cp minimal.tfvars my.tfvars)
#   terraform -chdir=terraform/open-source init
#   ./scripts/apply.sh --root terraform/open-source -var-file=my.tfvars
#   terraform -chdir=terraform/open-source output next_steps
#
# What you get: an EKS Auto Mode cluster with network policy enforced, the ACK / kro / Argo CD EKS
# Capabilities, the ECR repositories and the CodeBuild project that builds into them, the agents'
# permissions boundary and the bastion. Agents call Amazon Bedrock directly on their own IAM role
# (direct_model_id, Claude Sonnet 5.5), and the base keeps no state. Every other layer is a
# variable that is off until its User Guide page turns it on; the agents page of the EKS User
# Guide is the map.
# example.tfvars next door is the other end of the range: every option, annotated.

# The only variable with no default.
region = "us-west-2"

# Becomes the cluster name and the prefix on nearly everything else.
name = "my-agents"

# Cluster admins. Unset, it is the IAM role (or user) running Terraform. Name the platform team's
# roles for anything shared, so the list is reviewable in Git:
# cluster_admin_principal_arns = ["arn:aws:iam::ACCOUNT_ID:role/YOUR_ROLE"]

# The managed Argo CD applies everything in gitops/. Its create call requires an IAM Identity
# Center instance in this account; Terraform finds it, creates the admin group and adds the people
# you name. With no instance, the apply says so and prints the call that creates one:
#
#   aws sso-admin create-instance --name eks-agents
enable_argocd                    = true
argocd_admin_existing_user_names = ["REPLACE-your-identity-center-user"]
# argocd_idc_region              = "us-east-1"   # only when the instance is in another Region

# The platform's code: the public repository at a revision you choose. Pin a release tag or a commit,
# so a later change reaches the cluster only when you move it. Your stack's values never go to it.
# gitops_repo_revision = "<tag or commit>"

# Not set here, and worth knowing why:
#
#   The optional components   Every one defaults off, so this file is the base: enable_gateway,
#                         enable_checkpoints, enable_session_state, enable_observability, mesh_mode
#                         and enable_ingress are each turned on later, one at a time.
#   agents                Empty is the normal case, and is what turns the `Agent` resource
#                         definition on. See the aws-services minimal.tfvars for the longer note.
#   vpc_id / subnet_ids   Unset means this configuration creates a VPC. Supply them to deploy into
#                         the network your organization already operates.
