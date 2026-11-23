output "vpc_id" {
  description = "The VPC's id."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "The VPC's CIDR, for security group rules that need to name the whole network."
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet ids. This is what the cluster and its nodes use."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "Public subnet ids. These hold the NAT gateways and any deliberately internet-facing load balancer; nothing in this stack is placed here by default."
  value       = aws_subnet.public[*].id
}

output "availability_zones" {
  description = "Availability Zones the subnets were created in."
  value       = local.azs
}
