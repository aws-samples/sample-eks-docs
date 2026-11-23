################################################################################
# The agents' ingress: the name, the certificate and the identity provider.
#
# The load balancer itself is NOT here. It is a Gateway in the platform chart, created by the EKS
# Auto Mode ALB controller when the chart syncs, so it does not exist at apply time. This module
# makes the three things that have to exist BEFORE it does, and hands them to the chart.
#
# Which also means the alias record cannot live here: there is nothing to alias to until the Gateway
# programs. The zone is created empty on purpose -- see the `agent_zone_id` output.
################################################################################

locals {
  internet_facing = var.scheme == "internet-facing"

  # Three ways the listener gets a certificate, in precedence order: one you named, one generated
  # and imported here, or one ACM issues against a publicly delegated zone.
  request_cert = var.certificate_arn == "" && !var.self_signed_certificate

  certificate_arn = (var.certificate_arn != "" ? var.certificate_arn :
    var.self_signed_certificate ? aws_acm_certificate.self_signed[0].arn :
  try(aws_acm_certificate_validation.this[0].certificate_arn, ""))
}

# ---------------------------------------------------------------------------
# The name, resolvable inside the VPC and nowhere else
# ---------------------------------------------------------------------------

# A PRIVATE zone for an internal load balancer, even when the certificate is publicly trusted. A
# public record in front of an internal load balancer tells anyone asking that an endpoint exists and
# where it is, and resolves to an address they cannot reach -- all of the disclosure and none of the
# use.
#
# A PUBLIC zone for an internet-facing one, delegated from public_zone_id below, because the callers
# it exists for -- a workstation in the allowlist -- resolve through public DNS. Switching scheme
# replaces the zone; ExternalDNS rewrites its records into the new one on its next pass.
resource "aws_route53_zone" "agents" {
  name    = var.domain_name
  comment = local.internet_facing ? "${var.name} agent ingress. Public, for an internet-facing load balancer behind an allowlist." : "${var.name} agent ingress. Private: resolves in the cluster VPC only."

  dynamic "vpc" {
    for_each = local.internet_facing ? [] : [var.vpc_id]
    content {
      vpc_id = vpc.value
    }
  }

  # The zone outlives individual Gateways, and the records in it are written by whatever reconciles
  # the load balancer's address. Destroying it with records present is intentional here because the
  # records are derived, not authored.
  force_destroy = true

  tags = var.tags
}

# A SHORT NEGATIVE-CACHING TTL. Route 53 gives a new zone an SOA minimum of 86400 and an SOA TTL of
# 900, so a resolver caches "no such name" for 900 s. Any lookup of a route's host before ExternalDNS
# has written its record -- the sign-in check right after the sync that adds the chat UI, or a reader's
# own probe -- then keeps failing for minutes after the record exists. A shorter SOA TTL and
# minimum shorten that wait. Only those two change; the rest of the record is Route 53's own.
# Nothing to undo on destroy: the SOA goes with the zone.
resource "terraform_data" "negative_ttl" {
  triggers_replace = { zone_id = aws_route53_zone.agents.zone_id, ttl = 60 }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      ZONE_ID = self.triggers_replace.zone_id
      TTL     = tostring(self.triggers_replace.ttl)
    }
    command = <<-EOT
      set -euo pipefail
      soa="$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
        --query "ResourceRecordSets[?Type=='SOA'] | [0]" --output json)"
      batch="$(SOA="$soa" python3 -c '
      import json, os
      r = json.loads(os.environ["SOA"]); v = r["ResourceRecords"][0]["Value"].split()
      v[-1] = os.environ["TTL"]
      print(json.dumps({"Changes": [{"Action": "UPSERT", "ResourceRecordSet": {
          "Name": r["Name"], "Type": "SOA", "TTL": int(os.environ["TTL"]),
          "ResourceRecords": [{"Value": " ".join(v)}]}}]}))')"
      aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch "$batch" >/dev/null
    EOT
  }
}

# The delegation that makes the public agent zone answer: its name servers, in the parent zone.
data "aws_route53_zone" "public" {
  count   = local.internet_facing ? 1 : 0
  zone_id = var.public_zone_id
}

