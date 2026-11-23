# Pinned versions

Every version this repository pins, and where it is pinned.

Nothing here tracks `latest`. A moving tag on a component that enforces an egress boundary or issues
an identity is a change to the platform's security properties arriving without a review.

## Kubernetes and the cluster

| Component | Version | Where |
|---|---|---|
| EKS control plane | 1.36 | `var.kubernetes_version`, both root modules and `modules/agent-cluster` |
| kubectl on the bastion | v1.36.6 | `var.bastion_kubectl_version`, both root modules and `modules/bastion`; within one minor of the control plane |
| Terraform | >= 1.9 | every `versions.tf` |
| AWS provider | ~> 6.73 | every `versions.tf` |
| hashicorp/awscc provider | ~> 1.110 | both root modules, `modules/person-delegation`, `modules/person-delegation-agentcore` |
| hashicorp/random provider | ~> 3.9 | both root modules, `modules/memory-aws`, `modules/platform-secrets` |
| hashicorp/tls provider | ~> 4.4 | both root modules, `modules/ingress` |
| hashicorp/time provider | ~> 0.14 | both root modules, `modules/agent-cluster`, `modules/egress-agentcore`, `modules/evaluations-aws` |
| hashicorp/http, local providers | ~> 3.6, ~> 2.9 | root modules only |

Every `versions.tf` that names a provider pins it to the same constraint. A working directory
initialized under older pins needs `terraform init -upgrade` once, because its
`.terraform.lock.hcl` holds a release the new constraint excludes.

Validated against live clusters on Kubernetes **1.36.4** (platform version **eks.14**) and **1.37.1** (platform version **eks.7**).

## Upstream projects

| Component | Version | Where |
|---|---|---|
| Gateway API (standard channel) | v1.7.0 | `gitops/platform/*/10-gateway-api-crds.yaml` |
| Agent Sandbox | v1.0.10 | `gitops/platform/*/40-agent-sandbox.yaml` (chart values, CRDs and templates unchanged from v1.0.9) |
| KEDA (chart and app) | 2.21.0 | `gitops/platform/*/13-keda.yaml` — shipped **off** (`enable_agent_tasks`) |
| AgentGateway (chart and app) | v1.7.0 | `gitops/platform/open-source/templates/30-agentgateway.yaml` |
| AgentGateway CRDs (separate chart) | v1.7.0 | `gitops/platform/open-source/templates/29-agentgateway-crds.yaml` |
| Istio (base, cni, istiod, ztunnel) | 1.31.4 | `gitops/platform/open-source/templates/20-istio.yaml` |
| kube-prometheus-stack | 92.21.1 | `gitops/platform/open-source/templates/50-observability.yaml` |
| opentelemetry-collector | 0.178.2 | `gitops/platform/open-source/templates/50-observability.yaml` |
| opentelemetry-operator | 0.129.0 | `gitops/platform/aws-services/templates/50-adot.yaml` |
| ADOT collector image | v0.44.0 | `gitops/charts/adot-collector/templates/collector.yaml` |
| Langfuse | 2.2.3 | `gitops/platform/open-source/templates/51-langfuse.yaml` — shipped **off** |
| cert-manager (open source, for the ClickHouse operator) | v1.19.1 | `gitops/platform/open-source/templates/51-langfuse.yaml` |
| clickhouse-operator-helm | 0.0.8 | `gitops/platform/open-source/templates/51-langfuse.yaml` (OCI, `ghcr.io/clickhouse`) |
| Valkey (Bitnami chart) | 6.3.13 | `gitops/platform/open-source/templates/60-memory.yaml` — see the caveat below |
| secrets-store-csi-driver | 1.6.2 | `gitops/platform/open-source/templates/45-platform-secrets.yaml` |
| secrets-store-csi-driver-provider-aws | 3.1.4 | same file |
| strands-agents-evals | 1.9.0 | `apps/evals/requirements.txt` |
| langfuse (Python SDK) | 3.15.0 | `apps/evals/requirements.txt` |
| mem0ai | 2.2.1 | `apps/reference/requirements.txt` — consolidation (`enable_consolidation`), shipped **off**; the latest PyPI release when pinned |
| mem0-strands | 0.1.1 | same file; needs strands-agents >= 1.45 (`strands.memory`) |
| psycopg / psycopg-pool | 3.3.9 / 3.3.3 | same file; Mem0's pgvector driver |
| CloudNativePG cluster image | 17.6-standard-bookworm | `gitops/platform/open-source/templates/61-semantic-recall.yaml` — the managed role `agent_memory` lives here too |

