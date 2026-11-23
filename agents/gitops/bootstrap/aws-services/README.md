# Bootstrap objects (aws-services)

The three objects that hand the cluster to Argo CD on the aws-services path. Everything else on the cluster arrives through them, so read this when you bootstrap a cluster or need to know why an Application can't resolve its destination.

| File | What it is | Placeholders |
|---|---|---|
| `cluster-secret.yaml` | The Argo CD cluster Secret that registers the destination `eks-agents`, which every Application names | `CLUSTER_ARN`, `CLUSTER_NAME`, `CLUSTER_CA_DATA` |
| `appproject.yaml` | The `eks-agents` AppProject every Application names: the repositories it may install from, the one cluster it may install into, and the cluster-scoped kinds it may create | `REPO_URL`, `# EXTRA_SOURCE_REPOS` |
| `root-app.yaml` | The `eks-agents-platform` Application, pointed at [`gitops/platform/aws-services/`](../../platform/aws-services) | `REPO_URL`, `REPO_REVISION`, `REPO_PATH`, `PLATFORM_EXCLUDED`, `# VALUES_FILES` |

`terraform apply` renders `cluster-secret.local.yaml`, `appproject.local.yaml` and `root-app.local.yaml` beside these templates with the placeholders filled in, including the AppProject's `sourceRepos` (`gitops_repo_url`, the chart repositories the platform reads, and any `argocd_extra_source_repos`) and the `excluded` list of platform files whose layer you turned off (`platform_excluded`). `scripts/bootstrap-gitops.sh` then folds the values files Terraform wrote beside the platform chart (`gitops/platform/aws-services/*-values.yaml`) into the root Application's `helm.values`, so the account's values reach the cluster in that one object and nothing account-specific is committed anywhere. `.gitignore` excludes the rendered files, because the cluster Secret carries the cluster's CA data. Rerun the apply and the bootstrap after you change a component variable, so the root Application picks up the new list and values.

## Apply them

On a private cluster, run the script on the bastion. It applies the three objects in order, preferring the `*.local.yaml` files, and refuses a file that still carries a placeholder:

```bash
./scripts/run-stack.sh --root terraform/aws-services -- ./scripts/bootstrap-gitops.sh --path aws-services --sync
```

The order matters: no Application resolves a destination before the cluster Secret exists, and none is admitted to the `argocd` namespace before the AppProject that allows it. The root Application has no automated sync, so `--sync` starts each sync of the component set; [the GitOps README](../../README.md#bootstrap-and-sync) lists the script's flags. The header of `cluster-secret.yaml` explains why `server` is the cluster ARN, which the off-cluster EKS Capability for Argo CD requires.

## Remove them

Deleting the root Application deletes every child Application and what it installed, including the admission policy and the network policy, while running agents keep running without those controls. To remove one component, turn its variable off and sync with `--prune`. To remove the platform, follow [Clean up](https://docs.aws.amazon.com/eks/latest/userguide/agents-cluster-setup.html) in the EKS User Guide.
