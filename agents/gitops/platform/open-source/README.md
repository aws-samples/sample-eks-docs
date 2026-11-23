# Platform Applications (open-source)

A Helm chart whose templates are the platform's Argo CD Applications on the open source path, one file per component in `templates/`. The root Application in [`gitops/bootstrap/open-source/`](../../bootstrap/open-source) renders this chart; read this to find which file installs a component and which Terraform variable turns it on.

A file whose layer is off is left out by the chart's `excluded` list, which Terraform renders from `platform_excluded` in `terraform/open-source/main.tf`. Each file's header says what the component does and what it costs.

| File | Applications (sync wave) | Synced when |
|---|---|---|
| `00-base.yaml` | `eks-agents-base` (-10): the [base chart](../../base) | Always |
| `10-gateway-api-crds.yaml` | `gateway-api-crds` (-12) | `enable_gateway` or `enable_ingress` |
| `12-external-dns.yaml` | `external-dns` (-5): the agents' DNS records | `enable_ingress` |
| `19-istio-namespace.yaml` | `istio-namespace`: the `istio-system` Namespace (from `istio-namespace/`), ahead of the Istio Applications | `mesh_mode` isn't `"none"` |
| `20-istio.yaml` | `istio-base` (-13), `istio-cni` (-3), `istiod` (-2), `ztunnel` (-1), in ambient mode | `mesh_mode` isn't `"none"` |
| `29-agentgateway-crds.yaml` | `agentgateway-crds` (-1) | `enable_gateway` |
| `30-agentgateway.yaml` | `agentgateway` (0): the egress gateway | `enable_gateway` |
| `31-agentgateway-config.yaml` | `agentgateway-config` (1): its [configuration chart](../../charts/agentgateway-config) | `enable_gateway` |
| `40-agent-sandbox.yaml` | `agent-sandbox` (-11): the Agent Sandbox controller | Always |
| `45-platform-secrets.yaml` | `secrets-store-csi-driver-provider-aws` (-2), `platform-secrets` (-1): generated and synced secrets, projected from Secrets Manager | `enable_platform_secrets` (on by default) and a component that reads one: session state, observability, Langfuse, evaluations, consolidation, direct OIDC ingress, or `third_party_credentials` with the gateway |
| `46-consent-receiver.yaml` | `consent-receiver` (3): the OAuth consent receiver | `enable_gateway` and a client in `oauth_consent` |
| `50-observability.yaml` | `kube-prometheus-stack` (0), `opentelemetry-collector` (1), `agent-dashboards` (2) | `enable_observability` |
| `51-langfuse.yaml` | `cert-manager` (1), `clickhouse-operator` (2), `langfuse` (3) | `enable_langfuse` |
| `52-agent-evals.yaml` | `agent-evals` (4): online grading and the release gate | `enable_evaluations`, which needs `enable_langfuse` |
| `60-memory.yaml` | `agent-session-state` (0): Valkey | `enable_session_state` |
| `61-semantic-recall.yaml` | `cloudnative-pg` (2), `agent-semantic-recall` (3): pgvector | `enable_semantic_recall` |

Consolidation has no Application: `enable_consolidation` runs Mem0 as a library in the agent, on the pgvector tier, and needs `enable_semantic_recall`, `enable_gateway`, and `enable_platform_secrets`. [Memory for agents](https://docs.aws.amazon.com/eks/latest/userguide/agents-memory.html) covers each tier.

## Alternatives

`alternatives/` isn't under `templates/`, so the chart never renders anything in it. Move a file into `templates/` to use it:

* `alternatives/mem0-server/62-consolidation.yaml` runs a shared Mem0 server from the [mem0 chart](../../charts/mem0) instead of the library.

## Values files

The `*-values.yaml` files are not chart templates. `scripts/bootstrap-gitops.sh` folds each one into the root Application's `helm.values` under its own key (`terraform`, `collector`, `externalDns`, `agentEvals`), and the Applications pass it on to their charts as `helm.values`. Your rendered copies go to no repository: the root Application is the only way they reach the cluster.

| File | Read by | Written by |
|---|---|---|
| `terraform-values.yaml` | Every Application that renders a chart from this repository | `terraform apply`. The copy in the repository holds placeholders the charts refuse to render against. |
| `external-dns-values.yaml` | `external-dns` in `12-external-dns.yaml` | `terraform apply`, with `enable_ingress` |
| `collector-values.yaml` | `opentelemetry-collector` in `50-observability.yaml` | `terraform apply`, from `enable_langfuse`, so traces reach Langfuse when it's on |
| `agent-evals-values.yaml` | `52-agent-evals.yaml` | You: the release gate's agents and cases, and the runner image tag. Read after `terraform-values.yaml`, so it overrides it. |

## Sync order

Sync waves order the start of each Application's sync, not its completion; every Application carries a short `retry`, which is what converges one that started before its dependency was ready. The base Application sets `SkipDryRunOnMissingResource=true`, so a manifest whose CRD isn't registered yet retries on its own instead of failing the whole sync. Applications that install CRDs sync with `prune: false`; delete a resource you remove from their manifests by hand.
