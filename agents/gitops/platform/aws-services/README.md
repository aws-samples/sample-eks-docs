# Platform Applications (aws-services)

A Helm chart whose templates are the platform's Argo CD Applications on the AWS services path, one file per component in `templates/`. The root Application in [`gitops/bootstrap/aws-services/`](../../bootstrap/aws-services) renders this chart; read this to find which file installs a component and which Terraform variable turns it on.

A file whose layer is off is left out by the chart's `excluded` list, which Terraform renders from `platform_excluded` in `terraform/aws-services/main.tf`. Each file's header says what the component does and what it costs.

| File | Applications (sync wave) | Synced when |
|---|---|---|
| `00-base.yaml` | `eks-agents-base` (-10): the [base chart](../../base) | Always |
| `10-gateway-api-crds.yaml` | `gateway-api-crds` (-12) | `enable_ingress` |
| `12-external-dns.yaml` | `external-dns` (-5): the agents' DNS records | `enable_ingress` |
| `40-agent-sandbox.yaml` | `agent-sandbox` (-11): the Agent Sandbox controller | Always |
| `45-cert-manager.yaml` | `cert-manager` (-6): certificates for the OpenTelemetry operator's webhooks | `enable_observability` |
| `45-platform-secrets.yaml` | `secrets-store-csi-driver-provider-aws` (-2), `platform-secrets` (-1): the direct OIDC client secret, projected into the `ingress` namespace | `enable_ingress` with `ingress_idp = "oidc-direct"` |
| `46-consent-receiver.yaml` | `consent-receiver` (3): AgentCore Gateway's OAuth consent session binding | `enable_gateway` and a client in `agentcore_consent` |
| `50-adot.yaml` | `opentelemetry-operator` (-1), `adot-collector` (1) | `enable_observability` |
| `52-agent-evals.yaml` | `agent-evals` (4): the Strands Evals release gate | `enable_evaluations` |
| `54-istio-namespace.yaml` | `istio-namespace`: the `istio-system` Namespace (from `istio-namespace/`), ahead of the Istio Applications | `mesh_mode` isn't `"none"` |
| `55-istio.yaml` | `istio-base` (-13), `istio-cni` (-3), `istiod` (-2), `ztunnel` (-1) | `mesh_mode` isn't `"none"` |

[ISTIO-DECISION.md](ISTIO-DECISION.md) explains what the mesh adds on this path, where the network policy already makes AgentCore Gateway the only reachable destination.

## Values files

The `*-values.yaml` files are not chart templates. `scripts/bootstrap-gitops.sh` folds each one into the root Application's `helm.values` under its own key (`terraform`, `collector`, `externalDns`, `agentEvals`), and the Applications pass it on to their charts as `helm.values`. Your rendered copies go to no repository: the root Application is the only way they reach the cluster.

| File | Read by | Written by |
|---|---|---|
| `terraform-values.yaml` | Every Application that renders a chart from this repository | `terraform apply`. The copy in the repository holds placeholders the charts refuse to render against. |
| `external-dns-values.yaml` | `external-dns` in `12-external-dns.yaml` | `terraform apply`, with `enable_ingress` |
| `agent-evals-values.yaml` | `52-agent-evals.yaml` | You: the release gate's agents and cases, and the runner image tag. Read after `terraform-values.yaml`, so it overrides it. |

## Sync order

Sync waves order the start of each Application's sync, not its completion; every Application carries a short `retry`, which is what converges one that started before its dependency was ready. The base Application sets `SkipDryRunOnMissingResource=true`, so a manifest whose CRD isn't registered yet retries on its own instead of failing the whole sync. Applications that install CRDs sync with `prune: false`; delete a resource you remove from their manifests by hand.
