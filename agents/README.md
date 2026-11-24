# AI agents on Amazon EKS: reference sample

This directory holds the Terraform and GitOps templates for running AI agents on Amazon EKS. It's the reference sample for the [AI agents on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/agents.html) section of the Amazon EKS User Guide, and every command in that section runs from here. The guide explains each layer and walks through the steps. This README describes the repository's layout and scripts, and how to run templates you've changed.

The reference sample shows one way to run agents on Amazon EKS. It isn't a production-ready deployment. Before you rely on it, compare its [defaults](terraform/README.md#defaults), security controls, and cost with your own requirements, and adapt it to them.

The reference sample comes in two paths that share one cluster design:

* The *open source path* runs the gateway, memory, observability, and evaluation components in your cluster.
* The *AWS services path* uses Amazon Bedrock AgentCore, Amazon ElastiCache, Amazon S3 Vectors, and Amazon CloudWatch for the same layers.

Both paths deploy an EKS Auto Mode cluster, with Kubernetes 1.36 by default, a private API endpoint, Nitro Sandbox isolation, network policy in three tiers, an IAM role for each agent through EKS Pod Identity, and the EKS Capabilities for Argo CD, kro, and ACK. On both paths, you onboard an agent with one `Agent` resource.

## What the base setup includes

The base setup is a cluster that runs a sandboxed agent. Each other layer has a Terraform variable, and it stays off until you turn it on.

