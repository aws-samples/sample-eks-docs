# terraform

This directory holds the two root modules, `open-source` and `aws-services`, and the modules they call. Everything here is an AWS API call. Every Kubernetes object is in [`gitops/`](../gitops), and the two meet only in the values files that Terraform renders for Argo CD.

## Choose a root

| Root | Path |
|---|---|
| [`open-source/`](open-source) | AgentGateway, memory, observability, and evaluations run in the cluster. |
| [`aws-services/`](aws-services) | AgentCore Gateway, ElastiCache, S3 Vectors, AgentCore Memory, and CloudWatch. |

Apply one root, not both. [AI agents on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/agents.html) compares them. Both require Terraform 1.9 or later, and both default to Kubernetes 1.36.

```bash
cd terraform/aws-services          # or terraform/open-source
cp minimal.tfvars my.tfvars
terraform init
terraform plan  -var-file=my.tfvars
terraform apply -var-file=my.tfvars
terraform output next_steps
```

Each root has a `minimal.tfvars`, the smallest configuration that produces a working cluster, and an `example.tfvars` that describes every option. Each page of [AI agents on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/agents.html) names the variables for its layer.

To learn a root, read `example.tfvars`, then `main.tf`, which calls the modules in dependency order, then `outputs.tf`. `variables.tf` and `outputs.tf` describe every variable and output.

## Modules

| Module | Creates | Called by |
|---|---|---|
| [`network`](modules/network) | VPC, subnets, NAT, routes, S3 gateway endpoint. Skipped when you pass `vpc_id`. | Both |
| [`agent-cluster`](modules/agent-cluster) | The EKS Auto Mode cluster, the Argo CD, kro, and ACK capabilities, ECR repositories, the agent role path and permissions boundary. | Both |
| [`image-build`](modules/image-build) | The CodeBuild project `scripts/build-images.sh --root` builds the agent images in. | Both, with `enable_image_build` |
| [`bastion`](modules/bastion) | The SSM-managed host that can reach the private API endpoint. | Both, with `enable_bastion` |
| [`durable-storage`](modules/durable-storage) | The S3 checkpoint bucket. | Both, with `enable_checkpoints` |
| [`agent-identity`](modules/agent-identity) | One agent's IAM role and Pod Identity association. | Both, once per entry in `agents` |
| [`ingress`](modules/ingress) | Private zone, certificate, Cognito pool, and DNS reconciler role for agent ingress. | Both, with `enable_ingress` |
| [`vpc-endpoints`](modules/vpc-endpoints) | Interface VPC endpoints that keep traffic to AWS services inside the VPC: AgentCore Gateway, Amazon Bedrock, AgentCore Memory, S3 Vectors, STS, Secrets Manager, ECR, Pod Identity, CloudWatch, X-Ray, and Systems Manager. | Both, with `vpc_endpoints` |
| [`platform-secrets`](modules/platform-secrets) | The stack's generated credentials in Secrets Manager, and the roles that sync them into the cluster. | Open source with `enable_platform_secrets`; AWS services with `ingress_idp = "oidc-direct"` |
| [`egress-agentgateway`](modules/egress-agentgateway) | The AWS side of AgentGateway: its role, brokered secrets, audit log group. | Open source, with `enable_gateway` |
| [`egress-agentcore`](modules/egress-agentcore) | AgentCore Gateway, its targets, credential providers, and Cedar policy engine. | AWS services, with `enable_gateway` |
| [`observability-aws`](modules/observability-aws) | Transaction Search, log groups, the ADOT collector's role, the CloudWatch dashboard. | AWS services, with `enable_observability` |
| [`memory-aws`](modules/memory-aws) | ElastiCache Serverless, S3 Vectors, AgentCore Memory, each behind its own variable. | AWS services |
| [`evaluations-aws`](modules/evaluations-aws) | AgentCore evaluators, online evaluation, the Strands Evals runner's role. | AWS services, with `enable_observability` and `enable_evaluations` or `enable_online_evaluation` |

## Defaults

