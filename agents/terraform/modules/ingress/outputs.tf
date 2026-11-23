output "certificate_arn" {
  description = "The ACM certificate the HTTPS listener serves. Goes into ingress.certificateArn, which the base chart puts on the LoadBalancerConfiguration -- the only object the controller reads it from."
  value       = local.certificate_arn
}

output "domain_name" {
  description = "The DNS suffix an agent's route hostname is built from."
  value       = var.domain_name
}

output "agent_zone_id" {
  description = <<-EOT
    The agents' hosted zone -- private, or public with an internet-facing scheme -- created EMPTY.

    Nothing here can write the alias record, because the load balancer does not exist until the
    platform chart syncs and the Gateway programs. Whatever reconciles that address owns the record:
    a controller watching the Gateway, or one step after the first sync.
  EOT
  value       = aws_route53_zone.agents.zone_id
}

output "load_balancer_security_group_id" {
  description = "The internet-facing load balancer's security group (HTTPS from allowed_cidrs), for ingress.securityGroupIds. Empty when internal: the controller makes its own."
  value       = try(aws_security_group.load_balancer[0].id, "")
}

output "agent_zone_arn" {
  description = "The agents' zone's ARN, to scope the record-writing permission to this zone and no other."
  value       = aws_route53_zone.agents.arn
}

output "oidc" {
  description = "The provider's OIDC endpoints: direct_oidc's when set, which the chart's authenticate-oidc rule uses; otherwise the user pool's, for anything that verifies the claims it issues -- the load balancer then runs authenticate-cognito from the `cognito` output instead."
  value = var.direct_oidc != null ? var.direct_oidc : {
    issuer                 = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
    authorization_endpoint = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.region}.amazoncognito.com/oauth2/authorize"
    token_endpoint         = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.region}.amazoncognito.com/oauth2/token"
    user_info_endpoint     = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.region}.amazoncognito.com/oauth2/userInfo"
    client_id              = aws_cognito_user_pool_client.this.id
    client_secret_arn      = ""
  }
}

output "cognito_user_pool_id" {
  description = "The user pool. This is where a test user is created when ingress_idp is cognito."
  value       = aws_cognito_user_pool.this.id
}

output "cognito_client_secret" {
  description = "The app client's secret. Sensitive, and in Terraform state -- which is the cost of Cognito being created here rather than named."
  value       = aws_cognito_user_pool_client.this.client_secret
  sensitive   = true
}

output "dns_reconciler_role_arn" {
  description = "The role the DNS reconciler assumes, scoped to the agent zone alone."
  value       = try(aws_iam_role.dns[0].arn, "")
}

output "dns_reconciler_namespace" {
  description = "Namespace the DNS reconciler's Pod Identity association was made for. The controller has to run here, under the matching service account, or it gets no credential and the failure is silent -- an association is injected at pod admission, so a pod created before it existed runs with no identity at all."
  value       = var.dns_reconciler_namespace
}

output "dns_reconciler_service_account" {
  description = "Service account the association names."
  value       = var.dns_reconciler_service_account
}

output "idp_redirect_uris" {
  description = <<-EOT
    The redirect URIs to register with an external OIDC provider. Federated (ingress_idp =
    "oidc"): Cognito's own idpresponse endpoint on this pool's domain -- the provider hands the
    person back to the pool. Direct (ingress_idp = "oidc-direct"): the load balancer's
    /oauth2/idpresponse on every exposed hostname -- the provider hands the person back to the ALB.
    Empty with the pool's own users, where no external provider is involved.
  EOT
  value = var.direct_oidc != null ? [
    for h in var.cognito_callback_hosts : "https://${h}/oauth2/idpresponse"
    ] : var.federated_oidc != null ? [
    "https://${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.region}.amazoncognito.com/oauth2/idpresponse"
  ] : []
}

output "cognito" {
  description = <<-EOT
    The user pool as the `authenticate-cognito` action needs it: ARN, client id and domain PREFIX
    (not the full hostname).

    Null with direct_oidc: the load balancer then calls that provider with authenticate-oidc and
    does not use the pool. See the agents-ingress page of the EKS User Guide.
  EOT
  # Null with direct_oidc, so the chart has no Cognito action to prefer and renders authenticate-oidc.
  value = var.direct_oidc != null ? null : {
    userPoolArn      = aws_cognito_user_pool.this.arn
    userPoolClientId = aws_cognito_user_pool_client.this.id
    userPoolDomain   = aws_cognito_user_pool_domain.this.domain
    # The federated provider's name, passed by the listener rule as identity_provider so the hosted
    # UI redirects straight to it. Empty when the pool's own users sign in.
    identityProvider = try(aws_cognito_identity_provider.oidc[0].provider_name, "")
  }
}

output "certificate_pem" {
  description = <<-EOT
    The generated certificate, when this module made one, so a caller can trust it: pass it to curl
    as `--cacert`, or add it to a client's trust store. Empty otherwise.

    A self-signed certificate is its own root, so this one file is the whole chain.
  EOT
  value       = try(tls_self_signed_cert.self_signed[0].cert_pem, "")
}
