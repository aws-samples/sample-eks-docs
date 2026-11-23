output "queues" {
  description = "Per agent: the task, dead-letter and result queues' URLs and ARNs."
  value = { for a, _ in local.queues : a => {
    tasks_url   = aws_sqs_queue.tasks[a].url
    tasks_arn   = aws_sqs_queue.tasks[a].arn
    dlq_url     = aws_sqs_queue.dlq[a].url
    dlq_arn     = aws_sqs_queue.dlq[a].arn
    results_url = aws_sqs_queue.results[a].url
    results_arn = aws_sqs_queue.results[a].arn
  } }
}

output "keda_role_arn" {
  description = "KEDA operator's role (queue depth only)."
  value       = aws_iam_role.keda.arn
}