kro and ACK are **not** pinned here. Both arrive as EKS Capabilities, so AWS owns their version;
`aws_eks_capability` reports it as a computed `version` attribute. That is the point of taking them
as capabilities.

## Caveats on specific pins

**Valkey / Bitnami.** Bitnami changed its distribution model in 2025: the public catalogue carries
only the `latest` tag of each image, and the versioned tags a pinned chart references moved to the
`bitnamilegacy` repository or behind Bitnami Secure Images. So a pinned chart version can resolve to
an image tag that is not public, and the symptom is `ImagePullBackOff` on a chart that rendered
cleanly. Check before syncing; `gitops/platform/open-source/templates/60-memory.yaml` carries the command and
three ways out, the first of which is to take the managed cache instead.

**AgentGateway CRDs are a separate chart.** `cr.agentgateway.dev/charts/agentgateway` carries no
`crds/` directory, so the two charts are pinned together and the CRDs sync first. Bump them as a
pair: the controller watches every kind in the CRD chart, including `AgentgatewayModel` and
`AgentgatewayParameters` which this stack does not configure, so a version skew leaves it waiting on
a kind it cannot find.

**Agent Sandbox extensions.** `SandboxTemplate`, `SandboxWarmPool` and `SandboxClaim` are a separate
API surface from the core `Sandbox` CRD and have moved faster. Read the release notes on a bump, not
just the version number.

