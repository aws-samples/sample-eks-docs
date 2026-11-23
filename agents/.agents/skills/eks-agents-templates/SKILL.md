---
name: eks-agents-templates
description: Find your way around these templates and change them safely. Covers where each piece lives, how one Terraform variable reaches the cluster, the checklist for each kind of change (a variable, a layer, the Agent resource, an exercise.sh check), how to verify a change before and after a live run, and the known traps in this code. Use when adding or changing a feature, fixing a defect a live run turns up, reviewing a change, or answering "where does X come from" about this repository. To run the User Guide's steps against it, use eks-agents-user-guide instead.
---

# Navigate and change these templates

Read `AGENTS.md` first. It holds the rules this skill assumes:

- nothing done by hand stays out of the code;
- nothing from an account is committed;
- changes arrive as pull requests, reviewed before they merge;
- `scripts/validate.sh` passes before anything is done;
- version-dependent claims go in `VERSIONS.md`;
- observed beats reasoned;
- a check that can't fail isn't a check;
- a teardown is verified, not declared.

This skill is the map and the method that go with those rules. Paths are relative to the repository root.

## Where things live

Each directory has its own README that is the authority for it. Read it before you change anything there.

| Directory | What it is | Read first |
|---|---|---|
| `terraform/open-source/`, `terraform/aws-services/` | The two root modules. `variables.tf` holds every reader-facing option, with validation. `main.tf` holds the wiring and the rendered files. | `terraform/README.md` |
| `terraform/modules/` | One module per AWS concern, shared by both roots where the concern is the same: `agent-cluster`, `network`, `bastion`, `ingress`, `person-access`, `platform-secrets`, `egress-agentgateway`, `egress-agentcore`, `memory-aws` and the rest | the module's `README.md`, or its `variables.tf` and `main.tf` where it has none |
| `gitops/bootstrap/<path>/` | The cluster secret, the AppProject and the root Application. They're templates that Terraform renders to `*.local.yaml`. | `gitops/README.md` |
| `gitops/platform/<path>/` | A Helm chart whose `templates/` are the platform's Argo CD Applications, one file per component, rendered by the root Application with the stack's values. A file in `excluded` isn't rendered; the values files Terraform writes sit beside `Chart.yaml`. `alternatives/` is not part of the chart. | `gitops/platform/<path>/README.md` |
| `gitops/base/` | The chart for every cluster-wide control and the `Agent` API: namespaces, admission policies, network policies, the NodeClass, the resource graph definition (`templates/40-agent-rgd.yaml`, with the pod in `_agent-pod.tpl`) | `gitops/base/README.md` |
| `gitops/charts/` | Charts for components with no usable upstream chart: `agentgateway-config`, `platform-secrets`, `agent-evals`, `agent-dashboards`, `adot-collector`, `mem0`, `consent-receiver` | the chart's README |
| `gitops/examples/` | Objects a reader applies by hand on a guide page, rendered with `scripts/render-example.sh` | `gitops/examples/README.md` |
| `apps/` | The reference agent (`reference/`), shared code (`common/`), the MCP server, the chat UI, the evaluation runner, and unit tests (`tests/`) | `apps/README.md` |
| `scripts/` | Everything a reader runs (`apply.sh`, `gitops-mirror.sh`, `bootstrap-gitops.sh`, `run-stack.sh`, `build-images.sh`, `exercise.sh`, `teardown.sh`, `check-endpoint.sh`). Also what CI runs (`validate.sh`, with its checks in `lib/check_*.py`). | the script's header comment |
| `VERSIONS.md` | Every pinned version, and the claims to recheck before publishing | the file |

## How one variable reaches the cluster

Trace any feature through these links. A change that skips one renders cleanly and does nothing, which is the failure this repository is built to avoid.

1. **`variables.tf`** in the root declares it, with a `validation` block that refuses combinations that can't work. For example, an internet-facing load balancer without a public zone, or the delegated token without the gateway.
2. **`main.tf`** uses it in three places:
   - the AWS resources, often a module's `count`;
   - `local.platform_excluded`, rendered into the root Application's `excluded` list, so the platform chart doesn't render a component that's off;
   - the values written to `gitops/platform/<path>/terraform-values.yaml` by `local_file.gitops_values`.
   A few components get their own rendered file (`collector-values.yaml`, `external-dns-values.yaml`). `agent-evals-values.yaml` is edited by hand, because the release-gate cases are reviewed like code.
