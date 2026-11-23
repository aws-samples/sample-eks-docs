# AI agents on Amazon EKS: reference sample

Terraform and GitOps templates for running AI agents on Amazon EKS. They're the reference sample for the [AI agents on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/agents.html) section of the Amazon EKS User Guide, and every command in that section runs from this directory. Start with the guide; this README covers what the guide doesn't: the repository's layout, its scripts, and how to change it.

This is a reference sample: it shows one way to run agents on Amazon EKS, and it isn't a production-ready deployment. Before you rely on it, review its defaults (see [Defaults](terraform/README.md#defaults)), its security controls, and its cost against your own requirements, and adapt it to them.

The platform comes in two paths that share one cluster design:

* The *open source path* runs the gateway, memory, observability, and evaluation components in your cluster.
* The *AWS services path* uses Amazon Bedrock AgentCore, Amazon ElastiCache, Amazon S3 Vectors, and Amazon CloudWatch for the same layers.

Both paths deploy an EKS Auto Mode cluster with a private API endpoint, Nitro Sandbox isolation, network policy in three tiers, a per-agent IAM role through EKS Pod Identity, and the EKS Capabilities for Argo CD, kro, and ACK. On both, one `Agent` resource onboards an agent.

## What the base includes

The base is a cluster that can run a sandboxed agent, and nothing more. Every other layer is a Terraform variable that's off until you turn it on.

