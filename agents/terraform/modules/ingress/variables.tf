variable "name" {
  description = "Name prefix, normally the cluster name."
  type        = string
}

variable "vpc_id" {
  description = "The cluster's VPC. With an internal load balancer the private hosted zone is associated with it, so the agents' names resolve from inside and nowhere else."
  type        = string
}

variable "domain_name" {
  description = "The DNS suffix agents are reached at, e.g. `agents.example.com`. An agent's route claims `<agent>.<this>`."
  type        = string
}

variable "certificate_arn" {
  description = "An existing ACM certificate covering `*.<domain_name>`. Empty requests one, which needs `public_zone_id`. An ALB serves only ACM certificates, so an externally-issued or self-signed certificate has to be imported into ACM first."
  type        = string
  default     = ""
}

variable "public_zone_id" {
  description = "A publicly delegated Route 53 zone covering `domain_name`: answers ACM's DNS validation challenge, and with scheme = internet-facing holds the NS delegation to the agents' public zone. A zone that exists but is not delegated leaves validation pending forever."
  type        = string
  default     = ""
}

variable "scheme" {
  description = "`internal` (the default) or `internet-facing`. Internet-facing makes the agents' zone public, delegated from public_zone_id, and creates the load balancer's security group from allowed_cidrs."
  type        = string
  default     = "internal"

  validation {
    condition     = contains(["internal", "internet-facing"], var.scheme)
    error_message = "scheme must be internal or internet-facing."
  }
}

variable "allowed_cidrs" {
  description = "Source CIDRs an internet-facing load balancer admits on 443. Required with scheme = internet-facing; 0.0.0.0/0 is refused. Ignored when internal."
  type        = list(string)
  default     = []
}

variable "federated_oidc" {
  description = <<-EOT
    An existing OpenID Connect provider -- Okta, Entra ID, Auth0, Keycloak -- to federate into the
    user pool, so a person signs in with it rather than with a Cognito password. Null keeps the
    pool's own users.

    The load balancer runs `authenticate-cognito` and the provider is reached THROUGH the pool, so
    the agent receives Cognito's claims and tokens; `direct_oidc` is the alternative that calls the
    provider itself. The app client offers only this provider, and the listener rule passes
    `identity_provider` so the hosted UI redirects straight to it.

    Every endpoint is required, not discovered. Cognito fills in any endpoint left out from the
    issuer's discovery document and returns it on read, so a partial map would show a change on
    every plan.

    `client_secret_arn` names a Secrets Manager secret whose SecretString is the client secret. It
    is read at plan time and IS stored in Terraform state, because Cognito's provider_details is not
    a write-only argument.
  EOT
  type = object({
    name                   = optional(string, "oidc")
    issuer                 = string
    authorization_endpoint = string
    token_endpoint         = string
    user_info_endpoint     = string
    jwks_uri               = string
    client_id              = string
    client_secret_arn      = string
    scopes                 = optional(list(string), ["openid", "email", "profile"])
  })
  default = null

  validation {
    # try(): Terraform before 1.12 evaluates both sides of ||, so a bare attribute read on a null
    # object fails the validation instead of passing it.
    condition     = var.federated_oidc == null || can(regex("^[^_\\s][^\\s]{0,30}[^_\\s]$", try(var.federated_oidc.name, "")))
    error_message = "federated_oidc.name must be 2-32 characters, with no whitespace and no leading or trailing underscore: it becomes the Cognito provider name and the identity_provider the load balancer passes."
  }

  validation {
    condition = var.federated_oidc == null || alltrue([
      for k in ["issuer", "authorization_endpoint", "token_endpoint", "user_info_endpoint", "jwks_uri"] :
      startswith(try(var.federated_oidc[k], "https://"), "https://")
    ])
    error_message = "Every federated_oidc endpoint and the issuer must be an https:// URL. Cognito refuses anything else, and the refusal arrives at apply rather than at plan."
  }
}