* `agents = {}` is the usual setting. You then declare agents in the cluster as `Agent` resources, and kro composes each one's role, Pod Identity association, and workload through ACK. List an agent in `agents` only if you want to review its permissions in Terraform. Don't declare the same agent both ways.
* `mesh_mode = "none"` on both paths. Network policy already makes the gateway the only destination an agent can reach, and the mesh is a layer you add. See [Service mesh for agents](https://docs.aws.amazon.com/eks/latest/userguide/agents-mesh.html).
* The open source root can attach to an existing EKS Auto Mode cluster with `create_cluster = false`. It still installs cluster-wide objects, so read [Clean up](https://docs.aws.amazon.com/eks/latest/userguide/agents-cluster-setup.html) first.

A reviewer should know the following defaults, each listed with its tighter setting.

* Argo CD's cluster access: `argocd_cluster_access_policy_arn` is AmazonEKSClusterAdminPolicy, the EKS User Guide's quick-setup choice. Tighter: `""`, with AmazonEKSAdminViewPolicy and a ClusterRole limited to the kinds this stack applies, bound to `eks-access-entry:<capability role ARN>`.
* The Argo CD project: the `eks-agents` AppProject lists only the stack's repositories, plus `argocd_extra_source_repos` (empty by default), and only the `eks-agents` cluster. Its `clusterResourceWhitelist` is `"*"`, because the stack installs CRDs, ClusterRoles, webhooks, cluster network policies, and admission policies. Tighter: list those kinds in `gitops/bootstrap/<path>/appproject.yaml`.
* The Marketplace subscription (open source): `enable_bedrock_marketplace_subscribe = true` grants the gateway's role `aws-marketplace:Subscribe` and `ViewSubscriptions` account-wide. Tighter: `false`, where subscriptions are managed centrally.
* Password sign-in for test users: `person_access_password_auth = true` turns on `USER_PASSWORD_AUTH` on the person-access api client for `scripts/exercise.sh`. Tighter: `false` outside a test.
* The infrastructure carve-out: `networkPolicy.infrastructureNamespaces` in `gitops/base/values.yaml` accepts all traffic for kube-system, istio-system and monitoring, whose pods run on the agents' nodes. Tighter: drop monitoring where the netpol-verdicts DaemonSet isn't deployed.
* The sandbox runtime: `admission.allowConfidentialSandbox: false` admits only `isolated-sandbox`. This is already the tighter setting.
* Sandbox network limits: `agentResource.sandboxLimits` gives every Agent 1G and 15000 packets/s each direction, 256 DNS packets/s and 16384 connections, above the Nitro sandbox's own defaults. Tighter: lower values on the Agent's `networkBandwidth`, `networkPacketsPerSecond`, `dnsQueriesPerSecond` and `connectionLimit`.
* Prompt content in telemetry (AWS services): `collector.keepPromptContent: false` strips prompts and completions from spans, except with `enable_evaluations` or `enable_online_evaluation`, which grade them. With no evaluation turned on, this is already the tighter setting.
* VPC Flow Logs: `enable_vpc_flow_logs = false` on the VPC this stack creates, because flow logs bill per gigabyte and an organization's network usually collects them centrally. Tighter: `true`, which sends every flow to `/aws/vpc/<name>/flow-logs` with `vpc_flow_logs_retention_days` (90) of retention.
* S3 access logging: the checkpoint, person-access and bastion staging buckets have no server access logging. Tighter: add an `aws_s3_bucket_logging` resource for each one, pointing at your organization's log bucket.

## What Terraform hands to GitOps

Each root writes `gitops/platform/<path>/terraform-values.yaml` (set by `gitops_values_path`) with the account, Region, cluster, role ARNs, gateway endpoints, bucket, and cache endpoint, and the Argo CD Applications read it as a Helm values file. It also writes `external-dns-values.yaml` beside it, `collector-values.yaml` on the open source path, and the bootstrap objects under `gitops/bootstrap/<path>/`. Don't commit these files. `scripts/bootstrap-gitops.sh` adds their values to the root Application, so they reach the cluster without going to Git.

The committed `terraform-values.yaml` is a placeholder with invalid values, so the charts don't render until an apply replaces it.

## Conventions

* Terraform deletes the ECR repositories and the checkpoint bucket with their contents only when you set `ecr_force_delete` or `checkpoint_bucket_force_destroy`, so an apply can't delete images or agent state as a side effect. [`scripts/teardown.sh`](../scripts/teardown.sh) empties them before `terraform destroy`.
* Run `terraform fmt -recursive terraform` and [`scripts/validate.sh`](../scripts/validate.sh) before every commit. The pre-commit hook in `.githooks/` runs `validate.sh`.
