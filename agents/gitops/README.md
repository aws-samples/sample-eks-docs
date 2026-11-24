# GitOps

This directory holds every Kubernetes object that the stack installs, and Argo CD delivers them. Use this README to find where a component is defined and how it reaches the cluster. Everything that's an AWS API call is in [`terraform/`](../terraform).

Argo CD runs as the EKS Capability for Argo CD, outside the cluster, so every Application names the destination `eks-agents` that [`bootstrap/<path>/cluster-secret.yaml`](bootstrap/aws-services/cluster-secret.yaml) registers. Terraform writes `platform/<path>/terraform-values.yaml`, and every chart here reads it as a second Helm values file, so you don't copy an account ID, ARN, or endpoint into a manifest by hand.

## Layout

| Directory | Contents | Applied by |
|---|---|---|
| [`bootstrap/aws-services/`](bootstrap/aws-services), [`bootstrap/open-source/`](bootstrap/open-source) | The cluster secret, the AppProject, and the root Application | `scripts/bootstrap-gitops.sh` |
| [`platform/aws-services/`](platform/aws-services), [`platform/open-source/`](platform/open-source) | The root chart for each path, with one file per component, each holding one or more Argo CD Applications | The root Application |
| [`base/`](base) | The chart for cluster-wide controls and the `Agent` resource definition | The `eks-agents-base` Application |
| [`charts/`](charts) | Charts for components with no usable upstream chart | The component Applications |
| [`examples/`](examples) | Agents and shapes you apply yourself | You |

## Bootstrap and sync

`scripts/bootstrap-gitops.sh --path <path>` applies the cluster secret, the AppProject, and the root Application, in that order, from the `*.local.yaml` files that `terraform apply` rendered. The root Application has no automated sync, so you start a sync for every change to the set of components.

| Flag | Effect |
|---|---|
| none | Applies the three bootstrap objects and stops. |
| `--sync` | Starts one sync of the root Application and waits up to 20 minutes for every Application to be Synced and Healthy. |
| `--sync --roll-agents` | After the sync, recreates each agent pod whose `Sandbox` changed. |
| `--sync --prune` | Deletes the child Applications of components you turned off, and what they installed. Without it, the script lists them as turned off but still running. |

## How components are turned on and off

Terraform renders the root Application's `exclude` glob from your variables, and Argo CD doesn't sync a file that the glob matches. The README for each path, [aws-services](platform/aws-services/README.md) and [open-source](platform/open-source/README.md), maps every file to the variable that turns it on. The root Application doesn't recurse, so `platform/open-source/alternatives/` is never synced.

Applications that install CRDs sync with `prune: false`, because pruning a CRD deletes every resource of that kind. A resource that you remove from one of their manifests stays on the cluster until you delete it.

## Charts

| Chart | What it installs | Application |
|---|---|---|
| [`adot-collector`](charts/adot-collector) | The ADOT collector's pipeline | `platform/aws-services/50-adot.yaml` |
| [`agent-dashboards`](charts/agent-dashboards) | Prometheus scrape targets, cost rules, and the Grafana dashboard | `platform/open-source/50-observability.yaml` |
| [`agent-evals`](charts/agent-evals) | The Strands Evals runner: online grading and the release gate | `52-agent-evals.yaml`, both paths |
| [`agentgateway-config`](charts/agentgateway-config) | AgentGateway's Gateway, backends, routes, and policies | `platform/open-source/31-agentgateway-config.yaml` |
| [`consent-receiver`](charts/consent-receiver) | The OAuth consent receiver | `46-consent-receiver.yaml`, both paths |
| [`mem0`](charts/mem0) | A Mem0 server | `platform/open-source/alternatives/mem0-server/62-consolidation.yaml`, not synced |
| [`platform-secrets`](charts/platform-secrets) | Kubernetes Secrets projected from AWS Secrets Manager | `45-platform-secrets.yaml`, both paths |

## Examples

[`examples/`](examples) holds seven shapes that you apply yourself, each with a README that says what it demonstrates and what it costs. They're outside `platform/`, so none of them reaches a cluster unless you apply it. Start with [`reasoning-execution-split/`](examples/reasoning-execution-split), the two-tier agent whose execution tier has no network device.

## Before you change anything here

Run `scripts/validate.sh`. It renders every chart against both paths and checks the output for placeholders, missing guards, and broken references, without a cluster or an AWS account. `scripts/exercise.sh` checks the same layers on a live cluster.
