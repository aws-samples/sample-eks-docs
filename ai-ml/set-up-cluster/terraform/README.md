## Cluster setup (Terraform)

Two variants of the same GPU-ready EKS cluster. Pick one based on how you want to manage compute:

- [`auto-mode/`](auto-mode/) - EKS Auto Mode manages the GPU nodes.
- [`karpenter/`](karpenter/) - Self-managed Karpenter provisions the GPU nodes.

Both provision the cluster, monitoring (Amazon Managed Prometheus, DCGM exporter), an S3 model bucket, and GPU NodePools.

### Apply

```bash
export TF_VAR_region=us-east-2
export TF_VAR_cluster_name=ai-eks-docs

terraform init
terraform apply
```

After apply, use the `configure_kubectl` output to connect:

```bash
terraform output -raw configure_kubectl
```

### GPU NodePool strategies

`var.nodepools` selects which GPU strategy to deploy (defaults to `dynamic-spot-on-demand`). Set a `reservation` to have Terraform create a tagged On-Demand Capacity Reservation. Enable at most one strategy at a time. See the comments at the top of `nodepools.tf` for the available strategies and examples.

> Run `terraform fmt` and `terraform validate` before applying.
