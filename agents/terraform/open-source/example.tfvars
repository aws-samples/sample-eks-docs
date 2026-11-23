# Worked example for the open source path. Copy, change the placeholders, and keep your copy out of
# Git if it names anything you would rather not publish.
#
#   terraform init
#   terraform plan  -var-file=my.tfvars
#   terraform apply -var-file=my.tfvars
#
# The two agents below are the split from gitops/examples/reasoning-execution-split: a reasoning
# tier that holds the conversation and reaches a model through the gateway, and an execution tier
# that runs the code it produces with no network device at all.

name   = "agents-oss"
region = "us-west-2"

# NETWORK. Leave both of these out entirely and this configuration creates a VPC with three
# private and three public subnets, one NAT gateway and an S3 gateway endpoint -- which is the
# right choice for an evaluation and is what the defaults below describe.
#
# Set BOTH to run inside a network you already operate, which is the right choice for production.
# Setting only one is rejected at plan time.
#
#   vpc_id     = "vpc-REPLACE"
#   subnet_ids = ["subnet-REPLACE-a", "subnet-REPLACE-b", "subnet-REPLACE-c"]
#
# These three are ignored when you bring your own, and are shown at their defaults:
#
#   vpc_cidr           = "10.0.0.0/16"   # a /16, so each subnet is a /20 -- the VPC CNI gives pods real VPC addresses
#   az_count           = 3               # more zones means more places a node launch can succeed
#   single_nat_gateway = true            # false for one per zone; a NAT gateway is a per-hour and per-GB charge


cluster_admin_principal_arns = ["arn:aws:iam::111122223333:role/PlatformTeam"]

agent_namespaces = ["agents"]

# The mesh's own per-cluster trust domain. On this stack the mesh issues the identity, not AWS, so
# an identity under this domain cannot be presented to a system outside the cluster.
mesh_trust_domain = "cluster.local"

# Off. The mesh's self-signed CA costs nothing and issues under the same per-cluster domain. Turn
# this on only if the organization's policy requires mesh certificates to chain to a CA it
# operates: it bills per month and per certificate, and this stack signs one every time an agent
# presents mTLS.
enable_mesh_private_ca = false

# AGENTS: DECLARE THEM HERE **OR** FROM THE CLUSTER, NEVER BOTH -- AND THE EXAMPLES NEED THE SECOND.
#
# `agentResource.enabled` is derived as `length(var.agents) == 0`, so a non-empty map here switches
# OFF the agent resource definition in gitops/base/templates. That definition is what creates the
# `Agent` custom resource, and this repository's examples, such as
# gitops/examples/reasoning-execution-split, are `Agent` resources. Declare agents below and those
# examples cannot be applied at all: the CRD does not exist.
#
# The failure is silent, which is why this warning is this long. The base chart reports Synced and
# Healthy because the resource definition is simply absent from its manifest set rather than broken,
# `kubectl get agents` says "No resources found", and nothing anywhere mentions `var.agents`.
#
# So pick deliberately:
#
#   agents = {}   -- the resource definition renders, and a team declares each agent in the cluster
#                    as an `Agent`. kro composes the ServiceAccount, the IAM role and its Pod
#                    Identity association through ACK, the Deployment, the Service, the network
#                    policy and the route. This is what the examples use, and it is the default
#                    below.
#
#   agents = {...} -- Terraform pre-creates each agent's IAM role and Pod Identity association, and
#                    the team ships ordinary Deployments referencing those service accounts. Right
#                    when IAM has to be reviewed in Terraform rather than composed in-cluster.
#                    gitops/examples/mcp-server and gitops/examples/chat-ui are plain Deployments
#                    and work either way; the two `Agent` examples do not.
#
# The pre-declared form is kept below, commented, because it is a legitimate choice and the field
# shapes are not obvious.
agents = {}

# agents = {
#     # The reasoning tier. Its egress goes through AgentGateway, so the gateway may assume this role
#     # and sign its model calls as this agent. That mapping is where per-agent AWS authority comes
#     # from on this stack.
#     research = {
#       namespace               = "agents"
#       reached_through_gateway = true
#
#       bedrock_model_arns = [
#         # A cross-region profile (the `us.` prefix) is authorized against the foundation-model
#         # ARN in whichever region served the call, so list them all. One region gives a bare 403.
#         "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-5-5",
#         "arn:aws:bedrock:us-east-2::foundation-model/anthropic.claude-sonnet-5-5",
#         "arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-5-5",
#         "arn:aws:bedrock:us-west-2:111122223333:inference-profile/us.anthropic.claude-sonnet-5-5",
#       ]
#
#       bedrock_guardrail_arn     = "arn:aws:bedrock:us-west-2:111122223333:guardrail/REPLACE"
#       bedrock_guardrail_version = "1"
#
#       needs_checkpoints = true
#     }
#
#     # The execution tier. No gateway, because it has no network device for a gateway to be in the
#     # path of, and no model ARNs for the same reason. Work arrives on a volume and results leave the
#     # same way. The validation on var.agents refuses model ARNs here.
#     execution = {
#       namespace               = "agents"
#       reached_through_gateway = false
#       bedrock_model_arns      = []
#       needs_checkpoints       = true
#     }
# }

# The destinations whose long-lived credentials the gateway holds so the pod does not. One entry
# per destination per caller: two agents reaching the same service get two entries and carry
# different authority to it. Terraform creates the secret and never its value, and for a consented
# service the value only exists after somebody approves it in a browser. The open source gateway
# runs no consent flow itself; oauth_consent deploys a receiver that writes the approved token.
third_party_credentials = {
  github-research = {
    destination = "api.github.com"
    caller      = "research"
  }

  slack-research = {
    destination = "slack.com"
    caller      = "research"
  }
}

