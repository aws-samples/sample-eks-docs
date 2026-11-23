variable "name" {
  description = "Name prefix for the VPC and every resource in it."
  type        = string
}

variable "region" {
  description = "AWS Region. Used for the S3 gateway endpoint's service name."
  type        = string
}

variable "vpc_cidr" {
  description = <<-EOT
    CIDR for the VPC. A /16 gives each subnet a /20, which matters because the VPC CNI assigns real
    VPC addresses to pods -- a /24 per subnet runs out of pod addresses on a handful of nodes, and
    the failure presents as pods stuck Pending rather than as an address problem.

    Pick a range that does not overlap anything you might peer to later.
  EOT
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid CIDR of /20 or larger (a smaller prefix number)."
  }
}

variable "az_count" {
  description = <<-EOT
    Number of Availability Zones, each getting one private and one public subnet.

    Three is the default for a reason beyond availability: Auto Mode's node pools span every subnet
    they are given, and a single zone that cannot fill a launch request presents as "no capacity"
    with the NodeClaim stuck rather than as a zonal failure. More zones means more places for a
    launch to succeed.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4. EKS requires subnets in at least two zones."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    One NAT gateway for the whole VPC instead of one per zone.

    True by default, which is the evaluation choice: a NAT gateway bills hourly plus per gigabyte,
    so three is roughly three times the standing cost. It is also a single point of failure and a
    cross-zone data charge for every node outside its zone. Set it false for anything you care
    about staying up.
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}

variable "enable_flow_logs" {
  description = <<-EOT
    VPC Flow Logs for every network interface in the VPC, delivered to a CloudWatch Logs group.

    False by default. Flow logs bill per gigabyte ingested and stored, and an organization that
    already runs a network usually collects them centrally -- which is also why this module is
    optional. Set it true for a VPC this module creates that nothing else is watching: without
    flow logs there is no record of which addresses a node or a pod talked to.
  EOT
  type        = bool
  default     = false
}

variable "flow_logs_retention_days" {
  description = "Days the flow log group keeps records. Used only when enable_flow_logs is true."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_logs_retention_days)
    error_message = "flow_logs_retention_days must be a value CloudWatch Logs accepts, such as 30, 90 or 365."
  }
}