resource "aws_route53_record" "delegation" {
  count = local.internet_facing ? 1 : 0

  zone_id = var.public_zone_id
  name    = var.domain_name
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.agents.name_servers

  lifecycle {
    precondition {
      condition     = trimsuffix(lower(var.domain_name), ".") != trimsuffix(lower(data.aws_route53_zone.public[0].name), ".")
      error_message = "An internet-facing ingress needs domain_name to be a subdomain of public_zone_id's zone (e.g. agents.example.com under example.com), so the agents' zone can be delegated from it."
    }
    precondition {
      condition     = endswith(trimsuffix(lower(var.domain_name), "."), ".${trimsuffix(lower(data.aws_route53_zone.public[0].name), ".")}")
      error_message = "domain_name is not under public_zone_id's zone, so a delegation there would answer for nobody."
    }
  }
}

# ---------------------------------------------------------------------------
# Who may reach an internet-facing load balancer
# ---------------------------------------------------------------------------

# The load balancer's own security group, owned here rather than by the controller, so that moving
# the allowlist (a workstation whose address changed) is one `terraform apply` and no GitOps sync.
# HTTPS from the named CIDRs only; the chart hands this group to the LoadBalancerConfiguration with
# manageBackendSecurityGroupRules, so the controller still opens the targets to it.
data "aws_vpc" "this" {
  count = local.internet_facing ? 1 : 0
  id    = var.vpc_id
}

resource "aws_security_group" "load_balancer" {
  count = local.internet_facing ? 1 : 0

  name_prefix = "${var.name}-ingress-"
  description = "${var.name} internet-facing agent ingress: HTTPS from the allowlist only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${var.name}-ingress" })

  lifecycle {
    create_before_destroy = true
    precondition {
      condition     = length(var.allowed_cidrs) > 0 && !contains(var.allowed_cidrs, "0.0.0.0/0")
      error_message = "An internet-facing ingress needs allowed_cidrs: the source CIDRs that may reach it. 0.0.0.0/0 is refused."
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  for_each = local.internet_facing ? toset(var.allowed_cidrs) : toset([])

  security_group_id = aws_security_group.load_balancer[0].id
  description       = "HTTPS from an allowlisted caller"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# To the targets (pod IPs) and their health checks, inside the VPC only.
resource "aws_vpc_security_group_egress_rule" "targets" {
  count = local.internet_facing ? 1 : 0

  security_group_id = aws_security_group.load_balancer[0].id
  description       = "To agent targets in the VPC"
  cidr_ipv4         = data.aws_vpc.this[0].cidr_block
  ip_protocol       = "tcp"
  from_port         = 0
  to_port           = 65535
}

# ---------------------------------------------------------------------------
# The certificate
# ---------------------------------------------------------------------------

# Wildcard, so one certificate covers every agent's hostname and onboarding an agent is a route
# rather than a certificate request. The apex is included because a route may claim it.
resource "aws_acm_certificate" "this" {
  count = local.request_cert ? 1 : 0

  domain_name               = "*.${var.domain_name}"
  subject_alternative_names = [var.domain_name]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = var.tags
}

# The validation records go in the PUBLIC zone. ACM resolves them from the internet, so the private
# zone above cannot answer the challenge -- which is the whole reason this module takes two zones.
resource "aws_route53_record" "validation" {
  for_each = local.request_cert ? {
    for o in aws_acm_certificate.this[0].domain_validation_options : o.domain_name => o
  } : {}

  zone_id = var.public_zone_id
  name    = each.value.resource_record_name
  type    = each.value.resource_record_type
  records = [each.value.resource_record_value]
  ttl     = 60

  allow_overwrite = true
}

# Blocks the apply until the certificate is ISSUED, which matters because a Gateway pointed at a
# PENDING_VALIDATION certificate programs no listener and reports a routing problem.
resource "aws_acm_certificate_validation" "this" {
  count = local.request_cert ? 1 : 0

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]

  timeouts {
    create = "30m"
  }
}

# ---------------------------------------------------------------------------
# The identity provider: always a Cognito user pool
#
# Always created. The listener rule authenticates against it with authenticate-cognito, and an
# existing OIDC provider is federated into it (federated_oidc). With direct_oidc the pool still
# exists, but the listener rule calls that provider with authenticate-oidc instead.
# ---------------------------------------------------------------------------

resource "aws_cognito_user_pool" "this" {
  name = "${var.name}-ingress"

  # Ingress authenticates people who already exist. Self-service signup would let anyone who
  # can reach the load balancer create an identity that satisfies the gate, which is the gate
  # removed rather than configured.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # Pinned only when managed login is on (var.managed_login), because token exchange needs this tier.
  # Left unset otherwise, so an existing pool on another tier is not changed by this module.
  user_pool_tier = var.managed_login ? "ESSENTIALS" : null

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 1
  }

  tags = var.tags
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = "${var.name}-ingress"
  user_pool_id = aws_cognito_user_pool.this.id

  # 2 is managed login, 1 the classic hosted UI. Cognito's token exchange (RFC 8693) refuses a pool
  # whose domain serves the classic UI ("token_exchange_requires_managed_login"), so
  # var.managed_login turns this on for the delegated token (person_access_delegated_token).
  #
  # 1, NOT null, WITH IT OFF. Null leaves the domain as it is, so turning the option off would keep
  # managed login while deleting the load balancer client's style below -- and managed login serves
  # no page for a client without one, so nobody could sign in. 1 is
  # every domain's state until something sets 2, so a domain that never had managed login is
  # unchanged.
  managed_login_version = var.managed_login ? 2 : 1
}