variable "direct_oidc" {
  description = <<-EOT
    An OIDC provider for the load balancer to call directly with `authenticate-oidc`, with no
    Cognito pool in the person's path: ingress_idp = "oidc-direct". The agent then receives the
    provider's own claims and access token rather than Cognito's.

    When set, the `oidc` output carries these values and the `cognito` output is null, so the chart
    renders `authenticate-oidc`. The pool is still created -- the module always makes one -- but the
    load balancer does not use it.

    `client_secret_arn` is not read here. terraform/modules/platform-secrets reads it into the
    secret gitops/charts/platform-secrets syncs into the ingress namespace, where the listener
    rule reads it -- under the eks:managed grant in gitops/base/templates/47-ingress-oidc.yaml.
  EOT
  type = object({
    issuer                 = string
    authorization_endpoint = string
    token_endpoint         = string
    user_info_endpoint     = string
    client_id              = string
    client_secret_arn      = string
  })
  default = null

  validation {
    condition     = var.direct_oidc == null || var.federated_oidc == null
    error_message = "Set direct_oidc or federated_oidc, not both. federated_oidc puts the provider behind the Cognito pool; direct_oidc has the load balancer call it with no pool in the path."
  }
}

variable "cognito_callback_hosts" {
  description = <<-EOT
    Hostnames whose `/oauth2/idpresponse` is registered as a callback on the Cognito app client,
    normally one per agent that is exposed.

    EVERY EXPOSED HOSTNAME NEEDS TO BE HERE. Cognito refuses a callback it was not told about, and
    the error arrives at the browser after a successful login rather than at the load balancer, so
    it reads as the agent being broken rather than the client being short a URL.
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "cluster_name" {
  description = "The cluster the DNS reconciler's Pod Identity association is made against."
  type        = string
  default     = ""
}

variable "cluster_arn" {
  description = "The cluster's ARN. The Pod Identity trust policy is restricted to it with aws:SourceArn."
  type        = string
}

variable "dns_reconciler" {
  description = <<-EOT
    Create the IAM role and Pod Identity association for the controller that writes the agents'
    DNS records.

    SOMETHING HAS TO, and it cannot be Terraform: the record is an alias to a load balancer that
    does not exist until the platform chart syncs and the Gateway programs, which is after `apply`
    has returned. A one-off record written by hand then goes stale the first time the Gateway is
    recreated and the failure is a name resolving to a load balancer that was deleted.

    The role is scoped to the one private zone this module made, so the controller cannot touch any
    other zone in the account.
  EOT
  type        = bool
  default     = true
}

variable "dns_reconciler_namespace" {
  description = "Namespace the DNS reconciler runs in."
  type        = string
  default     = "external-dns"
}

variable "dns_reconciler_service_account" {
  description = "Service account the DNS reconciler runs as."
  type        = string
  default     = "external-dns"
}

variable "self_signed_certificate" {
  description = <<-EOT
    Generate a certificate here and import it into ACM, instead of requesting one from ACM or being
    given an ARN.

    FOR A PRIVATE INGRESS WITHOUT A PUBLICLY DELEGATED ZONE, AND NOTHING ELSE. ACM can only
    issue against a domain whose DNS it can reach, and an ALB serves only certificates that are in
    ACM -- so a cluster whose agents live under a name like `agents.internal.example` has no third
    option. This closes that gap without a manual `openssl` and `aws acm import-certificate`, which
    is what the alternative actually was.

    What it costs: nothing trusts it by default. A browser shows a warning; a client has to be given
    `certificate_pem` as a CA. That is correct for an internal ingress exercised by a test or by
    a workload gate, and wrong for anything a person is asked to log into for real -- for that,
    delegate a zone and let ACM issue.

    The private key is generated by Terraform and therefore lives in state. One more reason this is
    not the production path.
  EOT
  type        = bool
  default     = false

  validation {
    condition     = !(var.self_signed_certificate && var.certificate_arn != "")
    error_message = "self_signed_certificate and certificate_arn are alternatives: one generates a certificate, the other names one that already exists."
  }
}

variable "self_signed_validity_hours" {
  description = "How long the generated certificate is valid. Short by default, because a certificate nothing can revoke should expire on its own; re-apply to roll it."
  type        = number
  default     = 2160 # 90 days
}

variable "managed_login" {
  description = <<-EOT
    Serve the pool's sign-in pages with managed login (domain version 2) instead of the classic
    hosted UI, on the Essentials tier, with Cognito's default style on the load balancer's client.
    Cognito's token exchange requires it; the root turns it on with
    person_access_delegated_token. A person sees a different sign-in page; nothing else changes.
  EOT
  type        = bool
  default     = false
}
