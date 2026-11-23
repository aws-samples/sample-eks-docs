# bastion

An EC2 instance inside the VPC that can reach the cluster's private API endpoint. Both roots call it when `enable_bastion` is on (the default), because nothing outside the VPC can run `kubectl` against the cluster. [`scripts/run-stack.sh`](../../../scripts/run-stack.sh) runs repository scripts on it.

You reach it through AWS Systems Manager Session Manager. It has no key pair, no public IP address, and no inbound security group rules.

## What it creates

| Resource | Notes |
|---|---|
| `aws_instance.this` | Amazon Linux 2023 in a private subnet, IMDSv2 only, encrypted root volume. User data installs git, Docker, `kubectl`, and Helm, writes the kubeconfig, and clones `gitops_repo_url` to `/opt/eks-agents`. |
| Security group | Egress only: 443 anywhere, DNS to the VPC CIDR. |
| Ingress rule on the cluster security group | 443 from the bastion. Without it, `kubectl` hangs. |
| IAM role and instance profile | `AmazonSSMManagedInstanceCore`, `eks:DescribeCluster`, push to `ecr_repository_arns`, pull from `gitops_codecommit_repository_arns`, and with `teardown_access`, delete those repositories and empty the checkpoint bucket. |
| EKS access entry | `AmazonEKSClusterAdminPolicy`, cluster scope. |
| Staging bucket | `<cluster>-bastion-staging-<account>`, for the archives `run-stack.sh` copies over. Objects expire, and the bucket is force-destroyed with the stack. |

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `cluster_name`, `cluster_arn`, `cluster_security_group_id` | | From `agent-cluster`. |
| `vpc_id`, `vpc_cidr`, `subnet_id` | | A private subnet. |
| `instance_type`, `architecture` | `"t3.small"`, `"x86_64"` | Change both together. |
| `kubectl_version` | `"v1.36.6"` | Keep within one minor version of the cluster. |
| `ecr_repository_arns` | `[]` | Repositories the host may push to. |
| `teardown_access`, `checkpoint_bucket_arn` | `true`, `""` | Lets [`scripts/teardown.sh`](../../../scripts/teardown.sh) run its ECR and bucket steps here. |
| `gitops_codecommit_repository_arns`, `gitops_repo_url` | `[]`, `""` | The repository to clone. The host holds no Git credential for other hosts. |
| `permissions_boundary_arn`, `kms_key_arn` | `""`, `""` | |

## Outputs

`instance_id`, `role_arn`, `security_group_id`, `start_session_command`, `run_command_example`, `readiness_check`, `staging_bucket`.

## Constraints

* The bastion's architecture must match the nodes', because images built on it run there. EKS Auto Mode's default node pool is x86_64, and an arm64 image fails on it with `exec format error`.
* AWS Systems Manager Run Command doesn't load a login profile, so a command sent with `send-command` must `source /etc/bastion-env` first, as `run_command_example` does.
* The AMI is ignored after creation, so a new Amazon Linux release doesn't replace the host. Patch it, or replace it deliberately.
* Bootstrap takes a few minutes after the instance starts; `readiness_check` tells you when it's done.