| Layer | Variable | User Guide page |
|---|---|---|
| Cluster, network policy, ECR, permissions boundary, bastion | the base | [Cluster setup](https://docs.aws.amazon.com/eks/latest/userguide/agents-cluster-setup.html) |
| Argo CD, kro, ACK, and the platform components | `enable_argocd` (on in the base) | [EKS Capabilities](https://docs.aws.amazon.com/eks/latest/userguide/agents-capabilities-setup.html) |
| Egress gateway | `enable_gateway` | [Gateway](https://docs.aws.amazon.com/eks/latest/userguide/agents-gateway.html) |
| Service mesh | `mesh_mode` | [Mesh](https://docs.aws.amazon.com/eks/latest/userguide/agents-mesh.html) |
| Authenticated ingress and the chat UI | `enable_ingress`, `enable_chat_ui` | [Ingress](https://docs.aws.amazon.com/eks/latest/userguide/agents-ingress.html) |
| Telemetry and dashboards | `enable_observability` | [Observability](https://docs.aws.amazon.com/eks/latest/userguide/agents-observability.html) |
| Checkpoints and session cache | `enable_checkpoints`, `enable_session_state` | [Session state](https://docs.aws.amazon.com/eks/latest/userguide/agents-session-state.html) |
| Semantic recall and consolidation | `enable_semantic_recall`, `enable_consolidation` | [Memory](https://docs.aws.amazon.com/eks/latest/userguide/agents-memory.html) |
| Release gate and online evaluation | `enable_evaluations`, `enable_online_evaluation` | [Evaluations](https://docs.aws.amazon.com/eks/latest/userguide/agents-evaluations.html) |
| Third-party API credentials | `oauth2_providers`, `api_key_providers` (AWS services); `third_party_credentials` (open source) | [Third-party credentials](https://docs.aws.amazon.com/eks/latest/userguide/agents-third-party-credentials.html) |

Each root module's `example.tfvars` has every option annotated.

## How the paths differ

| Layer | Open source | AWS services |
|---|---|---|
| Egress gateway | AgentGateway, in the cluster | Amazon Bedrock AgentCore Gateway |
| Gateway policy | AgentGateway policies, per route | Cedar policy engine |
| Observability | Prometheus, Grafana, Langfuse | CloudWatch GenAI Observability |
| Session cache | Valkey | Amazon ElastiCache Serverless |
| Semantic recall | pgvector | Amazon S3 Vectors |
| Consolidation | Mem0, on pgvector | AgentCore Memory |
| Evaluations | Strands Evals, grades in Langfuse | AgentCore Evaluations, and a Strands Evals release gate |
| Third-party credentials | Brokered from AWS Secrets Manager | AgentCore credential providers |

The agent image is the same on both paths. Without a gateway, agents call Amazon Bedrock directly with their own role and Claude Sonnet 5.5. Through AgentCore Gateway, the AWS services path uses `bedrock/openai.gpt-oss-120b`, because the gateway's catalog has no Claude Sonnet model. [AI agents on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/agents.html) covers the trade at each layer.

## Deploy

The User Guide is the procedure. In outline, from this directory of a clone of [sample-eks-docs](https://github.com/aws-samples/sample-eks-docs) (`git clone https://github.com/aws-samples/sample-eks-docs.git && cd sample-eks-docs/agents`), where `<path>` is `open-source` or `aws-services`. The base cluster is the same on both; they differ in whether the gateway, memory, observability and evaluation layers run in your cluster or as AWS managed services ([How the paths differ](#how-the-paths-differ)):

Before you start: an IAM Identity Center instance and a user in it, for Argo CD; access to Claude Sonnet 5.5 in Amazon Bedrock in us-east-1, us-east-2 and us-west-2 (the US inference profile; `direct_model_id` changes it); and Terraform 1.9 or later, the AWS CLI v2, `kubectl`, Python 3, Git, `jq` and `curl`. With the default bastion, also the Session Manager plugin for the AWS CLI.

1. Set the base variables and apply. `minimal.tfvars` is the base; `example.tfvars` has every option annotated, and [Defaults](terraform/README.md#defaults) lists the ones to tighten outside a test. `scripts/apply.sh` is `terraform apply` with a guard that stops a plan replacing a stateful or security resource:

   ```bash
   (cd terraform/<path> && cp minimal.tfvars my.tfvars)   # set the marked values
   terraform -chdir=terraform/<path> init
   ./scripts/apply.sh --root terraform/<path> -var-file=my.tfvars
   terraform -chdir=terraform/<path> output next_steps
   ```
2. Build the agent images (in the stack's AWS CodeBuild project, so this needs only the AWS CLI), and install the platform. `scripts/run-stack.sh` runs a command where the cluster is reachable: on the bastion with the default private endpoint, or here in the workstation mode below:

   ```bash
   ./scripts/build-images.sh --root terraform/<path>
   ./scripts/run-stack.sh --root terraform/<path> -- ./scripts/bootstrap-gitops.sh --path <path> --sync
   ```
3. Apply your first `Agent`, as in [Deploy an agent](https://docs.aws.amazon.com/eks/latest/userguide/agents-application-setup.html). `terraform output agent_model_arns` is its `modelArns` list. Then `./scripts/exercise.sh --path <path>` checks every layer that is on.
4. Turn on each layer you need: set its variable, apply, and sync again. `--roll-agents` recreates each agent pod whose `Sandbox` changed, and `--prune` removes a component you turned off:

   ```bash
   ./scripts/run-stack.sh --root terraform/<path> -- \
     ./scripts/bootstrap-gitops.sh --path <path> --sync --roll-agents
   ```

### Where the platform's code and your values come from

Argo CD installs the platform from this repository, [aws-samples/sample-eks-docs](https://github.com/aws-samples/sample-eks-docs), at the revision `gitops_repo_revision` names. Set it to a release tag or a commit, so a later change to the repository reaches your cluster only when you move it. Nothing from your account goes to any repository. Terraform renders your stack's values into files beside the platform chart (`gitops/platform/<path>/*-values.yaml`), and `bootstrap-gitops.sh` passes them to the cluster in the root Application. An edit to one of those files, such as a release-gate case in `agent-evals-values.yaml`, reaches the cluster on the next sync.

To run templates you've changed, push them to a repository of your own and point the stack at it. A CodeCommit repository needs no stored credential:

```bash
./scripts/gitops-mirror.sh create --name my-agents --region us-west-2   # prints gitops_repo_url and argocd_codecommit_repository_arns
./scripts/gitops-mirror.sh push --name my-agents --region us-west-2     # this directory's committed tree, to branch my-agents
```

Then set `gitops_repo_url` and `argocd_codecommit_repository_arns` to the lines it printed, `gitops_repo_path = ""` and `gitops_repo_revision = "my-agents"`, and apply. The same repository holds the `Agent` manifests you manage from Git (application setup, Step 6). Argo CD syncs only from the repositories the `eks-agents` AppProject lists: this one, and the chart repositories the platform reads. To sync `Agent` manifests from a different repository, add it to `argocd_extra_source_repos`.

### Run everything from your workstation

By default the API endpoint is private and the bastion is the only way in. To run every step here and in the EKS User Guide from your own machine instead, set:

```hcl
cluster_endpoint_public_access = true    # the endpoint, open only to this machine's address
enable_bastion                 = false   # refused unless the endpoint is public
ingress_scheme                 = "internet-facing"   # only with enable_ingress; needs ingress_public_zone_id
```

The commands above stay as written. `scripts/run-stack.sh` runs a command on the stack's bastion when it has one, and on this machine, against a kubeconfig for this root's cluster alone, when it does not. `exercise.sh`, `build-images.sh --root` and `teardown.sh --root` go through it themselves. The ingress load balancer is internet-facing, behind a security group that admits HTTPS from `ingress_allowed_cidrs` only (empty means the endpoint's allowlist), and its names resolve in a public zone delegated from `ingress_public_zone_id`.

That zone is the one manual prerequisite: a public Route 53 hosted zone for a domain you control, which Terraform does not create. Either [register a domain with Route 53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/domain-register.html), which creates the zone, or create a public hosted zone for a domain or subdomain you already own and add its four name servers as NS records at your registrar. Check the delegation with `dig +short NS <domain> @8.8.8.8` before you apply. `ingress_domain_name` must be a subdomain of that zone, such as `agents.example.com`; Terraform creates and delegates the agents' zone under it.

The allowlist is the only way in. When your public address changes, which happens on a VPN or on a network that sends traffic out through a rotating pool of NAT addresses, every call times out. Apply again from the new address, then wait a few minutes while EKS rolls the change out. On such a network, name the pool's CIDRs in `cluster_endpoint_public_access_cidrs`, or keep the bastion. `./scripts/check-endpoint.sh --root terraform/<path>` says which of these it is: it prints the allowlist, this machine's address as two lookup services see it, and whether the endpoint answers.

The full prerequisites are in [Cluster setup](https://docs.aws.amazon.com/eks/latest/userguide/agents-cluster-setup.html#agents-cluster-prerequisites). The resources incur charges while they exist, including the cluster, NAT gateways, the bastion, and any managed service you turn on.

## Verify

`scripts/exercise.sh` checks each layer against the live cluster. Every assertion sends a real request or reads real cluster state, and a layer that's off is reported as skipped. Run it from your workstation. It runs the phases through `scripts/run-stack.sh`, so on the bastion when the stack has one:

```bash
./scripts/exercise.sh --path aws-services            # every phase
./scripts/exercise.sh --path aws-services model      # one phase
```

The phases are `prereqs`, `identity`, `model`, `tools`, `chat`, `state`, `session`, `memory`, `containment`, `egress`, `mesh`, `telemetry`, `ingress`, `signin`, and `evals`. The script's header describes each one. The exit status is the number of failed phases.

`scripts/validate.sh` checks what can be checked without an account: formatting, chart renders on both paths, manifests, placeholders, and that no value from your account is committed. Run it before every commit, and turn on the pre-commit hook once per clone with `git config core.hooksPath .githooks`.

## Clean up

`scripts/teardown.sh` deletes what `terraform destroy` leaves behind, such as load balancers, ECR images, and AgentCore log groups, and sweeps the account for anything left. It's a dry run unless you pass `--yes`:

```bash
./scripts/teardown.sh --path <path> --cluster my-agents --region us-west-2 \
  --root terraform/<path> --cluster-going-away
./scripts/teardown.sh --path <path> --cluster my-agents --region us-west-2 \
  --root terraform/<path> --cluster-going-away --yes --destroy-with my.tfvars
```

If you created a CodeCommit repository with `gitops-mirror.sh`, it isn't part of the stack, so delete it yourself. The teardown's sweep reports it while it exists:

```bash
./scripts/gitops-mirror.sh delete --name my-agents --region us-west-2
```

The Clean up section of [Cluster setup](https://docs.aws.amazon.com/eks/latest/userguide/agents-cluster-setup.html) explains each step.

## Repository layout

| Directory | Contents |
|---|---|
| [`terraform/`](terraform) | The two root modules, `open-source` and `aws-services`, and their modules. Everything that's an AWS API call. |
| [`gitops/`](gitops) | Everything that's a Kubernetes object: the base chart (namespaces, network policy, admission, the `Agent` resource definition), the platform Applications per path, the bootstrap objects, and [`examples/`](gitops/examples). |
| [`apps/`](apps) | The workloads: the reference agent (built as `reasoning` and `reasoning-direct`), the MCP server, the chat UI, the consent receiver, and the evaluation runner. |
| [`scripts/`](scripts) | `validate.sh`, `exercise.sh`, `teardown.sh`, `bootstrap-gitops.sh`, `build-images.sh`, `run-stack.sh`, `gitops-mirror.sh`, `render-example.sh`, and test fixtures. |

Terraform writes one values file per path, `gitops/platform/<path>/terraform-values.yaml`, and the charts read every ARN, endpoint, and name from it, so no ARN is copied into a manifest by hand. Each directory has a README of its own.

## Further reading

* [Deploy an agent](https://docs.aws.amazon.com/eks/latest/userguide/agents-application-setup.html): every field of the `Agent` resource, and the smallest agent that works.
* [VERSIONS.md](VERSIONS.md): component versions and the date each was checked.

Both paths run on EKS Auto Mode, with Kubernetes 1.36 as the default version.