3. **`bootstrap-gitops.sh --sync`** applies the root Application with every `gitops/platform/<path>/*-values.yaml` folded into its `helm.values` (`scripts/lib/root-app.sh`). The values reach the cluster only that way; nothing account-specific is committed. The code the Applications run comes from `gitops_repo_url` at `gitops_repo_revision`, so a change to any other file under `gitops/` reaches the cluster only once it's at that revision. Argo CD reads only Git for code.
4. **The root Application** renders the platform chart: one child Application per template that isn't excluded. Order comes from each file's `argocd.argoproj.io/sync-wave`, from `-14` for the Istio namespace up to `0`, not from the file name.
5. **The chart** gets `terraform-values.yaml`'s content as its `helm.values`, over its own `values.yaml`. A chart's `fail` guards refuse to render against the committed placeholder.
6. **For a per-agent setting**, the `Agent` resource graph definition reads the platform's values as defaults and composes the agent's objects: its service account, IAM role and Pod Identity association through ACK, its network policy, its `Sandbox` or Deployment, and its Service and route.

**Turning a layer off is the same path in reverse.** The Terraform variable decides whether the component is synced. The chart value only configures it. `scripts/lib/check_layer_toggles.py` fails the build when the two can disagree.

## Checklists by kind of change

### A new variable on an existing feature

- Add it to `variables.tf` in each root the feature exists in, with a description that says what it does and what it costs. Add a validation for every value that can't work.
- Pass it through `main.tf` to the module, the rendered values, or both. Never have a chart read an account value from anywhere except the rendered values.
- Add it to `example.tfvars`, commented.
- Run `terraform -chdir=terraform/<root> validate` and `./scripts/validate.sh`. The render check renders the chart against the values Terraform writes, not just the placeholder.

### A new layer, a component a reader turns on

- **The variable:** one variable in each root that offers it, off by default.
- **The platform files:** a file in `gitops/platform/<path>/` with its Application or Applications, a sync wave that puts it after what it needs, and `prune: false` on anything that holds data or CRDs.
- **The excluded list:** an entry in `local.platform_excluded` in `main.tf`, and the matching entry in `scripts/lib/check_layer_toggles.py`'s `LAYERS`. The platform file goes in `gitops/platform/<path>/templates/`, wrapped in the same `if not (has ...)` as the others.
- **Secrets:** if the component reads a Secret, it comes from `module.platform_secrets`. The Application syncs exactly when the module syncs some secret (`module.platform_secrets[*].in_use`), so don't keep a separate list of readers.
- **Network policy:** the egress rule the agents need, in `gitops/base`. If other pods must reach it, the component's own ingress policy. With the mesh on, allow port 15008 (HBONE) too.
- **exercise.sh:** a phase that asserts the component refuses what it should, registered in `ALL_PHASES` and the dispatch at the end of `scripts/exercise.sh`.
- **Teardown:** anything a controller creates outside Terraform must be found by `scripts/teardown.sh` and reported by its sweep.
- **The design record:** a section in the component's README covering the design and what it costs. Pinned versions and recheck claims go in `VERSIONS.md`.
- **The User Guide:** open an issue that names the User Guide page the layer needs. The guide follows this code.

### The `Agent` API

- A new field goes in `templates/40-agent-rgd.yaml`'s schema with a default from the platform values where one makes sense. Its effect goes in the composed objects, or in `_agent-pod.tpl` for the pod.
- A value an application team mustn't choose belongs to the platform, not the schema.
- If a field can be misused, add or extend the admission policy (`41-admission-agent-runtime.yaml`).
- kro needs RBAC for every kind it composes (`35-kro-rbac.yaml`). Without it, the Agent can report healthy while the object is silently absent.
- Open an issue for the agents-application-setup page of the EKS User Guide, which documents every field.
- Check the readiness the Agent reports (`readyWhen`). An Agent must not read `ACTIVE` while its pod was refused.

### An `exercise.sh` check

- Assert the refusal, not the success: the wrong caller refused, the unlisted host refused, the other person refused.
- A check that can't run on this cluster `skip`s and says why. A check that ran and saw the wrong thing `fail`s. A check that can't tell which must fail, never skip, because a skip reads like a pass in a summary.
- Phases run where `run-stack.sh` puts them: on the bastion, or on the workstation (`RUN_STACK_WHERE`). A check that needs the VPC must work from both. For an internal load balancer from a workstation, `exercise.sh` uses a short-lived probe pod.
- Every line a guide page quotes is a contract. If you reword a `pass` line, the page that quotes it has to change too.