# Whoever sets those values. Keep it short: every principal here is another way a long-lived
# third-party token leaves the account.
credential_admin_principal_arns = ["arn:aws:iam::111122223333:role/PlatformTeam"]

gitops_repo_url = "https://git.example.com/REPLACE/eks-agents-paved-paths.git"

# --- The managed Argo CD, which is ON by default ---------------------------
#
# Nothing in gitops/ reaches the cluster without it. Setting enable_argocd = false gives you every
# other resource and no GitOps control plane -- running that is then yours, and
# scripts/install-platform.sh is the supported fallback.
#
# It needs an IAM Identity Center instance in THIS account and region. That is a create-time
# requirement rather than a login one: reconciliation authenticates with the capability's own role,
# and `configuration.argoCd.awsIdc` is required anyway. Everything else is automatic -- the instance
# is discovered, the admin group is created, the people below are added to it, and the ADMIN role
# mapping is composed. With no instance the apply fails with the single call that creates one.
#
# enable_argocd = false   # only where no Identity Center instance can exist
#
# Who administers Argo CD. Prefer naming people who already exist in the Identity Store; use
# argocd_admin_users to create them, and note Identity Center has no API to set a password -- the
# person sets their own at first sign-in, from the invitation it emails.
#
# argocd_admin_existing_user_names = ["alice"]
# argocd_admin_users = [{
#   user_name = "bob", display_name = "Bob Example",
#   given_name = "Bob", family_name = "Example", email = "bob@example.com",
# }]
#
# argocd_manage_admin_group = false    # manage the group and mappings yourself instead
# argocd_admin_group_name   = "platform-argocd-admins"
#
# For an instance in another region, name it and its region; the identity-store objects are then
# yours to create too, because they live beside the instance.
#
# argocd_idc_instance_arn = "arn:aws:sso:::instance/ssoins-REPLACE"
# argocd_idc_region       = "us-east-1"

# --- Ingress, which is how a person or another workload reaches an agent -------------
#
# OFF BY DEFAULT, because it needs three things only you have: a domain, an ACM certificate for it,
# and an identity provider.
#
# What turning it on creates: a Route 53 zone for the agents' subdomain, the Gateway and
# GatewayClass (which needs the cluster's Gateway API setting, switched on with this variable), an
# ALB with an OIDC or Cognito listener rule, and external-dns to write each agent's record -- which
# Terraform cannot, because the record is an alias to a load balancer that does not exist until the
# chart syncs and the Gateway programs.
#
# The in-cluster half of this lives in gitops/base and is identical on both paths. What differs is
# only who runs the gateway the agents call OUT through; ingress is inbound.
#
# See the agents-ingress page of the EKS User Guide.
#
# enable_ingress          = true
# ingress_domain_name     = "agents.example.com"
# ingress_certificate_arn = "arn:aws:acm:us-west-2:111122223333:certificate/REPLACE"
# ingress_public_zone_id  = "Z0REPLACE"
#
# Who a person signs in with. "cognito" (the default) uses a Cognito pool's own users; "oidc"
# federates an existing provider into the pool, and the agent receives Cognito's claims; "oidc-direct"
# has the load balancer call the provider itself, and the agent receives the provider's own claims
# and access token. Register the provider's client with the idp_redirect_uris from
# `terraform output ingress`. oidc-direct needs enable_platform_secrets (the default).
# ingress_idp = "oidc-direct"
#
# ingress_oidc = {
#   issuer                 = "https://idp.example.com"
#   authorization_endpoint = "https://idp.example.com/oauth2/authorize"
#   token_endpoint         = "https://idp.example.com/oauth2/token"
#   user_info_endpoint     = "https://idp.example.com/oauth2/userinfo"
#   jwks_uri               = "https://idp.example.com/oauth2/keys"
#   client_id              = "REPLACE"
#   client_secret_arn      = "arn:aws:secretsmanager:us-west-2:111122223333:secret:ingress-idp-REPLACE"
# }

# AWS WAF on the ingress load balancer, with a per-IP rate rule. Needs enable_ingress.
# enable_ingress_waf            = true
# ingress_waf_rate_limit_per_ip = 2000

# --- A guardrail on every model call ------------------------------------------
#
# The gateway applies this Amazon Bedrock guardrail to every model request and response, whatever
# the agent asked for, and fails closed when the guardrail service doesn't answer. Name a published
# version, not DRAFT.
# gateway_guardrail = {
#   arn     = "arn:aws:bedrock:us-west-2:111122223333:guardrail/abcd1234efgh"
#   version = "1"
# }

# --- Cost allocation: an optional switch, off by default -------------------------------------
#
# Turn on to split spend in Cost Explorer and the Cost and Usage Report by agent and by cluster.
# Terraform activates five tag keys, as billing records them:
#   iamPrincipal/agent, iamPrincipal/cluster   usage signed by an agent's own role (Pod Identity
#                                              session tags)
#   aws:eks:cluster-name                       what EKS and Auto Mode create, nodes included
#   eks-agents/path, eks-agents.path           this stack's own resources
# On this path the gateway signs as the calling agent, so Bedrock spend splits per agent too.

# Three things decide whether it can succeed, which is why it is off:
#   - It is an ACCOUNT-LEVEL billing setting, so the apply needs payer (management) account
#     credentials. From a member account it fails with AccessDenied.
#   - A key is activatable only once it is in the account's tag inventory, so set this on a SECOND
#     apply, after agents have made calls -- not on the first.
#   - It is not retroactive, and Cost Explorer shows it up to 24 hours later.
# Turning it off again, or `terraform destroy`, deactivates the keys for the whole account.
# activate_cost_allocation_tags = true
