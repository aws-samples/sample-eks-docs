# agent-cluster

The EKS Auto Mode cluster both paths start from, and the EKS Capabilities for Argo CD, kro, and ACK that the platform runs on. Both roots call it. The header of [`main.tf`](main.tf) explains what it deliberately leaves out.

## What it creates

| Resource | Notes |
|---|---|
| EKS Auto Mode cluster | Private API endpoint, plus a public one restricted to `endpoint_public_access_cidrs` with `endpoint_public_access`; `API` authentication mode, no creator admin. Admins come from `cluster_admin_principal_arns`. |
| Cluster and node IAM roles, access entries, Pod Identity add-on, control plane log group | Skipped when `create_cluster = false`. |
| EKS Capabilities | ARGOCD (`enable_capability_argocd`, default `false`), KRO and ACK (both default `true`), each with its own role. |
| Identity Center admin group and users for Argo CD | With `argocd_manage_admin_group` (default `true`). |
| Agent role path and permissions boundary | Every per-agent role, from Terraform or from the `Agent` resource, is created under them. |
| ECR repositories | One per entry in `ecr_repository_names`, named `<name>/<entry>`, with immutable tags and scan on push. The roots pass their own list. |
| Gateway API enablement | With `enable_gateway_api`, through a `local-exec` call to the AWS CLI because the provider can't express the setting. |

It doesn't create a VPC, any agent's own role, or anything inside the cluster; those come from [`network`](../network), [`agent-identity`](../agent-identity), and [`gitops/`](../../../gitops).

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `name`, `vpc_id`, `subnet_ids` | | Cluster name and placement. |
| `kubernetes_version` | `"1.36"` | |
| `create_cluster` | `true` | `false` attaches to an existing Auto Mode cluster named `name`. The stack still installs cluster-wide objects; read [Clean up](https://docs.aws.amazon.com/eks/latest/userguide/agents-cluster-setup.html) first. |
| `cluster_admin_principal_arns` | `[]` | Principals granted cluster admin. |
| `agent_namespaces` | `["agents"]` | Namespaces agents run in. |
| `enable_capability_argocd` | `false` | Needs an IAM Identity Center instance. `argocd_idc_instance_arn` is optional: the module discovers the instance in `argocd_idc_region`. |
| `argocd_codecommit_repository_arns`, `argocd_codeconnections_arns`, `argocd_secrets_manager_secret_arns`, `argocd_ecr_pull` | empty | What the Argo CD role may read. |
| `ecr_repository_names`, `ecr_force_delete` | see `variables.tf`, `false` | |
| `enable_gateway_api`, `gateway_api_crds_managed` | `false`, `false` | Gateway API for agent ingress; the CRDs stay owned by GitOps. |

## Outputs

`cluster_name`, `cluster_arn`, `cluster_endpoint`, `cluster_oidc_issuer_url`, `cluster_security_group_id`, `node_role_arn`, `agent_role_path`, `agent_permissions_boundary_arn`, `ecr_repository_urls`, `ecr_repository_arns`, `capability_arns`, `argocd_server_url`. The full list and descriptions are in [`outputs.tf`](outputs.tf).

## Constraints

* The Argo CD capability's role has no permissions until you set one of the four repository grants above. Without one, every Application fails before it syncs, unless the repository is public over anonymous HTTPS.
* With `ecr_force_delete = false`, a repository that still holds images can't be deleted, so removing an entry from `ecr_repository_names` fails the apply. [`scripts/teardown.sh`](../../../scripts/teardown.sh) empties them.
* `enable_gateway_api` needs an AWS CLI recent enough to know the Gateway API setting on the machine that runs `terraform apply`.
