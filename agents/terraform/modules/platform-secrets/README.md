# platform-secrets

Generated credentials for platform components, stored in AWS Secrets Manager, and the per-namespace IAM roles the Secrets Store CSI driver uses to sync them into the cluster as Kubernetes Secrets. The [`platform-secrets`](../../../gitops/charts/platform-secrets) chart, applied by `45-platform-secrets.yaml` on each path, holds the `SecretProviderClass` objects and reads this module's `chart_values` output.

* On the open source path, the root calls it when `enable_platform_secrets` is on (the default). It generates the passwords for Valkey, Grafana, Langfuse, and the memory database, and syncs the gateway's third-party credentials and the direct OIDC client secret.
* On the AWS services path, the root calls it only with `ingress_idp = "oidc-direct"`, with `include_platform_components = false`, so the only secret is the ingress OIDC client.

## What it creates

| Resource | Notes |
|---|---|
| Generated secrets | `<name>/platform/<secret>`, one per Kubernetes Secret, each only when the component that reads it is on: `valkey-auth` (`include_session_state`), `agent-memory-db` (`include_memory_db`), `grafana-admin` (`include_observability`), the `langfuse-*` secrets (`include_langfuse`), `langfuse-otlp` (`include_observability` and `include_langfuse`), and `langfuse-evals-api` (`include_evals`). None with `include_platform_components = false`. |
| `aws_secretsmanager_secret.ingress_oidc` | With `ingress_oidc`: `<name>/platform/ingress-oidc`, with the `clientID` and `clientSecret` keys the load balancer controller reads, synced into the ingress namespace. |
| Reader roles and Pod Identity associations | `<name>-secrets-<key>`, one per namespace that reads a secret, for `service_account_name`. Each can read only its namespace's secrets. |

Values are generated with `random_password` and `random_id`, so they're in Terraform state.

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `name`, `cluster_name`, `cluster_arn` | | |
| `namespaces` | `agent-memory`, `monitoring`, `langfuse`, `ingress`, `agent-evals`, `agentgateway-system` | Which namespace reads each group of secrets. |
| `include_platform_components` | `true` | `false` generates nothing. |
| `include_session_state`, `include_observability`, `include_langfuse`, `include_memory_db`, `include_evals` | `true`, `true`, `true`, `true`, `false` | |
| `ingress_oidc` | `null` | `{ client_id, client_secret_arn }` for `oidc-direct`. The secret is read at plan time. |
| `external_secrets` | `{}` | Secrets another module owns, synced here. Their resource policy must admit the reader role `<name>-secrets-<namespace key>`. |
| `service_account_name` | `"platform-secrets"` | Must match the chart. |
| `recovery_window_in_days` | `7` | |

## Outputs

`secret_arns`, `secret_names`, `reader_role_arns`, `chart_values`, `namespaces`, `memory_db_secret_arn`.

## Constraints

* The CSI driver writes a Kubernetes Secret when its pod mounts the volume. A changed generated value changes `chart_values` and rolls the syncer, but a value set out of band in an `external_secrets` entry arrives only when the syncer pod is recreated.
* Agent pods in Nitro sandboxes can't mount CSI volumes, so an agent reads `agent-memory-db` from Secrets Manager with its own role (`memory_db_secret_arn`).
