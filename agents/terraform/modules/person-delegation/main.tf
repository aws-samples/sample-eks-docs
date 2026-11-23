# ONE TOKEN THAT NAMES THE PERSON AND THE AGENT (person_access_delegated_token on the open source
# path). Used with terraform/modules/person-access, on the same pool.
#
# Without this, a tool behind the gateway gets two things: the person's own token in x-person-token,
# and no caller token at all, because the gateway terminates the agent's. The tool verifies the
# person and has to trust the gateway for which agent asked; and the person's raw token, valid for
# any relying party that accepts the pool, travels all the way to the tool.
#
# With it, the gateway exchanges the pair at the pool (RFC 8693 delegation): the person's access
# token as the subject, the agent's own projected service account token as the actor. Cognito
# returns ONE token, signed by the pool, with
#
#   sub   the person
#   aud   this deployment's tools (var.tool_audience), so it is useless at any other relying party
#   act   {sub: system:serviceaccount:<namespace>:<agent>, iss: the cluster's OIDC issuer}
#
# and the gateway sends the tool that token instead of either original. The tool verifies one
# signature and reads both identities from it.
#
# WHAT COGNITO DOES NOT DECIDE. Cognito validates the actor token's signature and audience but does
# not restrict WHICH workload may act: an agent with no person access can also obtain a delegated
# token. The gateway's tool policy (person_access_agents) and the tool's own check of
# act.sub are what refuse it, and both stay on.

locals {
  # The cluster's issuer as a provider Cognito trusts for actor tokens. The name is what the token
  # request names (actor_token_provider_name).
  actor_provider_name = "eks-agents"
}

# The tools a delegated token is for. Its identifier is the token's audience.
resource "aws_cognito_resource_server" "tools" {
  user_pool_id = var.user_pool_id
  identifier   = var.tool_audience
  name         = "${var.name} tools"

  scope {
    scope_name        = "person"
    scope_description = "Act for the person named in the token, as the agent named in its act claim"
  }
}

# THE CLUSTER'S OIDC ISSUER, so Cognito can verify the actor token: a projected service account
# token, signed by the cluster.
#
# EVERY ENDPOINT IS EXPLICIT, AND THREE ARE PLACEHOLDERS. EKS publishes a discovery document with
# jwks_uri and nothing a sign-in needs: no token or userinfo endpoint, and an authorization_endpoint
# that is a URN. Given only the issuer, Cognito refuses every exchange with a bare invalid_request.
# Only jwks_uri is ever used. The other three point at paths EKS does not serve, so a browser sign-in
# through this provider cannot work -- which is right: no person signs in as a workload.
#
# client_id IS THE AUDIENCE AN ACTOR TOKEN MUST NAME. var.actor_audience is the gateway's own
# audience, so the actor is the token the agent already presents to the gateway and no second token
# is minted. A token for any other audience is refused.
resource "aws_cognito_identity_provider" "agents" {
  user_pool_id  = var.user_pool_id
  provider_name = local.actor_provider_name
  provider_type = "OIDC"

  provider_details = {
    client_id                     = var.actor_audience
    oidc_issuer                   = var.actor_issuer
    jwks_uri                      = "${var.actor_issuer}/keys"
    authorize_url                 = "${var.actor_issuer}/authorize"
    token_url                     = "${var.actor_issuer}/token"
    attributes_url                = "${var.actor_issuer}/userinfo"
    authorize_scopes              = "openid"
    attributes_request_method     = "GET"
    attributes_url_add_attributes = "false"
  }

  attribute_mapping = {
    username = "sub"
  }

}

# The client the gateway authenticates as when it asks for a delegated token. Confidential: only
# the gateway holds the secret, so only the gateway can exchange.
#
# DELEGATION ONLY. ALLOW_TOKEN_EXCHANGE_IMPERSONATION would let the holder of this secret turn a
# person's token into one with no actor at all, which is the property this exists to add.
#
# awscc, NOT aws, FOR THIS ONE RESOURCE. hashicorp/aws, under the `~> 6.73` pin, validates explicit_auth_flows against
# a list that predates token exchange and refuses ALLOW_TOKEN_EXCHANGE_DELEGATION at plan time. The
# Cloud Control provider passes it through. Move it to aws_cognito_user_pool_client when that list
# catches up.
resource "awscc_cognito_user_pool_client" "exchanger" {
  client_name     = "${var.name}-token-exchange"
  user_pool_id    = var.user_pool_id
  generate_secret = true

  explicit_auth_flows = ["ALLOW_TOKEN_EXCHANGE_DELEGATION", "ALLOW_REFRESH_TOKEN_AUTH"]
  # COGNITO for the subject, the person (a pool user); eks-agents for the actor.
  supported_identity_providers = ["COGNITO", aws_cognito_identity_provider.agents.provider_name]

  # THE CLIENT MUST HOLD AN OAUTH SCOPE, though the exchange names none. With no allowed scope the
  # pool refuses the exchange (invalid_grant), and a request that names a scope is refused too
  # (invalid_request). Cognito lets a client hold scopes only with an OAuth flow, so it
  # has the code flow, with a callback the load balancer does not route; the actor provider has no
  # working sign-in, so the flow cannot complete.
  allowed_o_auth_flows_user_pool_client = true
  allowed_o_auth_flows                  = ["code"]
  allowed_o_auth_scopes                 = ["${aws_cognito_resource_server.tools.identifier}/person"]
  callback_ur_ls                        = [var.exchanger_callback_url]

  # Short, because the tool accepts this token until it expires.
  access_token_validity = var.token_validity_minutes
  id_token_validity     = var.token_validity_minutes
  token_validity_units = {
    access_token = "minutes"
    id_token     = "minutes"
  }
  prevent_user_existence_errors = "ENABLED"
}

# The exchanger's secret, for the platform-secrets syncer to project into the gateway's namespace.
# Terraform holds it already (it is in state with the client); this is where the cluster reads it.
resource "aws_secretsmanager_secret" "exchanger" {
  name                    = "${var.name}/person-access/token-exchange"
  description             = "The client the egress gateway exchanges a person's and an agent's token with (RFC 8693). Written by terraform/modules/person-access."
  recovery_window_in_days = var.secret_recovery_window_days
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "exchanger" {
  secret_id     = aws_secretsmanager_secret.exchanger.id
  secret_string = jsonencode({ clientSecret = awscc_cognito_user_pool_client.exchanger.client_secret })
}

# Only the reader that projects it, the administrators, and whoever applies this: Terraform writes
# the value and reads it back.
data "aws_caller_identity" "current" {}

data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

data "aws_iam_policy_document" "exchanger_secret" {
  statement {
    sid       = "OnlyTheProjectingReader"
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
      values   = distinct(concat(var.secret_reader_arns, [data.aws_iam_session_context.current.issuer_arn]))
    }
  }
}

resource "aws_secretsmanager_secret_policy" "exchanger" {
  secret_arn = aws_secretsmanager_secret.exchanger.arn
  policy     = data.aws_iam_policy_document.exchanger_secret.json
}
