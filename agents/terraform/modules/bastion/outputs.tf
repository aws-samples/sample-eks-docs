output "instance_id" {
  description = "The bastion's instance id, which is how you reach it -- there is no address to connect to."
  value       = aws_instance.this.id
}

output "role_arn" {
  description = "The instance role, which holds the cluster-admin access entry. Useful when reading audit logs: cluster changes made from the bastion are attributed to this."
  value       = aws_iam_role.this.arn
}

output "security_group_id" {
  description = "The bastion's security group. It has no inbound rules; it is an output so a teardown can find it."
  value       = aws_security_group.this.id
}

output "start_session_command" {
  description = "Open an interactive shell. Requires the Session Manager plugin on your machine."
  value       = "aws ssm start-session --region ${data.aws_region.current.region} --target ${aws_instance.this.id}"
}

output "run_command_example" {
  description = "Run one command without a shell. Note the `source /etc/bastion-env` -- send-command runs no profile script, so without it kubectl has no KUBECONFIG and falls back to localhost:8080."
  value       = "aws ssm send-command --region ${data.aws_region.current.region} --instance-ids ${aws_instance.this.id} --document-name AWS-RunShellScript --parameters 'commands=[\"source /etc/bastion-env && kubectl get nodes\"]'"
}

output "readiness_check" {
  description = "Bootstrap installs kubectl and helm and writes the kubeconfig; it is not instant. This file exists when it has finished."
  value       = "aws ssm send-command --region ${data.aws_region.current.region} --instance-ids ${aws_instance.this.id} --document-name AWS-RunShellScript --parameters 'commands=[\"cat /var/log/bastion-bootstrap-complete\"]'"
}

output "staging_bucket" {
  description = "Where scripts/run-stack.sh stages the working tree for a run on the bastion. Transient archives only."
  value       = aws_s3_bucket.staging.id
}
