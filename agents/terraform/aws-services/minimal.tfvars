# The smallest configuration that produces a working aws-services cluster: the BASE the EKS User
# Guide's agents section starts from. Copy it, set the values marked below, and apply:
#
#   (cd terraform/aws-services && cp minimal.tfvars my.tfvars)
#   terraform -chdir=terraform/aws-services init
#   ./scripts/apply.sh --root terraform/aws-services -var-file=my.tfvars
#   terraform -chdir=terraform/aws-services output next_steps
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

# NEEDED ONCE enable_gateway IS ON, not in the base, where agents call Bedrock directly and are
# given direct_model_id. With the gateway on, Terraform does not require this
# and the charts do: the apply succeeds and then every Argo CD Application fails to render with
# `model.gatewayModelId is required`. It is a name from the gateway's own catalogue, NOT a Bedrock model id or inference
# profile -- those return a 404 from an otherwise correct call. Read the catalogue once the gateway
# exists, and pick one that serves the OpenAI dialect:
#
#   curl -H "Authorization: Bearer $TOKEN" https://<gateway>/inference/v1/models
#
# The examples use a model that serves the OpenAI dialect, not the base's Sonnet 5.5.
# gateway_model_id = "bedrock/openai.gpt-oss-120b"

# Deliberately not set here, and worth knowing why:
#
#   agents                  Empty is the normal case. Empty is what turns the `Agent` resource
#                           definition on, so agents are declared in the cluster and kro composes
#                           each one's role, Pod Identity association and Sandbox.
#   allowed_agent_subjects  The gateway's inbound allowlist, and it takes AT MOST ONE subject --
#                           that is a hard limit of the gateway, not a simplification here. Leave it
#                           empty with more than one agent and separate them with the egress network
#                           policy and the policy engine.
#   vpc_id / subnet_ids     Unset means this configuration creates a VPC. Supply them to deploy into
#                           the network your organization already operates, which is the better
#                           answer for anything beyond an evaluation.
