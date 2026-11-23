# Interface VPC endpoints, so traffic from the cluster to the AWS services it uses stays inside the
# VPC rather than crossing the NAT gateway to a public endpoint.
#
# Each endpoint has private DNS on, so the service's own hostname resolves to the endpoint's
# addresses inside the VPC and nothing in the cluster changes its configuration: the agents' network
# policy names the same hostnames, and the agents call the same URLs.

locals {
  # Key -> endpoint service. Grouped by who calls it; README.md lists which layer needs which.
  services = {
    # Agents
    agentcore-gateway = "com.amazonaws.${var.region}.bedrock-agentcore.gateway" # model and tool calls with enable_gateway
    bedrock-runtime   = "com.amazonaws.${var.region}.bedrock-runtime"           # model calls without a gateway
    agentcore         = "com.amazonaws.${var.region}.bedrock-agentcore"         # AgentCore Memory (enable_consolidation)
    s3vectors         = "com.amazonaws.${var.region}.s3vectors"                 # semantic recall (enable_semantic_recall)
    sts               = "com.amazonaws.${var.region}.sts"
    secretsmanager    = "com.amazonaws.${var.region}.secretsmanager"
    sqs               = "com.amazonaws.${var.region}.sqs" # task queues (enable_agent_tasks): the worker, KEDA and senders
    # Nodes: image pulls and Pod Identity credentials
    ecr-api  = "com.amazonaws.${var.region}.ecr.api"
    ecr-dkr  = "com.amazonaws.${var.region}.ecr.dkr"
    eks-auth = "com.amazonaws.${var.region}.eks-auth"
    # The cluster's OIDC issuer, oidc.eks.<region>.amazonaws.com: every check of a service account
    # token -- each agent's own, the MCP server's, the evaluation runner's target -- reads its
    # discovery document and keys there. With no route to the internet and no endpoint, every one
    # of them answers 401 ("cannot read OIDC discovery ... timed out").
    oidc-eks = "com.amazonaws.${var.region}.oidc-eks"
    # Telemetry (enable_observability): the collector's logs, metrics and traces
    logs       = "com.amazonaws.${var.region}.logs"
    monitoring = "com.amazonaws.${var.region}.monitoring"
    xray       = "com.amazonaws.${var.region}.xray"
    # The bastion's Session Manager channel
    ssm         = "com.amazonaws.${var.region}.ssm"
    ssmmessages = "com.amazonaws.${var.region}.ssmmessages"
    ec2messages = "com.amazonaws.${var.region}.ec2messages"
    # The operator's own calls from the bastion: the EKS API, and exercise.sh's load balancer and
    # inference profile lookups. Route 53, which ExternalDNS calls, has no VPC endpoint.
    #
    # `eks` ONLY WITH `oidc-eks`; the roots add it. The eks endpoint's private DNS hosts the
    # eks.<region>.amazonaws.com zone in the VPC, and the OIDC issuer, oidc.eks.<region>.amazonaws.com,
    # is inside it with no record: alone, it makes the issuer stop resolving and every service
    # account token check fail. With the oidc-eks endpoint's own zone also in the VPC, the issuer
    # resolves to the oidc-eks endpoint and its discovery answers 200, while the EKS API answers
    # through the eks endpoint.
    eks                  = "com.amazonaws.${var.region}.eks"
    elasticloadbalancing = "com.amazonaws.${var.region}.elasticloadbalancing"
    bedrock              = "com.amazonaws.${var.region}.bedrock"
  }

  # The agentcore-gateway endpoint admits only the platform's own gateways. A gateway's data plane
  # authorizes callers on a JWT rather than SigV4, so the request has no IAM principal; the policy
  # scopes the resource, not the caller.
  # Every other endpoint keeps the default policy, which allows any request the caller's IAM
  # permissions allow; scoping those to this account's resources is a data perimeter decision
  # (https://aws.amazon.com/identity/data-perimeters-on-aws/) the platform team makes.
  policies = {
    agentcore-gateway = length(var.agentcore_gateway_arns) == 0 ? null : jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "OnlyThisPlatformsGateways"
        Effect    = "Allow"
        Principal = "*"
        Action    = "*"
        Resource  = flatten([for arn in var.agentcore_gateway_arns : [arn, "${arn}/*"]])
      }]
    })
  }
}

resource "aws_security_group" "endpoints" {
  count = length(var.endpoints) > 0 ? 1 : 0

  name_prefix = "${var.name}-vpce-"
  description = "Interface endpoints for ${var.name}: HTTPS from the VPC."
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-vpce" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "https_from_vpc" {
  count = length(var.endpoints) > 0 ? 1 : 0

  security_group_id = aws_security_group.endpoints[0].id
  description       = "HTTPS from the VPC"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_endpoint" "this" {
  for_each = var.endpoints

  vpc_id              = var.vpc_id
  service_name        = local.services[each.key]
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true
  policy              = lookup(local.policies, each.key, null)

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })

  lifecycle {
    precondition {
      condition     = each.key != "agentcore-gateway" || length(var.agentcore_gateway_arns) > 0
      error_message = "The agentcore-gateway endpoint needs agentcore_gateway_arns: without them its policy would admit every gateway."
    }
    precondition {
      condition     = each.key != "eks" || contains(var.endpoints, "oidc-eks")
      error_message = "The eks endpoint needs oidc-eks with it: the eks endpoint's private DNS zone covers oidc.eks.<region>.amazonaws.com, and without the oidc-eks endpoint's zone the cluster's OIDC issuer stops resolving in the VPC."
    }
  }
}