# MANAGED LOGIN SERVES NO PAGE FOR A CLIENT WITHOUT A STYLE. Each client a person signs in through
# needs one; this is Cognito's default look, assigned to the load balancer's client.
resource "aws_cognito_managed_login_branding" "alb" {
  count = var.managed_login ? 1 : 0

  user_pool_id                = aws_cognito_user_pool.this.id
  client_id                   = aws_cognito_user_pool_client.this.id
  use_cognito_provided_values = true
}

# An existing OIDC provider, federated into the pool. The pool is still what the load balancer
# authenticates against; this is where the person actually signs in.
data "aws_secretsmanager_secret_version" "federated_oidc" {
  count = var.federated_oidc != null ? 1 : 0

  secret_id = var.federated_oidc.client_secret_arn
}

resource "aws_cognito_identity_provider" "oidc" {
  count = var.federated_oidc != null ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.this.id
  provider_name = var.federated_oidc.name
  provider_type = "OIDC"

  # Every key Cognito returns on read is set here. Leave an endpoint out and Cognito fills it from
  # the issuer's discovery document, the provider reads it back, and every plan shows a change.
  provider_details = {
    client_id                     = var.federated_oidc.client_id
    client_secret                 = data.aws_secretsmanager_secret_version.federated_oidc[0].secret_string
    oidc_issuer                   = var.federated_oidc.issuer
    authorize_url                 = var.federated_oidc.authorization_endpoint
    token_url                     = var.federated_oidc.token_endpoint
    attributes_url                = var.federated_oidc.user_info_endpoint
    jwks_uri                      = var.federated_oidc.jwks_uri
    authorize_scopes              = join(" ", var.federated_oidc.scopes)
    attributes_request_method     = "GET"
    attributes_url_add_attributes = "false"
  }

  # `sub` is the provider's stable identifier for the person; email is what a person reads.
  attribute_mapping = {
    username = "sub"
    email    = "email"
  }
}

resource "aws_cognito_user_pool_client" "this" {
  name         = "${var.name}-alb"
  user_pool_id = aws_cognito_user_pool.this.id

  # The load balancer runs the authorization code flow and holds the secret, so this is a
  # confidential client. A public client here would mean the code could be exchanged by anyone who
  # intercepted it.
  generate_secret = true

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  # The pool's own users, or ONLY the federated provider. Not both: offering COGNITO beside it would
  # leave a password login next to the provider the operator chose, and an admin-created pool user
  # would bypass that provider's own sign-in policy.
  #
  # A federated person is created in the pool on first sign-in whatever allow_admin_create_user_only
  # says, so WHO may sign in is decided by the provider's assignment to this client, not here.
  supported_identity_providers = var.federated_oidc != null ? [aws_cognito_identity_provider.oidc[0].provider_name] : ["COGNITO"]

  # The ALB's own callback path, one per exposed hostname. Cognito refuses a redirect_uri it was not
  # given, and the refusal surfaces in the browser after a successful login.
  callback_urls = [for h in var.cognito_callback_hosts : "https://${h}/oauth2/idpresponse"]
  logout_urls   = [for h in var.cognito_callback_hosts : "https://${h}"]
}

# ---------------------------------------------------------------------------
# The DNS reconciler's identity
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "dns_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    # Restricted to this cluster, as every other Pod Identity role in this stack is. Without it the
    # role could be delivered to a service account of the same name on any cluster in the account.
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.cluster_arn]
    }
  }
}

