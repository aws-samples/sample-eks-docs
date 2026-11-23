output "bucket_arn" {
  description = "Bucket ARN. Pass it to ../agent-identity as checkpoint_bucket_arn."
  value       = aws_s3_bucket.checkpoints.arn
}

output "bucket_name" {
  description = "Bucket name, for the agent's own configuration."
  value       = aws_s3_bucket.checkpoints.id
}

output "bucket_regional_domain_name" {
  description = "Regional endpoint. This is the hostname an ApplicationNetworkPolicy allows for an agent that writes checkpoints without a gateway in its path."
  value       = aws_s3_bucket.checkpoints.bucket_regional_domain_name
}
