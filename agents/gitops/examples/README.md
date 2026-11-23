# Examples

Each directory is one complete, applyable pattern for agents on Amazon EKS. Argo CD doesn't apply them: nothing in `gitops/platform/` references this directory, so an example reaches the cluster only when you apply it.

## Examples

| Order | Example | What it shows |
|---|---|---|
| 1 | [`mcp-server/`](mcp-server) | The reference MCP server, and how each path reaches it. Apply it first after an agent, so `tools/list` returns tools. |
| 2 | [`reasoning-execution-split/`](reasoning-execution-split) | A two-tier agent: a reasoning tier that reaches a model, and an execution tier with no network device for model-written code. |
| 3 | [`inbound-callers/`](inbound-callers) | Who may call an agent: the agent's own token check, the workload gate at ingress, and the Layer 4 mesh policy for unsandboxed workloads. |
| 4 | [`mcp-ingress/`](mcp-ingress) | A hand-written route on the shared ingress Gateway, gated by `jwt-validation` for an MCP client. |
| 5 | [`chat-ui/`](chat-ui) | The operator chat UI and the sign-in gate in front of it. Rendered by the base chart, not applied from this directory. |
| 6 | [`warm-pool/`](warm-pool) | Agent Sandbox warm pools, claims, and suspend and resume, with the RBAC a reasoning tier needs to drive them. |

Examples 1 through 3 are the core path: a tool call, containment, and delegation. Examples 4 through 6 each answer a narrower question.

## Prerequisites

* A cluster from either Terraform root, with the base chart and the platform synced. See [Cluster setup](https://docs.aws.amazon.com/eks/latest/userguide/agents-cluster-setup.html).
* The agent images in ECR, built with `./scripts/build-images.sh --root terraform/<path>`.
* A shell that reaches the cluster's private API endpoint, which is the bastion. Run the commands in these READMEs from the repository root there, or wrap one from your workstation with `./scripts/run-stack.sh --root terraform/<path> -- bash -c '<command>'`.

Every workload in an agent namespace sets `runtimeClassName: isolated-sandbox`, which the admission policy requires. [Application setup](https://docs.aws.amazon.com/eks/latest/userguide/agents-application-setup.html) in the EKS User Guide describes each field of the `Agent` resource that the examples set.

## Apply an example

Manifests that carry placeholders for your account, Region, cluster, OIDC issuer, or image URIs are applied through `scripts/render-example.sh`, which fills them from the `gitops/platform/<path>/terraform-values.yaml` file the apply wrote:

```bash
./scripts/render-example.sh gitops/examples/mcp-server/mcp-server.yaml aws-services | kubectl apply -f -
```

The second argument is the path, `open-source` (the default) or `aws-services`. The script also does the following:

* Names `agents/reasoning` for an agent's image when the platform has a gateway (`gateway.enabled`), and `agents/reasoning-direct` when it doesn't, so the agent calls Amazon Bedrock with its own role.
* Replaces the `:v1` tag on `agents/` images with `IMAGE_TAG`, when you set it, for images you rebuilt with `build-images.sh --tag`.
* Fills `guardrailArn` from `GUARDRAIL_ARN`, or drops the line when `GUARDRAIL_ARN` is unset.
* Sets `expose: route` on the Agents you name in `EXPOSE_ROUTE` (for example, `EXPOSE_ROUTE=research`).
* Renders the MCP server's path-specific lines; see [`mcp-server/`](mcp-server).

Anything only you know, such as a session name or your identity provider's endpoints, stays a placeholder, and the script lists it on stderr. Stdout stays pipeable into `kubectl`.

## Verify an example

`scripts/exercise.sh` has a phase for each example. The `tools` phase covers `mcp-server/`, `containment` covers the execution tier in `reasoning-execution-split/`, `chat` and `signin` cover `chat-ui/`, and `ingress` covers the routes `mcp-ingress/` shows. A phase creates the short-lived fixtures it needs, such as the execution-tier probe in `containment`, and reports a skip when the agents it tests aren't there.

```bash
./scripts/exercise.sh --path aws-services tools containment
```
