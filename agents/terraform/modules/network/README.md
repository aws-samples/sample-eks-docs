# network

A VPC for a team that doesn't already have one. Both roots call it only when `vpc_id` is empty (on the open source path, also only when `create_cluster` is true). If you have a network your organization operates, pass `vpc_id` and `subnet_ids` to the root instead, and this module isn't in the plan at all.

Don't use the default VPC in its place: its subnets are public and assign public IP addresses.

## What it creates

| Resource | Notes |
|---|---|
| VPC | DNS support and hostnames on. Its default security group has every rule removed. |
| Private subnets | `az_count` of them, for the cluster and nodes. Each is the VPC CIDR plus 4 bits, so a /16 gives /20 subnets. |
| Public subnets | `az_count` of them, for NAT gateways and internet-facing load balancers only. They don't assign public IP addresses. |
| Internet gateway, NAT gateways, route tables | One NAT gateway, or one per zone with `single_nat_gateway = false`. |
| S3 gateway endpoint | On the private route tables, so image layer pulls from ECR don't cross the NAT gateway. |

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `name`, `region` | | |
| `vpc_cidr` | `"10.0.0.0/16"` | /20 or larger. Pods get VPC addresses, so small subnets run out of pod IP addresses. |
| `az_count` | `3` | From 2 to 4. |
| `single_nat_gateway` | `true` | One NAT gateway is cheaper and a single point of failure. |

## Outputs

`vpc_id`, `vpc_cidr`, `private_subnet_ids`, `public_subnet_ids`, `availability_zones`.
