output "project_name" {
  description = "The CodeBuild project scripts/build-images.sh --root starts."
  value       = aws_codebuild_project.images.name
}

output "source_bucket" {
  description = "Where build-images.sh stages the working tree for a build. Objects expire after a day."
  value       = aws_s3_bucket.source.bucket
}

output "log_group" {
  description = "The builds' CloudWatch log group."
  value       = aws_cloudwatch_log_group.builds.name
}
