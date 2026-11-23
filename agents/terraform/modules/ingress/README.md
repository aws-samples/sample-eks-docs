# ingress

What the agents' authenticated ingress needs before the load balancer exists: a private DNS zone, a certificate, a sign-in provider, and the DNS reconciler's identity. Both roots call it when `enable_ingress` is on. The load balancer itself is a Gateway in the platform chart, created by the EKS Auto Mode load balancer controller when the chart syncs. [Ingress](https://docs.aws.amazon.com/eks/latest/userguide/agents-ingress.html) covers the design.

## What it creates

| Resource | Notes |
|---|---|
| `aws_route53_zone.agents` | A private zone for `domain_name`, attached to `vpc_id`. Created empty: the DNS reconciler writes the records once the Gateway has an address. |
| Certificate | One of three: `certificate_arn` if you name one; a self-signed certificate imported into ACM with `self_signed_certificate`; otherwise an ACM wildcard certificate for `*.<domain_name>` and the apex, validated in `public_zone_id`. |
| Cognito user pool, domain, and app client | Always created. Admin-created users only. The client's callbacks are `https://<host>/oauth2/idpresponse` for each of `cognito_callback_hosts`. |
| `aws_cognito_identity_provider.oidc` | With `federated_oidc`: your OIDC provider, federated into the pool and the only provider the client offers. |
| DNS reconciler role and Pod Identity association | With `dns_reconciler` (default `true`), for `external-dns`/`external-dns`, scoped to the agent zone. |

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `name`, `vpc_id`, `cluster_name`, `cluster_arn` | | |
| `domain_name` | | The suffix agents are reached at, such as `agents.example.com`. |
| `certificate_arn`, `public_zone_id`, `self_signed_certificate` | `""`, `""`, `false` | How the listener gets a certificate. `public_zone_id` must be a publicly delegated zone. |
| `self_signed_validity_hours` | `2160` | |
| `federated_oidc` | `null` | An OIDC provider behind the Cognito pool (root `ingress_idp = "oidc"`). Every endpoint is required. |
| `direct_oidc` | `null` | An OIDC provider the load balancer calls itself (root `ingress_idp = "oidc-direct"`). Set this or `federated_oidc`, not both. |
| `cognito_callback_hosts` | `[]` | Every exposed hostname. The roots derive it from `ingress_domain_name`, `agents`, `ingress_hostnames`, and `enable_chat_ui`. |
| `dns_reconciler`, `dns_reconciler_namespace`, `dns_reconciler_service_account` | `true`, `"external-dns"`, `"external-dns"` | |

## Outputs

`certificate_arn`, `certificate_pem`, `domain_name`, `agent_zone_id`, `agent_zone_arn`, `cognito` (null with `direct_oidc`), `oidc`, `cognito_user_pool_id`, `cognito_client_secret` (sensitive), `idp_redirect_uris`, `dns_reconciler_role_arn`, `dns_reconciler_namespace`, `dns_reconciler_service_account`.

## Constraints

* A hostname missing from `cognito_callback_hosts` fails in the browser after a successful sign-in, not at the load balancer.
* With `direct_oidc`, this module doesn't read the client secret. [`platform-secrets`](../platform-secrets) syncs it into the ingress namespace for the listener rule.
* The federated client secret, the Cognito client secret, and a self-signed private key are all stored in Terraform state.
* Nothing trusts a self-signed certificate by default. Give clients `certificate_pem`, and use a delegated zone for anything a person signs in to.
