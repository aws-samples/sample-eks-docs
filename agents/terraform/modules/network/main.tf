# The network, for a team that does not already have one.
#
# WHY THIS MODULE IS OPTIONAL AND NOT THE DEFAULT ASSUMPTION. An agent platform belongs inside the
# network perimeter the organization already operates: its routing, its flow logs, its peering, its
# egress inspection. So both roots take `vpc_id` and `subnet_ids` and will use them when given. This
# module exists because "bring your own VPC" with no alternative makes the first `terraform apply`
# impossible for anyone evaluating the stack, and the usual workaround -- pasting in the default VPC
# -- is the worst option available: the default VPC's subnets are public and auto-assign public IPs.
#
# What it builds, and the reasoning in each case:
#
#   - One VPC with DNS support and hostnames on, because EKS private endpoints and the EBS CSI
#     driver both need them.
#   - `az_count` PRIVATE subnets. The cluster and every node goes here. Nothing in this stack is
#     meant to be reachable from the internet.
#   - `az_count` PUBLIC subnets, which exist only to hold the NAT gateways and any deliberately
#     internet-facing load balancer. They do NOT auto-assign public IPs -- a NAT gateway carries its
#     own EIP and a public load balancer does not need the subnet default, so leaving it on would
#     only mean an instance launched here by mistake gets a public address.
#   - A NAT gateway so nodes can reach ECR, Bedrock and the EKS control plane. One by default, which
#     is a single point of failure and about a third of the cost of three; set
#     `single_nat_gateway = false` for one per AZ in anything you care about.
#
# A stricter alternative worth knowing about: drop the NAT gateways and the internet gateway
# entirely, and give the private subnets VPC interface endpoints for ECR, S3, STS, Bedrock, EKS and
# CloudWatch. That removes the cluster's route to the internet altogether. It is more objects and
# more cost per endpoint, and it breaks anything that pulls from a public Helm repository or an OCI
# registry -- which this stack's own platform layer does -- so it is a deliberate step, not a
# default.

locals {
  # Exclude Local Zones and Wavelength: `opt-in-not-required` is the ordinary-Region answer. A Local
  # Zone cannot run an EKS control plane and will fail an apply in a confusing way.
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /20 per subnet out of a /16, which is 4091 usable addresses each. Sized for the VPC CNI, which
  # assigns real VPC addresses to pods -- a /24 per subnet runs out of pod IPs on a handful of nodes
  # and the failure reads as a scheduling problem.
  #
  # Private subnets take the low block and public the high one, so the two are easy to tell apart in
  # a route table and there is room to add more of either without renumbering.
  private_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  nat_count = var.single_nat_gateway ? 1 : var.az_count
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(var.tags, { Name = var.name })
}

# THE DEFAULT SECURITY GROUP, EMPTIED. Every VPC gets one, it cannot be deleted, and it ships with an
# allow-all rule for anything else carrying the same group. Nothing here should ever use it, but a
# resource created later without an explicit group gets it by default -- so this removes every rule
# rather than leaving an allow-all group lying around. Declaring the resource adopts the existing
# group; it does not create a second one.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  # No ingress and no egress blocks: both lists are emptied.

  tags = merge(var.tags, { Name = "${var.name}-default-DO-NOT-USE" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = var.name })
}

resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.private_cidrs[count.index]

  tags = merge(var.tags, {
    Name = "${var.name}-private-${local.azs[count.index]}"

    # Tells the AWS Load Balancer Controller it may place an INTERNAL load balancer here. Without
    # it, a Service of type LoadBalancer with the internal annotation fails to provision and the
    # error names subnet discovery rather than a missing tag.
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_subnet" "public" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = local.public_cidrs[count.index]

  # Deliberately false. See the header.
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name                     = "${var.name}-public-${local.azs[count.index]}"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_eip" "nat" {
  count  = local.nat_count
  domain = "vpc"

  tags = merge(var.tags, { Name = "${var.name}-nat-${count.index}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  count = local.nat_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, { Name = "${var.name}-${local.azs[count.index]}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route_table_association" "public" {
  count = var.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One route table per private subnet even when there is a single NAT gateway, so moving to one NAT
# per AZ later is a change to the route target rather than a resubnetting exercise.
resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
  }

  tags = merge(var.tags, { Name = "${var.name}-private-${local.azs[count.index]}" })
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# S3 through a gateway endpoint rather than the NAT. Free, and it is the one endpoint that pays for
# itself immediately here: ECR image layers are served from S3, so every image pull on every node
# otherwise crosses the NAT gateway and is billed per gigabyte.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}

# ---------------------------------------------------------------------------
# Flow logs (optional)
# ---------------------------------------------------------------------------
#
# Off by default: see enable_flow_logs. When on, every accepted and rejected flow in the VPC goes to
# one log group with a retention, so the record does not grow without limit, and `terraform destroy`
# removes it with the VPC.

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_logs_retention_days

  tags = var.tags
}

data "aws_iam_policy_document" "flow_logs_assume" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    # Only flow logs in this account may use the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current[0].account_id]
    }
  }
}

data "aws_caller_identity" "current" {
  count = var.enable_flow_logs ? 1 : 0
}

resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${var.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json

  tags = var.tags
}

# Write access to this one log group and nothing else.
data "aws_iam_policy_document" "flow_logs_write" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs[0].arn}:*"]
  }
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs_write[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id               = aws_vpc.this.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn         = aws_iam_role.flow_logs[0].arn

  tags = merge(var.tags, { Name = "${var.name}-flow-logs" })
}
