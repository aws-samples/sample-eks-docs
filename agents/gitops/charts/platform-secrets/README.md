# platform-secrets chart

Projects secrets that Terraform writes to AWS Secrets Manager into the Kubernetes Secrets that third-party charts and the ingress read, through the Secrets Store CSI driver. Read this when a component fails with `secret not found`.

The `platform-secrets` Application in `gitops/platform/<path>/45-platform-secrets.yaml` installs it at sync wave -1, after the CSI driver and its AWS provider at wave -2 in the same file. On the open source path it carries the Valkey, Grafana, and Langfuse secrets, the direct OIDC client secret, and third-party credentials; on the AWS services path, only the direct OIDC client secret, with `ingress_idp = "oidc-direct"`. Each value is documented in [`values.yaml`](values.yaml).

## What it renders

| Template | Objects |
|---|---|
| `templates/00-namespaces.yaml` | Each namespace that holds a secret, unless another chart owns it (`externallyOwnedNamespaces`) |
| `templates/secretproviderclass.yaml` | A SecretProviderClass per secret, with `secretObjects` that produce a Kubernetes Secret |
| `templates/syncer.yaml` | Per namespace, the `platform-secrets` ServiceAccount, a `platform-secrets-syncer` Deployment that mounts every class in the namespace, and its PodDisruptionBudget |

A synced Secret exists only while a pod mounts its SecretProviderClass. The consumers read `existingSecret` and mount nothing, so the syncer pod is what keeps each Secret in place; deleting it deletes them.

## Values

`platformSecrets.enabled` and `platformSecrets.secrets` (each Secret's namespace, Secrets Manager name, and keys) come from `terraform-values.yaml`, written by `terraform/modules/platform-secrets`. The chart refuses to render against the placeholder account ID, because rendering nothing would prune the Secrets a previous sync created. To create the Secrets yourself on the open source path, set `enable_platform_secrets = false` in Terraform.
