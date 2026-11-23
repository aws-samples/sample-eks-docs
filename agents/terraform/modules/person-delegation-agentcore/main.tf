# ONE TOKEN THAT NAMES THE PERSON AND THE AGENT, from AgentCore Identity (person_access_delegated_token
# on the AWS services path). Used with terraform/modules/person-access, on the same pool.
#
# The agent never sends a tool the person's own token. It asks AgentCore Identity for an
# on-behalf-of token: GetWorkloadAccessTokenForJWT with the person's access token and the agent's
# workload identity, then GetResourceOauth2Token with oauth2Flow ON_BEHALF_OF_TOKEN_EXCHANGE on this
# agent's credential provider. AgentCore holds the client secret and runs the RFC 8693 exchange at
# the pool, with the person's access token as the subject and the agent's own client-credentials
# token as the actor. Cognito returns one token, signed by the pool, with
#
#   sub   the person
#   aud   var.tool_audience, so it is useless at any other relying party
#   act   {sub: this agent's Cognito client id, client_id, iss: the pool}
#
# The actor is a Cognito client of its own per agent, so the tool can tell which agent is acting:
# it maps act.sub to the agent and refuses a token whose actor isn't the agent that called it.
# The agent's role may read only its own workload identity and its own provider, so one agent can't
# obtain a token naming another as the actor.
#
# Three request details the agent sends because Cognito requires them, and the tool relies on:
# `audiences` set to var.tool_audience (without it the token has no aud), the subject token type
# set to access_token (AgentCore's default, jwt, is refused), and one blank scope (AgentCore needs
# at least one, and Cognito refuses any scope named in an exchange).

locals {
  agents = { for a in var.agents : element(split("/", a), length(split("/", a)) - 1) => {
    namespace = length(split("/", a)) == 2 ? split("/", a)[0] : "agents"
    subject   = format("system:serviceaccount:%s:%s", length(split("/", a)) == 2 ? split("/", a)[0] : "agents", element(split("/", a), length(split("/", a)) - 1))
  } }
  scope = "${aws_cognito_resource_server.tools.identifier}/person"
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

# Each agent's client. Client credentials only, which is how AgentCore mints the actor token, and
# delegation only: ALLOW_TOKEN_EXCHANGE_IMPERSONATION would let the holder turn a person's token
# into one with no actor at all.
resource "awscc_cognito_user_pool_client" "agent" {
  for_each = local.agents

  client_name     = "${var.name}-${each.key}-on-behalf-of"
  user_pool_id    = var.user_pool_id
  generate_secret = true

  explicit_auth_flows                   = ["ALLOW_TOKEN_EXCHANGE_DELEGATION", "ALLOW_REFRESH_TOKEN_AUTH"]
  allowed_o_auth_flows_user_pool_client = true
  allowed_o_auth_flows                  = ["client_credentials"]
  allowed_o_auth_scopes                 = [local.scope]
  supported_identity_providers          = ["COGNITO"]

  access_token_validity = var.token_validity_minutes
  id_token_validity     = var.token_validity_minutes
  token_validity_units = {
    access_token = "minutes"
    id_token     = "minutes"
  }
  prevent_user_existence_errors = "ENABLED"
}

# Managed login serves the exchange only for a client with a style; Cognito's default one.
resource "aws_cognito_managed_login_branding" "agent" {
  for_each = local.agents

  user_pool_id                = var.user_pool_id
  client_id                   = awscc_cognito_user_pool_client.agent[each.key].client_id
  use_cognito_provided_values = true
}

# The agent's credential provider. AgentCore stores the client secret in its token vault, so the
# agent never holds it.
resource "aws_bedrockagentcore_oauth2_credential_provider" "agent" {
  for_each = local.agents

  name                       = "${var.name}-${each.key}-on-behalf-of"
  credential_provider_vendor = "CustomOauth2"

  oauth2_provider_config {
    custom_oauth2_provider_config {
      client_id                    = awscc_cognito_user_pool_client.agent[each.key].client_id
      client_secret                = awscc_cognito_user_pool_client.agent[each.key].client_secret
      client_authentication_method = "CLIENT_SECRET_BASIC"

      oauth_discovery {
        discovery_url = "${var.issuer}/.well-known/openid-configuration"
      }

      on_behalf_of_token_exchange_config {
        grant_type = "TOKEN_EXCHANGE"
        token_exchange_grant_type_config {
          actor_token_content = "M2M"
          actor_token_scopes  = [local.scope]
        }
      }
    }
  }

  tags = var.tags

  depends_on = [aws_cognito_managed_login_branding.agent]
}

# The agent's workload identity, which GetWorkloadAccessTokenForJWT binds to the person's token.
resource "aws_bedrockagentcore_workload_identity" "agent" {
  for_each = local.agents

  name = "${var.name}-${each.key}"
  tags = var.tags
}
