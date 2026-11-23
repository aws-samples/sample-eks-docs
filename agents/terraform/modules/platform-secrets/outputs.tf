output "secret_arns" {
  description = "Secrets Manager ARNs, keyed by the Kubernetes Secret name they are projected as."
  value       = { for k, v in local.all_secrets : k => v.arn }
}

output "secret_names" {
  description = "Secrets Manager secret names, keyed by Kubernetes Secret name. This is what the SecretProviderClass objects reference."
  value       = { for k, v in local.all_secrets : k => v.sm_name }
}

output "reader_role_arns" {
  description = "The per-namespace reader roles, for a reviewer checking what each one can read."
  value       = { for k, v in aws_iam_role.reader : k => v.arn }
}

output "chart_values" {
  description = "The `platformSecrets.secrets` map for gitops/charts/platform-secrets: Secrets Manager name and namespace per Kubernetes Secret, so the chart cannot disagree with the IAM scoping about which namespace reads what."
  value = {
    for name, spec in local.all_secrets : name => {
      secretsManagerName = spec.sm_name
      namespace          = spec.namespace
      keys               = spec.keys
      type               = try(spec.type, "Opaque")
      labels             = try(spec.labels, {})
      # The Secrets Manager version, so a changed value changes the syncer's pod template and Argo CD
      # rolls it: the CSI driver writes the Kubernetes Secret at mount time, and without a new mount
      # a rotated value stops at Secrets Manager. See the chart's syncer.yaml.
      version = spec.version
    }
  }
}

output "namespaces" {
  description = "Every namespace that reads a secret, for the chart's platformSecrets.namespaces: a syncer runs in each."
  value       = sort(distinct([for name, spec in local.all_secrets : spec.namespace]))
}

output "memory_db_secret_arn" {
  description = "The memory tier's agent login (username, password), which an agent reads with its own role when consolidation is on. Empty when the platform components are not generated."
  value       = try(aws_secretsmanager_secret.this["agent-memory-db"].arn, "")
}

output "in_use" {
  description = "Whether this module syncs any secret at all. The root excludes 45-platform-secrets.yaml from the sync when it is false, so this is the one place that decides it: a hand-kept list of readers can leave out a reader, such as the delegated token's exchange client, and the gateway then waits on a Secret that never arrives. Keys only, so it is known at plan time."
  value       = length(local.all_secrets) > 0
}
