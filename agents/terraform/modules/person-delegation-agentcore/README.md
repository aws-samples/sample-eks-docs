# person-delegation-agentcore

The AWS services path's delegated token for a person's tools (`person_access_delegated_token`), from AgentCore Identity's on-behalf-of token exchange. The agent never sends a tool the person's own token. It sends one token that the pool signs, naming both the person and the agent.

## How a delegated token is made

1. The agent calls `GetWorkloadAccessTokenForJWT` with its workload identity and the person's access token.
2. The agent calls `GetResourceOauth2Token` with `oauth2Flow` `ON_BEHALF_OF_TOKEN_EXCHANGE` on its own credential provider. AgentCore runs the RFC 8693 exchange at the pool. The subject is the person's access token, and the actor is the agent's client-credentials token.
3. Cognito returns a token with `sub` the person, `aud` the tools, and `act` naming the agent's own client.

The agent's request sets `audiences` to the tools, overrides the subject token type to `urn:ietf:params:oauth:token-type:access_token`, and names one blank scope. Without the audience the token has no `aud`. Cognito refuses AgentCore's default subject token type, and it refuses any scope named in an exchange, while AgentCore requires at least one.

## What it creates

| Resource | Per |
|---|---|
| A resource server whose identifier is the tools' audience, with a `person` scope | Stack |
| A Cognito client with client credentials and `ALLOW_TOKEN_EXCHANGE_DELEGATION`, and its managed login style | Agent |
| An AgentCore OAuth2 credential provider (`CustomOauth2`, `TOKEN_EXCHANGE`, actor `M2M`) | Agent |
| An AgentCore workload identity | Agent |

The pool's domain must serve managed login. Cognito refuses an exchange on a domain that serves the classic UI (`token_exchange_requires_managed_login`); the ingress module's `managed_login` turns it on.

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `name`, `tags` | | Naming and tags. |
| `user_pool_id`, `issuer` | | The ingress pool and its issuer URL. |
| `tool_audience` | | The audience a tool requires. |
| `agents` | | `person_access_agents`. |
| `token_validity_minutes` | `15` | A delegated token's lifetime. |

## Outputs

`tool_audience`, `actor_clients` (client id to agent subject, for the tool), `provider_name_prefix`, and `agents` (each agent's provider and workload identity).
