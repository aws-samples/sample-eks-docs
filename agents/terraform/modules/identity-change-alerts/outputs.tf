output "topic_arn" {
  description = "The SNS topic every reported change is published to."
  value       = aws_sns_topic.changes.arn
}
