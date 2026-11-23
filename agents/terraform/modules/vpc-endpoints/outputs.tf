output "endpoint_ids" {
  description = "Endpoint ID per service key."
  value       = { for k, e in aws_vpc_endpoint.this : k => e.id }
}

output "security_group_id" {
  description = "The endpoints' security group, or null when no endpoint is created."
  value       = try(aws_security_group.endpoints[0].id, null)
}