## Verify a change

1. **Locally:**
   - `./scripts/validate.sh`: Terraform format and validate, Helm lint and render on both paths, the posture checks, the layer-toggle and mesh-mode checks, the no-account-values check, and cross-references.
   - `terraform -chdir=terraform/<root> validate` for each root you touched.
   - The unit tests in `apps/tests/` for agent code.
2. **A read-only plan:** to see a Terraform condition's effect, run `terraform plan -refresh=false -lock=false` with a throwaway variables file, in a gitignored location. A plan creates nothing.
3. **Live:** apply on a test cluster, following the guide page the change touches, with the `eks-agents-user-guide` skill. Use `scripts/apply.sh`, never a bare `terraform apply`. Record the observed result in the pull request's description.
4. **Fix the class, not the line.** When a live run finds a defect, look for every sibling site with the same shape, and prefer a change that removes the class. Deriving a list from the data that defines it beats keeping it by hand.

5. **Open a pull request.** Fork the repository, make the change on a branch, and open a pull request with `./scripts/validate.sh` passing and the live result from step 3. Keep every value from an account out of it.

## Known traps in this code

Each of these gives a result that looks right and isn't, or stops a deployment partway.

- **Pod and namespace shape:**
  - A `Sandbox` doesn't replace its running pod when its spec changes, so a feature that adds an environment variable needs a roll.
  - A Service named `chat-ui` injects `CHAT_UI_PORT` into every pod in the namespace, and that overrides the app's own setting.
  - AgentGateway speaks MCP to a Service port only when the port declares `appProtocol: agentgateway.dev/mcp`.
- **Argo CD:**
  - One unknown API group in an Application's manifests fails the whole sync, not just that object.
  - Helm `lookup` returns nothing under Argo CD's render, so a generated secret built on it rotates on every sync.
  - A `Replace=true` sync option wipes a webhook's injected `caBundle`.
  - The EKS capability drops `ignoreMissingValueFiles: false` after applying it, so an Application that sets it never reads Synced.
  - A cluster-scoped object in the root Application, such as a Namespace, never reads Synced. Give it its own child Application.
- **Network policy:**
  - In a `ClusterNetworkPolicy`, the action is `Accept`, not `Allow`. A cluster-tier `Accept` ends evaluation, so it overrides every namespaced policy.
  - With the mesh on, the application port is inside the HBONE tunnel on 15008, so a policy that admits only the application port breaks meshed traffic.
- **Istio:**
  - A default-deny `AuthorizationPolicy` must be `ALLOW` with no rules. A catch-all `DENY` overrides every allowlist.
  - ztunnel doesn't capture a Nitro sandbox pod's traffic. The pod's annotation and the workload table say otherwise; only the access log tells the truth.
  - Istio CNI doesn't work as the sidecar redirect in a Nitro sandbox, which is part of why there's no sidecar mode.
- **AgentGateway:**
  - A traffic policy with no `phase` runs PostRouting, and a route-level `jwtAuthentication` replaces the Gateway-level one. To verify two tokens on one route, move the first to `phase: PreRouting`.
  - S3 needs `x-amz-content-sha256`, which the gateway's signer doesn't add.
- **IAM:**
  - A tagged `AssumeRole` is authorized as `sts:AssumeRole` plus `sts:TagSession`, and `sts:RoleSessionName` is absent for `TagSession`, so the trust needs two statements.
  - `iam simulate-custom-policy` allows cases that IAM refuses, so test trust conditions live.
- **Scripts:**
  - Bash on macOS is 3.2: no associative arrays, and an empty array is unbound under `set -u`. Write `${a[@]+"${a[@]}"}`.
  - Never edit a script while it runs, because bash reads it as it goes.
  - `terraform apply` rewrites `terraform-values.yaml` with the account's values, and `validate.sh`'s no-account-values check then fails on the working tree. Restore the placeholder before you open a pull request: `git checkout gitops/platform/<path>/terraform-values.yaml`.
- **Teardown:** deleting the capabilities while Agents exist leaves each agent's IAM role behind. A label-selector delete that matches nothing exits 0. Count what's left.

## Writing about it

- **READMEs** are the design record. They hold the design and what it costs, stated as the end state, with no history of earlier names.
- **Comments** carry the evidence for a non-obvious line: the log line or the error.
- **The User Guide** follows the code, and it leaves out problems the automation already solves. When a change alters a reader-visible step, an output a page quotes, or a default, say in the pull request what changed and which page quotes it.