| Layer | Variable | User Guide page |
|---|---|---|
| Cluster, network policy, ECR, permissions boundary, bastion | The base setup | [Cluster setup](https://docs.aws.amazon.com/eks/latest/userguide/agents-cluster-setup.html) |
| Argo CD, kro, ACK, and the in-cluster components | `enable_argocd` (on in the base setup) | [EKS Capabilities](https://docs.aws.amazon.com/eks/latest/userguide/agents-capabilities-setup.html) |
| Egress gateway | `enable_gateway` | [Gateway](https://docs.aws.amazon.com/eks/latest/userguide/agents-gateway.html) |
| Service mesh | `mesh_mode` | [Mesh](https://docs.aws.amazon.com/eks/latest/userguide/agents-mesh.html) |
| Authenticated ingress and the chat UI | `enable_ingress`, `enable_chat_ui` | [Ingress](https://docs.aws.amazon.com/eks/latest/userguide/agents-ingress.html) |
| Telemetry and dashboards | `enable_observability` | [Observability](https://docs.aws.amazon.com/eks/latest/userguide/agents-observability.html) |
| Checkpoints and session cache | `enable_checkpoints`, `enable_session_state` | [Session state](https://docs.aws.amazon.com/eks/latest/userguide/agents-session-state.html) |
| Semantic recall and consolidation | `enable_semantic_recall`, `enable_consolidation` | [Memory](https://docs.aws.amazon.com/eks/latest/userguide/agents-memory.html) |
| Release gate and online evaluation | `enable_evaluations`, `enable_online_evaluation` | [Evaluations](https://docs.aws.amazon.com/eks/latest/userguide/agents-evaluations.html) |
| Third-party API credentials | `oauth2_providers`, `api_key_providers` (AWS services); `third_party_credentials` (open source) | [Third-party credentials](https://docs.aws.amazon.com/eks/latest/userguide/agents-third-party-credentials.html) |

Each root module's `example.tfvars` describes every option.

## How the paths differ

| Layer | Open source | AWS services |
|---|---|---|
| Egress gateway | AgentGateway, in the cluster | Amazon Bedrock AgentCore Gateway |
| Gateway policy | AgentGateway policies | Policy in Amazon Bedrock AgentCore |
| Third-party credentials | AWS Secrets Manager, synced to AgentGateway | AgentCore Identity |
| Observability | Prometheus, Grafana, and Langfuse | Amazon CloudWatch and AWS X-Ray, through the ADOT collector |
| Session state | Valkey | Amazon ElastiCache Serverless for Valkey |
| Semantic recall | pgvector | Amazon S3 Vectors |
| Consolidation | Mem0, on pgvector | AgentCore Memory |
| Evaluations | Strands Evals, with grades in Langfuse | Strands Evals for release gates, AgentCore Evaluations |
| Service mesh | Istio in ambient mode, off by default | Istio in ambient mode, off by default |

Both paths use the same agent image. Without a gateway, an agent calls Claude Sonnet 5.5 in Amazon Bedrock directly, with its own role. Through AgentCore Gateway, the AWS services path uses `bedrock/openai.gpt-oss-120b`, because the gateway's catalog has no Claude Sonnet model. [AI agents on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/agents.html) compares the paths at each layer.

## Repository layout

| Directory | Contents |
|---|---|
| [`terraform/`](terraform) | The two root modules, `open-source` and `aws-services`, and their modules. It holds everything that's an AWS API call. |
| [`gitops/`](gitops) | Every Kubernetes object, including the base chart (namespaces, network policy, admission, the `Agent` resource definition), the root chart for each path, whose templates are the component Applications, the bootstrap objects, and [`examples/`](gitops/examples). |
| [`apps/`](apps) | The workloads: the reference agent (built as `reasoning` and `reasoning-direct`), the MCP server, the chat UI, the consent receiver, and the evaluation runner. |
| [`scripts/`](scripts) | `validate.sh`, `apply.sh`, `exercise.sh`, `teardown.sh`, `bootstrap-gitops.sh`, `build-images.sh`, `run-stack.sh`, `check-endpoint.sh`, `set-credential.sh`, `open-dashboard.sh`, `gitops-mirror.sh`, `render-example.sh`, and test fixtures. |

Terraform writes one values file for each path, `gitops/platform/<path>/terraform-values.yaml`. The charts read every ARN, endpoint, and name from it, so you don't copy an ARN into a manifest by hand. Each directory has its own README.

## Deploy

[Cluster setup](https://docs.aws.amazon.com/eks/latest/userguide/agents-cluster-setup.html) in the User Guide has the full procedure. The following steps summarize it. Run them from the `agents` directory of your clone (`git clone https://github.com/aws-samples/sample-eks-docs.git && cd sample-eks-docs/agents`), with `<path>` set to `open-source` or `aws-services`.

Before you start, you need the following:

- An IAM Identity Center instance and a user in it, for Argo CD.
- Amazon Bedrock access to Claude Sonnet 5.5 in us-east-1, us-east-2, and us-west-2, the Regions that the default US inference profile routes to. `direct_model_id` changes the model.
- Terraform 1.9 or later, the AWS CLI v2, `kubectl`, Python 3, Git, `jq`, and `curl`. With the default bastion, you also need the AWS Systems Manager Session Manager plugin for the AWS CLI.

1. Set the base variables and apply. `minimal.tfvars` holds the base setup's variables, and `example.tfvars` describes every option. [Defaults](terraform/README.md#defaults) lists the ones to tighten outside a test. `scripts/apply.sh` runs `terraform apply`, and stops when a plan would replace a stateful or security resource.

   ```bash
   (cd terraform/<path> && cp minimal.tfvars my.tfvars)   # set the marked values
   terraform -chdir=terraform/<path> init
   ./scripts/apply.sh --root terraform/<path> -var-file=my.tfvars
   terraform -chdir=terraform/<path> output next_steps
   ```
2. Build the agent images and install the in-cluster components. The images build in the stack's AWS CodeBuild project, so this step needs only the AWS CLI. `scripts/run-stack.sh` runs a command where the cluster is reachable, on the bastion with the default private endpoint, or on this machine in workstation mode.

   ```bash
   ./scripts/build-images.sh --root terraform/<path>
   ./scripts/run-stack.sh --root terraform/<path> -- ./scripts/bootstrap-gitops.sh --path <path> --sync
   ```
3. Apply your first `Agent`, as described in [Deploy an agent](https://docs.aws.amazon.com/eks/latest/userguide/agents-application-setup.html). `terraform output agent_model_arns` prints the list for its `modelArns` field. Then run `./scripts/exercise.sh --path <path>` to check every layer that's on.
4. To turn on a layer, set its variable, apply, and sync again. `--roll-agents` recreates each agent pod whose `Sandbox` changed, and `--prune` removes a component you turned off.

   ```bash
   ./scripts/run-stack.sh --root terraform/<path> -- \
     ./scripts/bootstrap-gitops.sh --path <path> --sync --roll-agents
   ```

### Where the stack's code and values come from

Argo CD reads the stack's code from this repository, [aws-samples/sample-eks-docs](https://github.com/aws-samples/sample-eks-docs), at the revision `gitops_repo_revision` names, `main` by default. To control when a change to the repository reaches your cluster, set it to a commit. Nothing from your account goes to any repository. Terraform renders your stack's values into files beside the root chart (`gitops/platform/<path>/*-values.yaml`), and `bootstrap-gitops.sh` passes them to the cluster in the root Application. An edit to one of those files, such as a release-gate case in `agent-evals-values.yaml`, reaches the cluster on the next sync. Don't commit the rendered files, because they contain your account ID and other values from your stack.

To run templates you've changed, fork this repository on GitHub, commit your changes to a branch of the fork, and point the stack at it:

```hcl
gitops_repo_url      = "https://github.com/my-org/sample-eks-docs.git"
gitops_repo_revision = "my-changes"   # your branch, tag, or commit
gitops_repo_path     = "agents/"
```

Argo CD reads a public fork with no credential. A fork of a public repository is public, so don't commit anything that names your account, such as an `Agent` manifest with your image URL.

For files that must stay private, such as your `Agent` manifests, use a private repository. Give Argo CD access to it through an AWS CodeConnections connection in `argocd_codeconnections_arns`, or through a credential in AWS Secrets Manager in `argocd_secrets_manager_secret_arns`. `scripts/gitops-mirror.sh` creates and pushes a CodeCommit repository instead, which needs no stored credential:

```bash
./scripts/gitops-mirror.sh create --name my-agents --region us-west-2   # prints gitops_repo_url and argocd_codecommit_repository_arns
./scripts/gitops-mirror.sh push --name my-agents --region us-west-2     # this directory's committed tree, to branch my-agents
```

Then set `gitops_repo_url` and `argocd_codecommit_repository_arns` to the lines it printed, `gitops_repo_path = ""` and `gitops_repo_revision = "my-agents"`, and apply. Argo CD syncs only from the repositories that the `eks-agents` AppProject lists, which are the stack's repository and the chart repositories that the components use. To sync `Agent` manifests from a different repository, add it to `argocd_extra_source_repos`.

### Run everything from your workstation

By default, the API endpoint is private and the bastion is the only way in. To run every step in this README and the User Guide from your own machine instead, set the following variables.

```hcl
cluster_endpoint_public_access = true    # the endpoint, open only to this machine's address
enable_bastion                 = false   # refused unless the endpoint is public
ingress_scheme                 = "internet-facing"   # only with enable_ingress; needs ingress_public_zone_id
```

The commands in Deploy don't change. `scripts/run-stack.sh` runs a command on the stack's bastion when there is one. Otherwise it runs the command on this machine, with a kubeconfig for this root module's cluster only. `exercise.sh`, `build-images.sh --root`, and `teardown.sh --root` call it themselves. The ingress load balancer is internet-facing, and its security group admits HTTPS only from `ingress_allowed_cidrs`, or from the endpoint's allowlist when that list is empty. Its names resolve in a public zone delegated from `ingress_public_zone_id`.

Terraform doesn't create that zone, so it's the one prerequisite you set up by hand. You need a public Route 53 hosted zone for a domain you control. Either [register a domain with Route 53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/domain-register.html), which creates the zone, or create a public hosted zone for a domain or subdomain you already own and add its four name servers as NS records at your registrar. Before you apply, check the delegation with `dig +short NS <domain> @8.8.8.8`. Set `ingress_domain_name` to a subdomain of that zone, such as `agents.example.com`. Terraform creates the agents' zone under it and delegates it.

The allowlist is the only way in. When your public address changes, every call times out. Apply again from the new address, then wait a few minutes while EKS rolls the change out. On a corporate network or VPN that sends traffic from several public addresses, name those addresses' CIDRs in `cluster_endpoint_public_access_cidrs`. If your network uses addresses you can't name, keep the bastion, or apply from a connection with one public address. To find the cause, run `./scripts/check-endpoint.sh --root terraform/<path>`. It prints the allowlist, this machine's address as two lookup services see it, and whether the endpoint answers.

[Cluster setup](https://docs.aws.amazon.com/eks/latest/userguide/agents-cluster-setup.html#agents-cluster-prerequisites) lists the full prerequisites. The stack's resources incur charges while they exist, including the cluster, NAT gateways, the bastion, and any managed service you turn on.

## Verify

`scripts/exercise.sh` checks each layer against the live cluster. Each check sends a request or reads the cluster's state, and the script reports a layer that's off as skipped. Run it from your workstation. It runs each phase through `scripts/run-stack.sh`, so the phases run on the bastion when the stack has one.

```bash
./scripts/exercise.sh --path aws-services            # every phase
./scripts/exercise.sh --path aws-services model      # one phase
```

The script's phases are `prereqs`, `identity`, `model`, `tools`, `chat`, `state`, `session`, `memory`, `containment`, `egress`, `mesh`, `telemetry`, `ingress`, `signin`, and `evals`, and its header describes each one. The exit status is the number of phases that failed.

`scripts/validate.sh` runs the checks that don't need an account. It checks formatting, chart renders on both paths, manifests, and placeholders, and fails when a value from your account is committed. Run it before every commit. To run it as a pre-commit hook, run `git config core.hooksPath .githooks` once in each clone.

## Clean up

`scripts/teardown.sh` deletes what `terraform destroy` leaves behind, such as load balancers, ECR images, and AgentCore log groups, and then checks the account for anything left. Without `--yes`, it's a dry run.

```bash
./scripts/teardown.sh --path <path> --cluster my-agents --region us-west-2 \
  --root terraform/<path> --cluster-going-away
./scripts/teardown.sh --path <path> --cluster my-agents --region us-west-2 \
  --root terraform/<path> --cluster-going-away --yes --destroy-with my.tfvars
```

A CodeCommit repository that you created with `gitops-mirror.sh` isn't part of the stack, so delete it yourself. The teardown reports it while it exists.

```bash
./scripts/gitops-mirror.sh delete --name my-agents --region us-west-2
```

The Clean up section of [Cluster setup](https://docs.aws.amazon.com/eks/latest/userguide/agents-cluster-setup.html) explains each step.

## Further reading

* [Deploy an agent](https://docs.aws.amazon.com/eks/latest/userguide/agents-application-setup.html): every field of the `Agent` resource, and the smallest agent that works.
* [VERSIONS.md](VERSIONS.md): component versions and the date each was checked.