**Istio ambient.** Pin to a version the chart repo actually publishes, not to a GitHub release tag:
a chart pin taken from the GitHub API fails at install with `no chart version found` when the two
diverge. The charts come from `https://blob.istio.io/istio-release/charts` and the images from
`docker.io/istio` (`hub` and `global.hub`, set explicitly so the images do not depend on the charts' default registry). Istio
retires `registry.istio.io`, `gcr.io/istio-release` and `istio-release.storage.googleapis.com` on
2026-12-16 and switches them off in announced windows before then
(istio.io/latest/blog/2026/retirement-of-gcp). Check with
`helm search repo istio/base --versions` against the new repository.

1.31.4, not 1.30.x: 1.30 reaches end of life on 2026-12-16 and istio.io lists only 1.30.8 and later
as free of known CVEs; 1.31 supports Kubernetes 1.32 through 1.37 (end of life about 2027-03). The
ztunnel CIDR-lookup fix the capture layer needs is in 1.31.2 and later (`4b6b046`, the release-1.31
backport #2156), so 1.31.2 is the floor for this pin.

The three charts plus ztunnel are pinned together on purpose. Mixing minor
versions across `istio-cni`, `istiod` and `ztunnel` is unsupported, and on this stack a capture layer
that silently stops capturing is an egress boundary that silently stops enforcing.

## Schema provenance

Where the field shapes in this repository came from, since several are newer than their
documentation.

| Schema | How it was verified |
|---|---|
| `ClusterNetworkPolicy` (`networking.k8s.aws/v1alpha1`) | Read from the shipped CRD on a live Auto Mode 1.36 cluster. The documented example is ingress-only; the `action` enum is `Accept\|Deny\|Pass` with no `Allow`, and egress `to` peers accept `domainNames`. Neither is inferable from the documentation. |
| `ApplicationNetworkPolicy` | The EKS User Guide's worked example, confirmed by server-side apply on a live cluster |
| `Sandbox`, `SandboxTemplate`, `SandboxWarmPool`, `SandboxClaim` | CRDs installed from the v1.0.9 release on a live cluster; v1.0.10's are identical |
| `ResourceGraphDefinition` (`kro.run/v1alpha1`) | The kro EKS Capability on a live cluster, including a probe confirming CEL `join()` is available |
| ACK `Role` (`iam.services.k8s.aws/v1alpha1`), `PodIdentityAssociation` (`eks.services.k8s.aws/v1alpha1`) | The ACK EKS Capability on a live cluster; both resources reconciled real AWS objects |
| `AgentgatewayBackend`, `AgentgatewayPolicy` (`agentgateway.dev/v1alpha1`) | Server-side apply against the pinned v1.7.0 CRDs on a live EKS Auto Mode 1.37 cluster: every object both charts render was accepted, including `ai.groups`, `policies.auth.aws.assumeRole.tags`, `backend.health` and `traffic.retry`. Validation was confirmed to be enforcing rather than absent by two rejections — a backend setting both `provider` and `groups` ("exactly one of the fields in [provider groups] must be set") and duplicate provider names in one group. The Go types were read from master, so field *presence* at v1.7.0 is what this row establishes; it does not establish runtime behaviour |
| `NodeClass` (`eks.amazonaws.com/v1`) | Read from the CRD on a live cluster, for the `networkPolicy` enum and its default |
| `ValidatingAdmissionPolicy` | Applied to a live cluster; the CEL expressions compile and the denials were exercised |
| Every AWS resource | `terraform providers schema -json` against the AWS provider the `~> 6.73` constraint resolves to, and `terraform plan` on both root modules |

## Recheck before publishing

Claims in this tree that are true of a version rather than of the design, and will go stale without
anything here changing. Check each one before publishing this tree or linking it from
documentation, and again whenever the provider pin moves.

### 1. `aws_ssoadmin_instance` — creating the Identity Center instance

**The claim:** the AWS provider cannot create an IAM Identity Center instance, so turning on the
managed Argo CD needs one manual `aws sso-admin create-instance` call. Stated in the README
prerequisites, both `minimal.tfvars` files, and the comment and precondition in
`terraform/modules/agent-cluster/main.tf`.

**Status:** absent from the latest 6.x release that `~> 6.73` resolves to, and from provider `main`
(`website/docs/r/ssoadmin_instance.html.markdown` is a 404 while its siblings are not). **In
flight:** [hashicorp/terraform-provider-aws#45878](https://github.com/hashicorp/terraform-provider-aws/issues/45878)
requests it; [PR #49456](https://github.com/hashicorp/terraform-provider-aws/pull/49456) implements
it (open).

```bash
# Released?
curl -s -o /dev/null -w '%{http_code}\n' \
  https://raw.githubusercontent.com/hashicorp/terraform-provider-aws/main/website/docs/r/ssoadmin_instance.html.markdown
# 200 means it is in main. Then confirm it is in a release:
terraform -chdir=terraform/open-source providers schema -json \
  | python3 -c 'import json,sys; print("aws_ssoadmin_instance" in json.load(sys.stdin)["provider_schemas"]["registry.terraform.io/hashicorp/aws"]["resource_schemas"])'
```

**If it has landed**, this step stops being manual, and the change is contained:

- create the instance in `terraform/modules/agent-cluster/main.tf`, behind a variable, because it is
  an account-level resource — `enable_argocd` alone should not create one silently
- drop the `create-instance` wording from the capability's precondition, keeping the precondition for
  the case where the operator opted out of creating one
- update the README prerequisite, the [AI agents on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/agents.html) page of
  the EKS User Guide and both `minimal.tfvars`, which currently present the call as unavoidable

### 2. Gateway rate limits on the managed path

**The claim:** there is no `aws_bedrockagentcore_gateway_rate_limit`, so a per-agent token budget on
the aws-services path needs the CLI. The pin is `~> 6.73`, so any 6.x release from 6.73 on can be
the one in use. Recheck against the release the constraint resolves to
(`terraform providers schema -json`, as in item 1), and delete the limitation if the resource exists.

### 3. The Istio fail-closed message

**The claim:** an `AuthorizationPolicy` whose L7 conditions ztunnel cannot evaluate reports a
misleading status before Istio **1.32.0**, and an accurate one from 1.32.0 (istio/istio#61126,
PR #61166, not backported). The mesh notes carry it. If the pin moves to 1.32+, the "silent" half
of that finding stops applying and the wording should say so.

### 4. One verified JWT per request on AgentGateway

**The claim:** an `AgentgatewayPolicy` validates one JWT per phase, and a route-level
`jwtAuthentication` replaces the Gateway-level one rather than adding to it. So a person's token
cannot be checked beside the agent's own without dropping the agent check. Stated as a limitation
of delegating a person's authority, on the
[agents-identity-on-behalf-of](https://docs.aws.amazon.com/eks/latest/userguide/agents-identity-on-behalf-of.html) page of the EKS User
Guide. **Reasoned from the v1.7.0 CRD schema and its field descriptions; not run.**

```bash
helm pull oci://cr.agentgateway.dev/charts/agentgateway-crds --version <ver> --untar
python3 -c 'import sys,yaml; d=next(x for x in yaml.safe_load_all(open(sys.argv[1])) if x)
print(sorted(d["spec"]["versions"][0]["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["traffic"]["properties"]["jwtAuthentication"]["properties"]))' \
  agentgateway-crds/templates/agentgateway.dev_agentgatewaypolicies.yaml
# v1.7.0: ['location', 'mcp', 'mode', 'preserveToken', 'providers']. A location per provider, or a
# second named JWT in CEL, would change the answer.
```

### 5. The agent-sandbox MCP server's connection types

**The claim:** every `K8S_SANDBOX_CONNECTION__TYPE` the upstream MCP server accepts reaches the
sandbox over the network, so it cannot drive a `network-isolated` sandbox. Stated in
`gitops/examples/warm-pool/README.md`. **Checked against v1.0.10 source.**

```bash
git clone -q --depth 1 --branch <ver> https://github.com/kubernetes-sigs/agent-sandbox.git as
grep -n 'K8S_SANDBOX_CONNECTION__TYPE' as/clients/integrations/mcp-server/README.md
# v1.0.10: gateway, direct, in-cluster, sandboxd-in-cluster. A type that uses pods/exec would let the
# server drive this stack's execution tier, and the README section would become a recommendation.
```

### 6. The `eks:managed` grant for direct OIDC

**The claim:** EKS Auto Mode's managed gateway controller reads an `authenticate-oidc` client secret
as the `AWSServiceRoleForAmazonEKS` service-linked role. That role's access policies grant no
Secret access, so `gitops/base/templates/47-ingress-oidc.yaml` binds a one-Secret Role to the
group `eks:managed`, which the role's access entry declares. Stated there and on the
[agents-ingress](https://docs.aws.amazon.com/eks/latest/userguide/agents-ingress.html) page of the EKS User Guide. **Verified** on
Kubernetes 1.37.1, platform eks.7: no status without the grant, `accepted: true` with it. AWS documents the
pattern in https://docs.aws.amazon.com/eks/latest/userguide/auto-managed-rbac.html.

Two things could change it. AWS could add Secret access to `AmazonEKSLoadBalancingClusterPolicy`,
which would make the grant redundant. AWS could drop or rename the `eks:managed` group, which would
make the grant inert while it still renders.

```bash
# The group, on a cluster of yours:
aws eks describe-access-entry --cluster-name <cluster> \
  --principal-arn "arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS" \
  --query accessEntry.kubernetesGroups
# ["eks:managed"]. Empty, or another name: the RoleBinding subject has to follow it.

# Whether the managed policy now covers Secrets (the docs page lists its permissions):
#   https://docs.aws.amazon.com/eks/latest/userguide/access-policy-permissions.html#_amazoneksloadbalancingclusterpolicy
# If it does, 47-ingress-oidc.yaml can go -- after confirming an authenticate-oidc rule reaches
# accepted: true on a cluster without it.
```

### 7. What Strands Evals reads and writes

**The claims**, read from the strands-agents-evals 1.9.0 source, and each one is
something `apps/evals/runner.py` depends on:

- `LangfuseProvider` and `CloudWatchProvider` fetch a session by the span attribute `session.id`.
  The reference agent sets it for that reason.
- `LangfuseProvider` reads through the Langfuse v3 API (`api.trace.list`, `api.observations.get_many`),
  which Langfuse 4 in `events_only` mode -- what the pinned chart 2.2.3 runs, server 4.75.0 --
  answers with 404. The runner therefore reads `GET /api/public/v2/observations` itself and uses only
  the provider's converter. When Strands Evals ships a Langfuse 4 provider, `langfuse_v4_provider`
  in `apps/evals/runner.py` can go.
- Strands Evals writes NO score back to Langfuse. The runner does, with `create_score(session_id=)`
  from the Langfuse 3.x SDK -- which silently does nothing if the SDK's tracing is disabled.
- The AgentCore result writer is `telemetry/_cloudwatch_logger.py`, documented in its own header as
  **temporary, to be removed once ADOT integration is complete**. It is turned on by
  `AGENT_OBSERVABILITY_ENABLED`, writes to `/aws/bedrock-agentcore/evaluations/results/<EVALUATION_RESULTS_LOG_GROUP>`,
  needs `service.name` in `OTEL_RESOURCE_ATTRIBUTES`, and swallows every failure at debug level --
  so a missing permission or variable produces no results and no error.
- A task that raises is recorded as score 0 / `test_pass` false. The runner counts those as
  execution failures instead of publishing them.
- The Langfuse SDK attaches its exporter to the global tracer provider and keeps one resource
  manager per public key. The runner relies on that to keep its own spans out of Langfuse.

Any of these can change in a minor release. Re-read the five files the claims come from when the pin
moves -- `providers/{langfuse,cloudwatch}_provider.py`, `telemetry/_cloudwatch_logger.py`,
`experiment.py` -- and run `apps/tests/test_evals_runner.py`, which asserts the last three.

### 8. What kro and Agent Sandbox do not do, that the Agent resource relies on

**The claims**, verified on EKS's kro capability and Agent Sandbox v1.0.9:

- kro's ResourceGraphDefinition schema has **no cross-field validation**: `kubectl explain
  resourcegraphdefinitions.kro.run.spec.schema` lists no `validation` field, and one written there is
  dropped on apply. So "a Sandbox runs one replica" is a ValidatingAdmissionPolicy
  (`gitops/base/templates/41-admission-agent-runtime.yaml`).
- A Sandbox propagates only podTemplate labels and annotations to its running pod; any other change
  waits for the pod to be recreated (upstream `api/v1beta1/sandbox_types.go`, and verified on a cluster).
- Upstream `failedPodPolicy` defaults to `Retain`, which leaves an evicted pod down; the Agent sets
  `Recreate`.

Either can change: kro may add schema validation (the policy could then move into the graph), and
Agent Sandbox may start rolling a Sandbox's pod on a template change (the delete step on the
[agents-application-setup](https://docs.aws.amazon.com/eks/latest/userguide/agents-application-setup.html) page of the EKS User Guide
would then be unnecessary).

### 9. AgentCore Gateway target behaviours this tree works around

**The claims**, all verified on a live gateway, each with a workaround in
`terraform/modules/egress-agentcore`:

- `CreateGatewayTarget` rejects an empty `credentialPrefix`, so an api_key credential with no prefix
  omits the field. If the API starts accepting `""`, the `== "" ? null` guards are harmless.
- An OpenAPI target whose schema declares a `text/plain` response is accepted by the create call and
  settles `FAILED`. Supported: `application/json`, `application/xml`, `multipart/form-data`,
  `application/x-www-form-urlencoded`. Stated in `open_api_targets`' description.
- An EXTERNAL api_key or OAuth2 provider is read at call time with the GATEWAY's role, so that role
  needs `secretsmanager:GetSecretValue` on the operator's own secret, not only on
  `bedrock-agentcore*`. If AgentCore starts reading external secrets with a service identity, the
  extra grant becomes unnecessary but stays harmless.

```bash
# The prefix: create a scratch api_key target with credentialPrefix "" and read the error.
# The media type: create a scratch OpenAPI target with a text/plain response, then
aws bedrock-agentcore-control get-gateway-target --gateway-identifier <gw> --target-id <t> \
  --query '[status,statusReasons]'
```

### 10. What AgentCore online evaluation needs from an agent's spans

**The claims**, verified on a live online evaluation configuration:

- Traces are grouped into sessions by the `session.id` span attribute. Spans without it, with every
  `gen_ai` attribute present, produced no result while the configuration read `ACTIVE`/`ENABLED`.
  `apps/reference/app.py` sets it through Strands' `trace_attributes`.
- The conversation has to reach `aws/spans`. Strands records it as span EVENTS, and the
  collector's `awsxray` exporter (ADOT collector v0.44.0) drops events when it converts spans to
  segment documents. `gitops/charts/adot-collector` sends traces to X-Ray's OTLP endpoint instead,
  which keeps them.

```bash
# Events present on the agent's spans in aws/spans?
aws logs filter-log-events --log-group-name aws/spans --filter-pattern '"<session id>"' \
  --query 'events[].message' --output text | grep -c gen_ai.user.message
```

- Session discovery is a Logs Insights query over `aws/spans` and the configured groups together,
  filtering `resource.attributes.aws.service.type = "gen_ai_agent"` and the service names, over the
  last five minutes, every five minutes. So the role needs `StartQuery` on `aws/spans` too, the
  agent needs that resource attribute (the AWS distro sets it; the plain SDK does not), and a
  session missed in its window is not picked up later. Read from the evaluation role's CloudTrail.

Recheck if the awsxray exporter starts carrying span events, evaluation derives a session from the
trace id, or the discovery query stops filtering on `aws.service.type`.

## Bumping a version

1. Change the pin.
2. `./scripts/validate.sh`.
3. For anything in the egress or identity path — Istio, AgentGateway, the network policy CRDs — re-run
   the enforcement check in the README. A component can render, lint, sync and report healthy while
   enforcing nothing, and that is the failure mode this stack is most exposed to.