data "aws_iam_policy_document" "dns" {
  # Writes, scoped to THIS ZONE. The controller reconciles the agents' names and must not be able to
  # change any other zone in the account -- including the public zone that answered the certificate
  # challenge.
  statement {
    sid       = "ChangeRecordsInTheAgentZone"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [aws_route53_zone.agents.arn]
  }

  # Reads cannot be resource-scoped: ListHostedZones is a list call over the account, and the
  # controller needs it to find the zone by name. ListResourceRecordSets is scoped, and
  # GetChange names a change id rather than a zone.
  statement {
    sid       = "FindTheZone"
    effect    = "Allow"
    actions   = ["route53:ListHostedZones", "route53:ListHostedZonesByName"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadChangeStatus"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:${data.aws_partition.current.partition}:route53:::change/*"]
  }

  statement {
    sid       = "ReadTheAgentZone"
    effect    = "Allow"
    actions   = ["route53:ListResourceRecordSets"]
    resources = [aws_route53_zone.agents.arn]
  }
}

resource "aws_iam_role" "dns" {
  count = var.dns_reconciler ? 1 : 0

  name               = "${var.name}-ingress-dns"
  assume_role_policy = data.aws_iam_policy_document.dns_trust.json
  description        = "Writes the agents' DNS records in ${var.domain_name} as their Gateway's address changes."

  tags = var.tags
}

resource "aws_iam_role_policy" "dns" {
  count = var.dns_reconciler ? 1 : 0

  name   = "route53"
  role   = aws_iam_role.dns[0].id
  policy = data.aws_iam_policy_document.dns.json
}

resource "aws_eks_pod_identity_association" "dns" {
  count = var.dns_reconciler && var.cluster_name != "" ? 1 : 0

  cluster_name    = var.cluster_name
  namespace       = var.dns_reconciler_namespace
  service_account = var.dns_reconciler_service_account
  role_arn        = aws_iam_role.dns[0].arn

  tags = var.tags
}

# ---------------------------------------------------------------------------
# The generated certificate, for ingress with no publicly delegated zone
# ---------------------------------------------------------------------------

# WHY THIS EXISTS. An ALB serves only certificates held in ACM, and ACM issues only for a domain
# whose DNS it can reach from the internet. A cluster whose agents live under a private name has
# neither -- and without this the gap is filled by hand, with `openssl req` and
# `aws acm import-certificate`. A manual step in the middle of ingress is a manual step in the
# middle of a security control, so it is here instead.
resource "tls_private_key" "self_signed" {
  count = var.self_signed_certificate ? 1 : 0

  algorithm = "RSA"
  # 2048, not 4096: an ALB accepts RSA 1024-4096 and the larger key buys nothing for a certificate
  # whose whole purpose is to exist.
  rsa_bits = 2048
}

resource "tls_self_signed_cert" "self_signed" {
  count = var.self_signed_certificate ? 1 : 0

  private_key_pem = tls_private_key.self_signed[0].private_key_pem

  subject {
    common_name  = "*.${var.domain_name}"
    organization = "${var.name} agent ingress (self-signed)"
  }

  # The wildcard AND the apex, matching what ACM would be asked for, so a route on either is
  # covered. A hostname outside this set produces a route that is Accepted and a handshake that
  # fails, which reads like DNS.
  dns_names = ["*.${var.domain_name}", var.domain_name]

  validity_period_hours = var.self_signed_validity_hours
  early_renewal_hours   = 72

  # server_auth alone. A certificate that could also sign other certificates is a CA, and nothing
  # here should be one.
  allowed_uses = ["digital_signature", "key_encipherment", "server_auth"]
}

resource "aws_acm_certificate" "self_signed" {
  count = var.self_signed_certificate ? 1 : 0

  private_key      = tls_private_key.self_signed[0].private_key_pem
  certificate_body = tls_self_signed_cert.self_signed[0].cert_pem

  # No certificate_chain: a self-signed certificate is its own root, and ACM accepts the pair.

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.name}-ingress-self-signed"
    # Says in the console what the description above says in code. NO COMMA: ACM validates tag
    # values against `([\p{L}\p{Z}\p{N}_.:/=+\-@]*)`, which excludes it, and the apply fails on
    # the tag rather than on the certificate -- "Value of the input at 'tags.1.member.value' failed
    # to satisfy constraint".
    "eks-agents/trust" = "self-signed-not-publicly-trusted"
  })
}
