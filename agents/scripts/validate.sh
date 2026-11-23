#!/usr/bin/env bash
#
# Everything that can be checked without an AWS account or a cluster.
#
#   ./scripts/validate.sh
#
# What it checks:
#   - every Terraform configuration is formatted and valid
#   - every Helm chart renders, on both paths, with realistic values
#   - every rendered manifest and every static YAML file parses
#   - no placeholder reaches a rendered manifest
#
# What it cannot check, and what has to be checked on a cluster instead:
#   - that the ClusterNetworkPolicy egress schema matches the CRD on the cluster. VERSIONS.md,
#     "Schema provenance", records where the field shapes come from; see also the banner in
#     gitops/base/templates/30-cluster-egress-policy.yaml.
#   - that network policies are enforced rather than accepted and ignored. Without the ConfigMap in
#     10-network-policy-controller.yaml every policy on the cluster is inert and looks fine.
#   - that the AgentGateway and Agent Sandbox CRDs on the cluster accept these objects. A render
#     cannot ask an API server; VERSIONS.md, "Schema provenance", records how each shape was checked.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$(pwd)

# The interpreter the checks run under. Override it to point the credential tests at a venv that has
# fastapi and pyjwt[crypto]:  PYTHON_BIN=.venv/bin/python ./scripts/validate.sh
PYTHON_BIN="${PYTHON_BIN:-python3}"

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
fails=0
checks=0

ok()   { checks=$((checks+1)); printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
bad()  { checks=$((checks+1)); fails=$((fails+1)); printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
step() { printf '\n== %s ==\n' "$1"; }

need() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '%serror%s: %s is required\n' "$RED" "$RESET" "$1" >&2
    exit 1
  }
}
need terraform
need helm
need python3

RENDER_DIR=$(mktemp -d)
trap 'rm -rf "$RENDER_DIR"' EXIT

# ---------------------------------------------------------------------------
step "Terraform format"
# ---------------------------------------------------------------------------

# Gitignored files are left out: a deployment's own *.tfvars sits in the root it applies, and is not
# this repository's to format.
unformatted=$( { terraform fmt -recursive -check -list=true terraform 2>&1 || true; } \
               | while read -r f; do git -C "$ROOT" check-ignore -q "$f" 2>/dev/null || echo "$f"; done)
if [[ -z "$unformatted" ]]; then
  ok "terraform fmt"
else
  bad "terraform fmt — run 'terraform fmt -recursive terraform':"
  printf '      %s\n' $unformatted
fi

# ---------------------------------------------------------------------------
step "Terraform validate"
# ---------------------------------------------------------------------------

for cfg in terraform/open-source terraform/aws-services; do
  (
    cd "$cfg"
    if terraform init -backend=false -input=false -no-color >/dev/null 2>&1 \
       && terraform validate -no-color >/dev/null 2>&1; then
      exit 0
    fi
    exit 1
  ) && ok "$cfg" || {
    bad "$cfg"
    (cd "$cfg" && terraform validate -no-color 2>&1 | sed 's/^/      /' | head -30)
  }
done

# ---------------------------------------------------------------------------
step "Helm lint"
# ---------------------------------------------------------------------------

for chart in gitops/base gitops/charts/*; do
  [[ -f "$chart/Chart.yaml" ]] || continue
  if helm lint "$chart" --quiet >/dev/null 2>&1; then
    ok "helm lint $chart"
  else
    bad "helm lint $chart"
    helm lint "$chart" 2>&1 | sed 's/^/      /' | head -20
  fi
done

# ---------------------------------------------------------------------------
step "Helm template, both paths"
# ---------------------------------------------------------------------------

# Values standing in for what Terraform renders. Every field the charts' fail guards check has to be
# here, which is the point: a guard that fires on realistic values is a guard that would fire in
# production.
cat > "$RENDER_DIR/oss-values.yaml" <<'YAML'
accountId: "111122223333"
region: us-west-2
cluster: agents-oss
path: open-source
oidcIssuerUrl: https://oidc.eks.us-west-2.amazonaws.com/id/EXAMPLE1234567890
mesh:
  # Rendered with the mesh ON, which is not the default (mesh_mode defaults to none on both paths),
  # so the Istio policy checks below have something to check. The aws fixture renders the default.
  mode: ambient
  trustDomain: cluster.local
gateway:
  namespace: agentgateway-system
storage:
  checkpointBucket: agents-oss-agent-checkpoints-111122223333
agentResource:
  enabled: true
  rolePath: /eks-agents/
  permissionsBoundaryArn: arn:aws:iam::111122223333:policy/eks-agents/agents-oss-agent-boundary
agents:
  research:
    namespace: agents
    serviceAccount: research
observability:
  collectorNamespace: opentelemetry-operator-system
  collectorServiceAccount: adot-collector
  collectorRoleArn: arn:aws:iam::111122223333:role/agents-oss-adot-collector
  telemetryLogGroup: /aws/eks/agents-oss/agents
destinations:
  github:
    host: api.github.com
    port: 443
    secretName: agentgateway-github
    secretKey: token
mcpServers:
  internal:
    host: mcp.internal.example.com
    port: 443
    path: /mcp
nodeClass:
  roleName: agents-oss-eks-node
  subnetIds: ["subnet-EXAMPLE1", "subnet-EXAMPLE2"]
  securityGroupIds: ["sg-EXAMPLE1"]
networkPolicy:
  kubernetesApiServiceIp: 10.100.0.1   # Terraform renders the service CIDR's first address
YAML

cat > "$RENDER_DIR/aws-values.yaml" <<'YAML'
accountId: "111122223333"
region: us-west-2
cluster: agents-aws
path: aws-services
oidcIssuerUrl: https://oidc.eks.us-west-2.amazonaws.com/id/EXAMPLE1234567890
mesh:
  mode: none
  trustDomain: cluster.local
gateway:
  hostname: agents-aws-agents.gateway.bedrock-agentcore.us-west-2.amazonaws.com
  # The model endpoint carries /inference/v1, which only exists once the gateway has an inference
  # target. The check below asserts that shape, because a bare hostname here reaches no model.
  modelEndpoint: https://agents-aws-agents.gateway.bedrock-agentcore.us-west-2.amazonaws.com/inference/v1
  mcpEndpoint: https://agents-aws-agents.gateway.bedrock-agentcore.us-west-2.amazonaws.com/mcp
model:
  # Required on this path: the gateway routes on the model name in the request body, and the
  # AgentCore connector advertises its own catalogue (bedrock/<provider>.<model>) rather than
  # Bedrock model ids, so there is no default that resolves. An agent rendered without it
  # authenticates correctly and then gets a 404 naming a model that does not exist.
  gatewayModelId: bedrock/openai.gpt-oss-120b
storage:
  checkpointBucket: agents-aws-agent-checkpoints-111122223333
agentResource:
  enabled: true
  rolePath: /eks-agents/
  permissionsBoundaryArn: arn:aws:iam::111122223333:policy/eks-agents/agents-aws-agent-boundary
observability:
  collectorNamespace: opentelemetry-operator-system
  collectorServiceAccount: adot-collector
  collectorRoleArn: arn:aws:iam::111122223333:role/agents-aws-adot-collector
  telemetryLogGroup: /aws/eks/agents-aws/agents
nodeClass:
  roleName: agents-aws-eks-node
  subnetIds: ["subnet-EXAMPLE1", "subnet-EXAMPLE2"]
  securityGroupIds: ["sg-EXAMPLE1"]
networkPolicy:
  kubernetesApiServiceIp: 10.100.0.1   # Terraform renders the service CIDR's first address
YAML

render() {
  local name=$1 chart=$2 values=$3 out=$4
  if helm template "$name" "$chart" -f "$chart/values.yaml" -f "$values" > "$out" 2>"$out.err"; then
    ok "helm template $chart ($name)"
    return 0
  fi
  bad "helm template $chart ($name)"
  sed 's/^/      /' "$out.err" | head -20
  return 1
}

render base-oss gitops/base            "$RENDER_DIR/oss-values.yaml" "$RENDER_DIR/base-oss.yaml" || true
render base-aws gitops/base            "$RENDER_DIR/aws-values.yaml" "$RENDER_DIR/base-aws.yaml" || true
render agwcfg   gitops/charts/agentgateway-config "$RENDER_DIR/oss-values.yaml" "$RENDER_DIR/agwcfg.yaml" || true
# EVERY OPTIONAL COMPOSITION ON at once: task agents, permission sets and person access. Each adds
# CEL to the Agent resource definition that the default render never reaches, and a CEL ternary
# left unquoted is a YAML error only a render with it on shows: the base chart fails to render on a
# cluster with tasks on while every default render here passes.
cat "$RENDER_DIR/oss-values.yaml" > "$RENDER_DIR/oss-all-values.yaml"
cat >> "$RENDER_DIR/oss-all-values.yaml" <<'YAML'
tasks:
  enabled: true
  agents: [reporter]
personAccess:
  enabled: true
  agents: [research]
  roleArnPrefix: arn:aws:iam::111122223333:role/eks-agents/agents-oss-
  bucket: agents-oss-person-data-111122223333
  issuer: https://cognito-idp.us-west-2.amazonaws.com/us-west-2_EXAMPLE
  clientIds: [apiclient, browserclient]
YAML
python3 - "$RENDER_DIR/oss-all-values.yaml" <<'PY'
import sys, yaml
p = sys.argv[1]; v = yaml.safe_load(open(p))
v.setdefault("agentResource", {})["permissionSets"] = {"orders-read": [], "tasks-reporter": ["agents"]}
yaml.safe_dump(v, open(p, "w"))
PY
render base-oss-all gitops/base "$RENDER_DIR/oss-all-values.yaml" "$RENDER_DIR/base-oss-all.yaml" || true
render adot     gitops/charts/adot-collector      "$RENDER_DIR/aws-values.yaml" "$RENDER_DIR/adot.yaml" || true
# The same collector with an evaluation on: Terraform renders observability.evaluationsReadSpans
# true with enable_evaluations or enable_online_evaluation, and the content has to stay.
python3 - "$RENDER_DIR/aws-values.yaml" "$RENDER_DIR/aws-evals-values.yaml" <<'PY'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1]))
v.setdefault("observability", {})["evaluationsReadSpans"] = True
yaml.safe_dump(v, open(sys.argv[2], "w"))
PY
render adot-evals gitops/charts/adot-collector "$RENDER_DIR/aws-evals-values.yaml" "$RENDER_DIR/adot-evals.yaml" || true

# ---------------------------------------------------------------------------
step "The collector strips prompt content by default and keeps it when an evaluation grades spans"
# ---------------------------------------------------------------------------
python3 - "$RENDER_DIR/adot.yaml" "$RENDER_DIR/adot-evals.yaml" <<'PY'
import sys, yaml

def pipelines(path):
    for d in yaml.safe_load_all(open(path)):
        if isinstance(d, dict) and d.get("kind") == "OpenTelemetryCollector":
            cfg = d["spec"]["config"]
            cfg = yaml.safe_load(cfg) if isinstance(cfg, str) else cfg
            return cfg["service"]["pipelines"]
    sys.exit(f"      ✗ {path}: no OpenTelemetryCollector")

failed = False
for path, want in ((sys.argv[1], True), (sys.argv[2], False)):
    p = pipelines(path)
    for name in ("traces", "logs"):
        has = "attributes/strip_content" in p[name]["processors"]
        if has != want:
            label = "default" if want else "evaluationsReadSpans=true"
            print(f"      ✗ {label}: the {name} pipeline {'lacks' if want else 'has'} attributes/strip_content")
            failed = True
sys.exit(1 if failed else 0)
PY
if [[ $? -eq 0 ]]; then ok "collector content stripping"; else bad "collector content stripping"; fi

# ---------------------------------------------------------------------------
step "Rendered manifests parse, and carry no placeholder"
# ---------------------------------------------------------------------------

python3 - "$RENDER_DIR" <<'PY'
import glob, os, sys, re

try:
    import yaml
except ImportError:
    print("      ! PyYAML not installed; skipping the parse check (pip install pyyaml)")
    sys.exit(0)

render_dir = sys.argv[1]

# Strings that must never survive into a rendered manifest. A placeholder here is not a cosmetic
# problem: ACCOUNT_ID in an IAM trust policy produces a role nothing can assume, and REPLACE in a
# hostname produces an egress rule that matches nothing.
placeholders = ["ACCOUNT_ID", "CLUSTER_NAME", "REGION_NOT_SET", "CLUSTER_NOT_SET",
                "ACCOUNT_ID_NOT_SET", "REPLACE"]

failed = False
for path in sorted(glob.glob(os.path.join(render_dir, "*.yaml"))):
    name = os.path.basename(path)
    if name.endswith(".err"):
        continue
    text = open(path, encoding="utf-8").read()
    try:
        docs = [d for d in yaml.safe_load_all(text) if d]
    except yaml.YAMLError as e:
        print(f"      ✗ {name}: {e}")
        failed = True
        continue

    kinds = {}
    for d in docs:
        if isinstance(d, dict) and "kind" in d:
            kinds[d["kind"]] = kinds.get(d["kind"], 0) + 1
    summary = ", ".join(f"{k}x{v}" for k, v in sorted(kinds.items()))
    print(f"      ✓ {name}: {len(docs)} docs ({summary})")

    for p in placeholders:
        for i, line in enumerate(text.splitlines(), 1):
            # Ignore comments: the templates discuss placeholders on purpose.
            if line.lstrip().startswith("#"):
                continue
            if p in line:
                print(f"      ✗ {name}:{i} placeholder {p!r} reached a rendered manifest: {line.strip()[:90]}")
                failed = True
                break

sys.exit(1 if failed else 0)
PY
if [[ $? -eq 0 ]]; then ok "rendered manifests"; else bad "rendered manifests"; fi

# ---------------------------------------------------------------------------
step "Workload security posture, on the manifests that actually get applied"
# ---------------------------------------------------------------------------
#
# The checks above prove a manifest parses and carries no placeholder. They say nothing about
# whether the pod it describes runs as root. This closes that, and it reads the RENDERED output
# plus the static YAML rather than the templates, because a scanner pointed at a template sees
# `{{ ... }}` where the answer should be and reports nothing -- a repository can pass a posture
# scan it never actually ran.
#
# It also walks pod templates EMBEDDED IN THE kro ResourceGraphDefinition. The agent workload --
# the one that matters most here -- is not a Deployment of its own; it is a template inside
# spec.resources[]. A scanner that walks only top-level kinds reports a clean repository while the
# only workload on the platform goes unchecked.

python3 - "$RENDER_DIR" <<'PY'
import glob, os, sys

try:
    import yaml
except ImportError:
    print("      ! PyYAML not installed; skipping the posture check (pip install pyyaml)")
    sys.exit(0)

render_dir = sys.argv[1]

# Workloads whose readOnlyRootFilesystem is deliberately false. Each entry names the reason and the
# file that argues it: a suppression that does not point at its own justification is a defect in
# waiting, because the next reader cannot tell a decision from an oversight.
ROOTFS_EXEMPT = {
    "Deployment/execution":
        "the execution tier exists to run code that writes files, and containment there is the "
        "absent network device and the sandbox kernel rather than the filesystem "
        "(gitops/examples/reasoning-execution-split/execution.yaml)",
}

def pod_specs(doc):
    kind = doc.get("kind")
    spec = doc.get("spec") or {}
    name = (doc.get("metadata") or {}).get("name", "?")
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "Job", "ReplicaSet"):
        t = (spec.get("template") or {}).get("spec")
        if t: yield f"{kind}/{name}", t
    elif kind == "Pod":
        yield f"Pod/{name}", spec
    elif kind == "CronJob":
        t = (((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec")
        if t: yield f"{kind}/{name}", t
    elif kind == "ResourceGraphDefinition":
        for r in spec.get("resources") or []:
            t = r.get("template") or {}
            if t.get("kind") in ("Deployment", "StatefulSet", "DaemonSet"):
                inner = ((t.get("spec") or {}).get("template") or {}).get("spec")
                if inner: yield f"RGD[{r.get('id')}]/{t['kind']}", inner

findings = []

def check(src, owner, pod):
    # Strategic-merge PATCH FRAGMENTS are not workloads. gitops/examples/mcp-server/caller-token.yaml
    # is "the patch to add to such an agent's Deployment": its container carries a volumeMount and
    # nothing else. Judged against a full workload's bar it produces five findings and no defect.
    # A fragment is recognisable by having no image to run.
    if not any(c.get("image") for c in (pod.get("containers") or [])):
        return

    psc = pod.get("securityContext") or {}
    if psc.get("runAsNonRoot") is not True:
        findings.append((src, owner, "-", "pod securityContext.runAsNonRoot is not true. Set it at "
                                          "the POD level so it covers every container, including "
                                          "ones added later"))

    for c in pod.get("containers") or []:
        cn = c.get("name", "?")
        csc = c.get("securityContext") or {}
        if (psc.get("seccompProfile") or csc.get("seccompProfile") or {}).get("type") != "RuntimeDefault":
            findings.append((src, owner, cn, "seccompProfile.type is not RuntimeDefault"))
        if csc.get("allowPrivilegeEscalation") is not False:
            findings.append((src, owner, cn, "allowPrivilegeEscalation is not false"))
        if "ALL" not in ((csc.get("capabilities") or {}).get("drop") or []):
            findings.append((src, owner, cn, "capabilities.drop does not include ALL"))
        if csc.get("readOnlyRootFilesystem") is not True and owner not in ROOTFS_EXEMPT:
            findings.append((src, owner, cn, "readOnlyRootFilesystem is not true, and no exemption "
                                             "with a reason is recorded in ROOTFS_EXEMPT above"))

    # A NETWORK PROBE ON A SANDBOXED POD IN ISTIO AMBIENT CRASH-LOOPS IT. tcpSocket and httpGet
    # probes on a pod with runtimeClassName: isolated-sandbox in an ambient namespace fail --
    #
    #   Startup probe failed: dial tcp <pod-ip>:8080: i/o timeout
    #   Liveness probe failed: Get "http://<pod-ip>:8080/healthz": context deadline exceeded
    #
    # -- and the container restarts in a loop while serving correctly. Ambient captures the kubelet's
    # connection, and the reply from the Nitro guest never comes back through the pod's network
    # namespace. The same pod outside ambient is Ready. The rule applies to every sandboxed pod rather
    # than only enrolled ones because enrolment is a namespace label any later change can add, and
    # exec probes work in both cases: the runtime runs them inside the container.
    rc = pod.get("runtimeClassName") or ""
    if rc.endswith("-sandbox"):
        for c in pod.get("containers") or []:
            for probe in ("startupProbe", "livenessProbe", "readinessProbe"):
                for net in ("tcpSocket", "httpGet", "grpc"):
                    if net in (c.get(probe) or {}):
                        findings.append((src, owner, c.get("name", "?"),
                            f"{probe} uses {net} on a {rc} pod. Under Istio ambient the kubelet never "
                            "gets a reply and the container crash-loops; use an exec probe"))

    # A projected token with no expirationSeconds inherits the 24-hour default. Bounding it is the
    # difference between a leaked token being useful for a day and for minutes.
    for v in pod.get("volumes") or []:
        for s in ((v.get("projected") or {}).get("sources") or []):
            sat = s.get("serviceAccountToken")
            if sat is None:
                continue
            exp = sat.get("expirationSeconds")
            if exp is None or int(exp) > 3600:
                findings.append((src, owner, f"volume/{v.get('name')}",
                    f"projected serviceAccountToken expirationSeconds={exp}; bound it to 3600 or "
                    "less rather than inheriting the 24-hour default"))

sources = sorted(p for p in glob.glob(os.path.join(render_dir, "*.yaml")) if not p.endswith(".err"))
sources += [f for f in glob.glob("gitops/**/*.yaml", recursive=True)
            if "/templates/" not in f and "terraform-values" not in f]

checked = 0
for path in sources:
    try:
        docs = [d for d in yaml.safe_load_all(open(path, encoding="utf-8")) if isinstance(d, dict)]
    except Exception:
        continue
    for d in docs:
        for owner, pod in pod_specs(d):
            checked += 1
            check(os.path.basename(path), owner, pod)

for src, owner, where, msg in findings:
    print(f"      ✗ {src}  {owner} [{where}]  {msg}")
print(f"      {checked} pod template(s) checked, {len(findings)} finding(s)")
sys.exit(1 if findings else 0)
PY
if [[ $? -eq 0 ]]; then ok "workload security posture"; else bad "workload security posture"; fi

# ---------------------------------------------------------------------------
step "Each platform chart renders, and each layer's file leaves on its own name"
# ---------------------------------------------------------------------------

# gitops/platform/<path> is a Helm chart whose templates are the Applications, each wrapped in
# `if not (has "<file>" .Values.excluded)`. A wrapper that names the wrong file, or an `end` in the
# wrong place, still renders cleanly with nothing excluded, and the layer it belongs to can then not
# be turned off -- or turning off a neighbour removes it. So: every template excluded renders
# nothing, one excluded removes exactly that one, and none excluded renders one Application per
# document in the template's source.
#
# The checks below read this one render (PLATFORM_RENDER_DIR, through scripts/lib/platform_render.py)
# rather than the templates, which are not manifests until rendered.
PLATFORM_RENDER_DIR="$RENDER_DIR/platform"
export PLATFORM_RENDER_DIR
if python3 "$ROOT/scripts/lib/platform_render.py" render "$ROOT" "$PLATFORM_RENDER_DIR" \
   && python3 "$ROOT/scripts/lib/platform_render.py" check "$ROOT"; then
  ok "platform charts render"
else
  bad "platform charts render"
fi

# ---------------------------------------------------------------------------
step "Static YAML parses"
# ---------------------------------------------------------------------------

python3 - "$PLATFORM_RENDER_DIR" <<'PY'
import glob, os, sys
try:
    import yaml
except ImportError:
    print("      ! PyYAML not installed; skipping")
    sys.exit(0)

# Everything that is not a Helm template: the examples, the bootstrap, the platform charts' own
# files. The platform's Applications, and the alternatives written as its templates, are parsed as
# rendered, from the step above (<render dir>/<path>/ mirrors gitops/platform/<path>/).
rendered = set(glob.glob(os.path.join(sys.argv[1], "**", "*.yaml"), recursive=True))
mirror = {os.path.join("gitops/platform", os.path.relpath(r, sys.argv[1])) for r in rendered}
paths = sorted(
    set(glob.glob("gitops/bootstrap/**/*.yaml", recursive=True))
    | {p for p in glob.glob("gitops/platform/**/*.yaml", recursive=True)
       if "/templates/" not in p and p not in mirror}
    | set(glob.glob("gitops/examples/**/*.yaml", recursive=True))
    | rendered
)

failed = False
for path in paths:
    if path.endswith("terraform-values.yaml"):
        continue  # written by Terraform, not checked in on a clean tree
    try:
        docs = [d for d in yaml.safe_load_all(open(path, encoding="utf-8")) if d]
    except yaml.YAMLError as e:
        print(f"      ✗ {path}: {e}")
        failed = True
        continue
    if not docs:
        print(f"      ✗ {path}: parses but contains no object. Argo CD recursing this directory "
              f"would sync nothing from it; if it is a decision record, give it a .md extension.")
        failed = True
        continue
    print(f"      ✓ {path} ({len(docs)} docs)")

sys.exit(1 if failed else 0)
PY
if [[ $? -eq 0 ]]; then ok "static YAML"; else bad "static YAML"; fi

# ---------------------------------------------------------------------------
step "The agent's gateway credential is mintable and accepted"
# ---------------------------------------------------------------------------

# Two charts have to agree on one string or nothing works, and the disagreement is silent: the pod
# is Running, the policies are Accepted, and every model call is rejected for an unverifiable
# identity. This check catches an agent with no gateway credential at all, which rendering and
# linting both pass.
python3 - "$RENDER_DIR" <<'PY'
import glob, os, re, sys

try:
    import yaml
except ImportError:
    print("      ! PyYAML not installed; skipping")
    sys.exit(0)

render_dir = sys.argv[1]
failed = False

CEL = re.compile(r'^\$\{schema\.spec\.([A-Za-z0-9_]+)\}$')
DEFAULT = re.compile(r'default="([^"]*)"')


def docs(path):
    with open(path, encoding="utf-8") as f:
        return [d for d in yaml.safe_load_all(f) if isinstance(d, dict)]


def resolve(value, schema_spec):
    """A composed template's field is a CEL reference; the real value is the schema field's default.

    So a check that read the template literally would compare '${schema.spec.gatewayAudience}'
    against 'agentgateway' and report a mismatch on a correct configuration. Follow the reference.
    """
    m = CEL.match(str(value))
    if not m:
        return value
    decl = schema_spec.get(m.group(1))
    if decl is None:
        return None  # the template names a field the schema does not declare
    d = DEFAULT.search(str(decl))
    return d.group(1) if d else None


# What the agent mints: the audiences on the projected volume in the Deployment the RGD composes.
#
# The volume can hold more than the gateway's credential, so the sources are checked differently
# and by file name:
#
#   token       the gateway credential. Its audience must be exactly what the gateway accepts.
#   any other   a credential for something else, with its own audience. What IS checkable is that
#               no branch of its expression can render empty, because an `audience: ""` source is a
#               token for the Kubernetes API server. That would hand every agent a cluster
#               credential and silently undo needsClusterApi: false.
minted = set()
other_sources = 0
for path in glob.glob(os.path.join(render_dir, "base-*.yaml")):
    for d in docs(path):
        if d.get("kind") != "ResourceGraphDefinition":
            continue
        schema_spec = d.get("spec", {}).get("schema", {}).get("spec", {})
        for res in d.get("spec", {}).get("resources", []):
            tmpl = res.get("template", {})
            if tmpl.get("kind") != "Deployment":
                continue
            pod = tmpl.get("spec", {}).get("template", {}).get("spec", {})
            for vol in pod.get("volumes", []):
                for src in vol.get("projected", {}).get("sources", []):
                    sat = src.get("serviceAccountToken")
                    if not sat or not sat.get("audience"):
                        continue
                    raw = str(sat["audience"])

                    if sat.get("path") != "token":
                        other_sources += 1
                        # An empty branch anywhere in the expression is the API-server token.
                        if '? ""' in raw or ': ""' in raw or ":''" in raw or "? ''" in raw:
                            print(f"      ✗ {os.path.basename(path)}: the {sat.get('path')!r} token's "
                                  f"audience can render empty: {raw!r}. An audience-less projected "
                                  f"token is a credential for the Kubernetes API server, which no "
                                  f"agent on this stack is meant to hold.")
                            failed = True
                        else:
                            print(f"      ✓ {os.path.basename(path)}: {sat.get('path')!r} always "
                                  f"names an audience")
                        continue

                    # A SECOND RELYING PARTY IS NOT A MISCONFIGURATION. The gateway-audience check
                    # below compares every minted audience against what the gateway accepts, which
                    # is right for the credential the agent presents to the gateway and wrong for a
                    # token deliberately minted for something else -- an in-cluster MCP server that
                    # validates its own audience, for instance. Those volumes are skipped here and
                    # checked by their own consumer instead.

                    if vol.get("name") in ("mcp-identity",):
                        continue

                    aud = resolve(raw, schema_spec)
                    if aud is None:
                        print(f"      ✗ {os.path.basename(path)}: the projected token's audience is "
                              f"{raw!r}, which resolves to nothing. A volume whose "
                              f"audience renders empty mints a token for the Kubernetes API server, "
                              f"which the gateway rejects.")
                        failed = True
                        continue
                    minted.add((os.path.basename(path), aud))

if not minted:
    print("      ✗ the composed agent Deployment projects no audience-scoped token. The gateway's "
          "JWT authentication is Strict, so the agent would hold no credential it accepts and "
          "every model call would be refused with no error on any object.")
    failed = True

# What the gateway accepts.
accepted = set()
for path in glob.glob(os.path.join(render_dir, "agwcfg*.yaml")):
    for d in docs(path):
        for prov in (d.get("spec", {}).get("traffic", {})
                       .get("jwtAuthentication", {}).get("providers", [])):
            for aud in prov.get("audiences", []):
                accepted.add(aud)

if accepted:
    bad = {a for _, a in minted} - accepted
    if bad:
        print(f"      ✗ the agent mints a token for {sorted(bad)} and the gateway accepts only "
              f"{sorted(accepted)}. Set gateway.audience once, in the values file Terraform writes.")
        failed = True
    else:
        print(f"      ✓ audience agrees on both sides: {sorted(accepted)}")
else:
    print("      ! no agentgateway JWT provider rendered; audience agreement not checked for the "
          "open source path")

for name, aud in sorted(minted):
    print(f"      ✓ {name}: composed agent mints a token for {aud!r}")

sys.exit(1 if failed else 0)
PY
if [[ $? -eq 0 ]]; then ok "gateway credential"; else bad "gateway credential"; fi

# ---------------------------------------------------------------------------
step "Every mesh mode renders, and renders only its own shape"
# ---------------------------------------------------------------------------

# mesh.mode is one variable with two values, none and ambient. The failure this check exists for is
# the one Istio makes silent: a namespace labelled for both data planes is resolved in favour of
# sidecar injection, with nothing to show it. So assert that each mode emits exactly its own label
# and never istio-injection, and that an unknown value -- including "sidecar", which the stack does
# not offer -- is refused rather than quietly producing a cluster with no mesh. See the agents-mesh
# page of the EKS User Guide.
mesh_fail=0
for mode in none ambient; do
  if helm template "mesh-$mode" gitops/base \
       -f gitops/base/values.yaml -f "$RENDER_DIR/oss-values.yaml" \
       --set-string mesh.mode="$mode" > "$RENDER_DIR/mesh-$mode.yaml" 2>"$RENDER_DIR/mesh-$mode.err"; then
    :
  else
    bad "helm template gitops/base (mesh.mode=$mode)"
    sed 's/^/      /' "$RENDER_DIR/mesh-$mode.err" | head -10
    mesh_fail=1
    continue
  fi
  python3 "$ROOT/scripts/lib/check_mesh_mode.py" "$RENDER_DIR/mesh-$mode.yaml" "$mode" || mesh_fail=1
done

# An unknown value must fail loudly. A typo that rendered a mesh-less cluster would look like a
# working install with the enforcement layer missing.
if helm template mesh-bogus gitops/base -f gitops/base/values.yaml -f "$RENDER_DIR/oss-values.yaml" \
     --set-string mesh.mode=ambinet >/dev/null 2>&1; then
  bad "mesh.mode accepted a typo ('ambinet') instead of failing"
  mesh_fail=1
fi
if helm template mesh-sidecar gitops/base -f gitops/base/values.yaml -f "$RENDER_DIR/oss-values.yaml" \
     --set-string mesh.mode=sidecar >/dev/null 2>&1; then
  bad "mesh.mode accepted 'sidecar', which the stack does not offer, instead of failing"
  mesh_fail=1
fi

if [[ $mesh_fail -eq 0 ]]; then ok "mesh modes"; else bad "mesh modes"; fi

# ---------------------------------------------------------------------------
step "Every Cedar permit names its principal"
# ---------------------------------------------------------------------------

# AN UNCONSTRAINED `principal` IS THE ONE MISTAKE THAT RE-OPENS THE GATEWAY, and it is invisible:
# the policy validates, reaches ACTIVE, and the engine still reports ENFORCE.
#
# On this path a gateway admits exactly one service account subject or every one, so with more than
# one agent `allowed_agent_subjects` is empty and the per-agent decision belongs to the policy
# engine. Cedar's principal for a JWT-authorized gateway is `AgentCore::OAuthUser`, whose entity id
# IS the `sub` claim, so the decision is expressible there per agent. Two agents holding disjoint
# grants over one gateway each reach only what their own permits name.
#
# Add ONE `permit(principal, ...)` beside those, and every caller -- including a service account
# named by no policy at all -- is allowed both, with the same engine still reporting ENFORCE.
#
# So: a permit whose principal is the bare keyword is refused here. `principal == ...`,
# `principal in ...` and `principal is ...` are all constrained and all pass. A `forbid` is not
# checked, because an unconstrained forbid is a deny and fails closed.
cedar_fail=0
cedar_checked=0
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  out="$(CEDAR_FILE="$f" python3 "$ROOT/scripts/lib/check_cedar_principals.py" "$f")" || cedar_fail=1
  [[ -n "$out" ]] && printf '%s\n' "$out"
  cedar_checked=$((cedar_checked + 1))
done < <(find "$ROOT/terraform" -name '*.tfvars' -print)

if [[ $cedar_fail -eq 0 ]]; then
  ok "every Cedar permit names its principal ($cedar_checked .tfvars files)"
else
  bad "a Cedar permit leaves its principal unconstrained"
fi

# ---------------------------------------------------------------------------
step "Every ingress route rule carries the OIDC filter"
# ---------------------------------------------------------------------------

# THE GATE ATTACHES PER RULE, NOT PER ROUTE. A route with two rules and one ExtensionRef filter
# serves the other path unauthenticated -- and nothing reports it: the Gateway is Accepted, the
# ListenerRuleConfiguration has no status to disagree with, and no condition anywhere says a rule
# has no authentication on it. The only way to see it is an unauthenticated request to that path,
# which is why scripts/exercise.sh asserts a refusal rather than reading these objects.
#
# The cluster half of this is a ValidatingAdmissionPolicy in gitops/base; this is the half that
# governs what this repository ships, because an example is what a reader copies.
#
# Rendered YAML only. The chart's templates deliberately carry BOTH route variants -- the
# unauthenticated one is what a cluster with no identity provider gets, selected by a condition a
# text scan cannot evaluate.
# The platform's Applications and its template alternatives are read as rendered, in place of the
# template beside them (<render dir>/<path>/ mirrors gitops/platform/<path>/).
route_files=()
while IFS= read -r f; do
  rel="${f#"$ROOT/gitops/platform/"}"
  [[ "$rel" != "$f" && -f "$PLATFORM_RENDER_DIR/$rel" ]] && continue
  route_files+=("$f")
done < <(
  find "$ROOT/gitops" "$PLATFORM_RENDER_DIR" -name '*.yaml' -not -path "$ROOT/gitops/*/templates/*" -print
)
# Every Application source that points into this repository keeps the REPO_URL / HEAD placeholders,
# so the documented substitution reaches it. The script's docstring says why.
if out="$("$PYTHON_BIN" "$ROOT/scripts/lib/check_inrepo_sources.py" "$ROOT")"; then
  ok "in-repo Application sources carry the repository placeholders"
  [[ -n "$out" ]] && printf '%s\n' "$out"
else
  [[ -n "$out" ]] && printf '%s\n' "$out"
  bad "an in-repo Application source names a concrete repository or revision"
fi

# The AppProject lists exactly the repositories the platform's Applications read, so a component
# added with a new chart repository fails here rather than at its first sync. The script's docstring
# says what else it holds the project to.
if out="$("$PYTHON_BIN" "$ROOT/scripts/lib/check_appproject.py" "$ROOT")"; then
  ok "the AppProject admits the platform's repositories and destination, and nothing else"
  [[ -n "$out" ]] && printf '%s\n' "$out"
else
  [[ -n "$out" ]] && printf '%s\n' "$out"
  bad "the AppProject and the platform's Applications disagree on a repository or destination"
fi

# Teardown deletes every ClusterNetworkPolicy by name before the base release goes, or its delete
# hangs on a finalizer nothing can clear. See the script's header.
if out="$("$PYTHON_BIN" "$ROOT/scripts/lib/check_teardown_cnps.py" "$ROOT")"; then
  ok "teardown deletes every ClusterNetworkPolicy the chart renders"
  [[ -n "$out" ]] && printf '%s\n' "$out"
else
  [[ -n "$out" ]] && printf '%s\n' "$out"
  bad "teardown misses a ClusterNetworkPolicy the chart renders"
fi

if out="$("$PYTHON_BIN" "$ROOT/scripts/lib/check_route_filters.py" "${route_files[@]}")"; then
  ok "every ingress HTTPRoute gates all of its rules"
  [[ -n "$out" ]] && printf '%s\n' "$out"
else
  [[ -n "$out" ]] && printf '%s\n' "$out"
  bad "an ingress route rule is served unauthenticated"
fi

# ---------------------------------------------------------------------------
step "The mesh is enabled in both places, or in neither"
# ---------------------------------------------------------------------------

# ENABLING THE MESH TAKES TWO EDITS IN TWO DIFFERENT PLACES, and doing one of them breaks more than
# the mesh. `mesh_mode` is a Terraform variable that lands in the rendered terraform-values.yaml;
# installing Istio means uncommenting the syncPolicy on four Argo CD Applications in Git. Set the
# variable without uncommenting, and gitops/base renders AuthorizationPolicies in
# `security.istio.io/v1` against a cluster where that group does not exist -- which fails the WHOLE
# eks-agents-base sync, so the namespaces, the admission policy, the egress boundary and the agent
# resource definition are all absent. The error names an Istio API group and says nothing about
# the admission policy it also takes down.
#
# Uncommenting without setting the variable is the harmless direction -- a mesh with no namespace
# enrolled captures nothing -- so only the dangerous one fails here.
twohalves_fail=0
for p in aws-services open-source; do
  values="gitops/platform/$p/terraform-values.yaml"
  # The Istio Applications as the root Application renders them, from the platform chart.
  istio_app="$PLATFORM_RENDER_DIR/$p/$([[ $p == aws-services ]] && echo 55-istio.yaml || echo 20-istio.yaml)"
  [[ -f "$values" && -f "$istio_app" ]] || continue

  # The rendered mode, if the file has been rendered at all. A placeholder or a missing key is not
  # a mesh, so it is not this check's business.
  # THE mode UNDER mesh, and nothing else that happens to be called mode. awk rather than grep so
  # the key is read inside its own block, and quoted keys as well as bare ones: terraform's
  # yamlencode quotes every key, so a rendered file reads
  #   "mesh":
  #     "mode": "ambient"
  # while the hand-written placeholder beside it reads `mode: "none"`. A pattern matching only the
  # bare form passes on every real deployment and can fire only on the placeholder, which is the
  # one file no cluster is ever running.
  #
  # Not an inline `<<'PY'` heredoc: bash 3.2 mis-parses a heredoc inside `$( )`, and reports the
  # syntax error far from it.
  mode="$(awk '
    /^"?mesh"?[[:space:]]*:/ { inmesh = 1; next }
    /^[^[:space:]#]/         { inmesh = 0 }
    inmesh && $0 ~ /^[[:space:]]+"?mode"?[[:space:]]*:/ {
      v = $0; sub(/^[^:]*:[[:space:]]*/, "", v); gsub(/[" ]/, "", v); print v; exit
    }' "$values")"
  # How many of the four Applications would actually install: a live `automated:` under syncPolicy.
  # The gate is `# automated:`; the sync options beside it stay live on purpose.
  live="$(grep -c '^    automated:' "$istio_app" || true)"

  if [[ "$mode" == "ambient" ]]; then
    if [[ "${live:-0}" -lt 4 ]]; then
      bad "$p: mesh.mode is '$mode' but only ${live:-0} of 4 Istio Applications in $(basename "$istio_app") would install"
      warn "uncomment the three automated lines in each gate block"
      warn "the sync options beside them are already live"
      twohalves_fail=1
    else
      ok "$p: mesh.mode '$mode' and all 4 Istio Applications enabled"
    fi
  else
    ok "$p: mesh off (mode '${mode:-unset}'), ${live:-0} of 4 Istio Applications enabled"
  fi
done

# ---------------------------------------------------------------------------
step "No Istio policy enforces something other than what it reads as"
# ---------------------------------------------------------------------------

# A CATCH-ALL DENY, first, because it is the one that makes every other rule in its scope moot.
# `action: DENY` with an empty rule and no selector reads as a namespace default-deny and is not
# one: DENY is evaluated before ALLOW and wins, so nothing can ever be allowed. The correct
# default-deny is `action: ALLOW` with no rules.
#
# THEN L7 AT ZTUNNEL, AMBIENT ONLY. ztunnel is an L4 proxy, so Istio omits the L7 attributes it
# cannot evaluate, and the outcome depends on the action -- one of the three fails OPEN:
#
#   ALLOW + L7                  rules omitted, nothing matches, connection denied  (fails closed)
#   DENY  + L7 and some L4      enforced without the L7 rules, over-blocks         (fails closed)
#   DENY  + only L7             no enforceable rule left, policy has NO EFFECT     (FAILS OPEN)
#
# The examples here are built for ambient, the only mesh mode (the open source fixture above renders
# it), so that is what this checks. The L7 attribute list is from Istio's own conversion,
# pilot/pkg/serviceregistry/ambient/authorization.go.
python3 "$ROOT/scripts/lib/check_l7_at_ztunnel.py" "$RENDER_DIR"
if [[ $? -eq 0 ]]; then ok "Istio policy enforcement point"; else bad "Istio policy enforcement point"; fi

# ---------------------------------------------------------------------------
step "No manifest carries a duplicate mapping key"
#
# THE PARSE STEP CANNOT CATCH THIS. PyYAML's safe_load accepts a duplicate key and keeps the last
# one, so a file kubectl refuses outright --
#
#   error: error validating data: ... found a duplicate key
#
# -- passes every other check here: a duplicated `command:` in an example's manifest still leaves
# this script reporting all checks passed. The same class of bug can stop an entire install: when
# the affected file is first in an apply list, `set -e` takes everything behind it.
# No mapfile: this has to run on the bash 3.2 that ships with macOS, where it does not exist and
# the step exits 127 while printing its header -- which reads as a crash rather than a missing
# builtin.
# The platform's Applications are templates, so their rendered form is what is read.
find "$ROOT/gitops" "$PLATFORM_RENDER_DIR" -name '*.yaml' -not -path '*/charts/*/templates/*' \
     -not -path "$ROOT/gitops/platform/*/templates/*" -print0 2>/dev/null \
  | xargs -0 python3 "$ROOT/scripts/lib/check_duplicate_keys.py"
if [[ $? -eq 0 ]]; then ok "no duplicate mapping keys"; else bad "no duplicate mapping keys"; fi

# ---------------------------------------------------------------------------
step "The agent dashboard is internally consistent"
# ---------------------------------------------------------------------------

# A Grafana panel whose query names a metric nothing produces renders as an empty graph, and an
# empty graph on an agent platform reads as "no traffic" rather than "this panel is broken". The
# dashboard is templated from values.yaml, so this checks the template stayed consistent with
# itself: the JSON parses, every panel has a title, the ServiceMonitor that feeds it exists, and
# every recording rule a panel uses is defined by the chart's PrometheusRule.
if helm template agent-dashboards gitops/charts/agent-dashboards \
     > "$RENDER_DIR/dashboards.yaml" 2>"$RENDER_DIR/dashboards.err"; then
  python3 "$ROOT/scripts/lib/check_dashboards.py" "$RENDER_DIR/dashboards.yaml"
  if [[ $? -eq 0 ]]; then ok "agent dashboard"; else bad "agent dashboard"; fi
else
  bad "helm template gitops/charts/agent-dashboards"
  sed 's/^/      /' "$RENDER_DIR/dashboards.err" | head -10
fi

# ---------------------------------------------------------------------------
step "The credential checks fail closed"
# ---------------------------------------------------------------------------

# check_route_gates.py below proves every route calls a verifier. These prove the verifier is
# correct, that each service is wired to it, and that an agent attaches its credential to a real
# model call:
#
#   test_gates.py       a forged token, a wrong-key token, a wrong-audience token and an expired
#                       token are each refused, and a correctly signed one is accepted -- without
#                       that last case the others would pass on a gate that refuses everything.
#   test_services.py    every route of all three serving workloads, through the real ASGI app.
#   test_model_path.py  a turn against a fake OpenAI-compatible endpoint, asserting the projected
#                       token arrives on the request, which only a real call can show.
#   test_relay.py       the chat UI relaying a turn on its OWN token rather than forwarding the
#                       person's, which is what keeps the UI out of the agent's trust chain.
#   test_person_access.py  the tools that act with a person's authority verify the person's token
#                       and answer for that person only.
#
# ALL FIVE, and they do not share one dependency set. test_gates and test_services need fastapi and
# pyjwt[crypto]; the other three import apps/reference/app.py and so need strands as well, on
# Python 3.10 or newer. A venv built from apps/mcp-server/requirements.txt alone satisfies the
# `import fastapi` guard and then fails the last three on ModuleNotFoundError, and a failure
# branch that greps for `fail` prints NOTHING, because an ImportError traceback does not contain
# the word. So the guard checks every import the tests actually make, and a failure prints the
# interpreter's own output.
# apply.sh's recovery (standard library only, so outside the agent-dependency gate below): a network error retries, "already exists" names the import, and only a
# tainted EKS cluster or capability that is healthy in AWS is ever untainted.
if out="$(python3 "$ROOT/scripts/lib/apply_recover.py" selftest 2>&1)"; then
  ok "apply recovery: network errors retried, import commands named, unsafe taints left alone (apply_recover)"
else
  bad "apply recovery (apply_recover selftest)"
  printf '%s\n' "$out" | grep -E 'FAIL' | head -10 | sed 's/^/      /'
fi
if "$PYTHON_BIN" -c "import fastapi, jwt.algorithms, strands" >/dev/null 2>&1; then
  cred_tests=(test_gates test_services test_model_path test_relay test_person_access)
  cred_failed=()
  for t in "${cred_tests[@]}"; do
    "$PYTHON_BIN" "$ROOT/apps/tests/$t.py" >/dev/null 2>&1 || cred_failed+=("$t")
  done

  if [[ ${#cred_failed[@]} -eq 0 ]]; then
    ok "credential checks fail closed (${#cred_tests[@]} test files)"
  else
    bad "credential checks fail closed: ${cred_failed[*]}"
    for t in "${cred_failed[@]}"; do
      printf '      --- %s\n' "$t"
      "$PYTHON_BIN" "$ROOT/apps/tests/$t.py" 2>&1 | tail -20 | sed 's/^/      /'
    done
  fi
  if out="$("$PYTHON_BIN" "$ROOT/apps/tests/test_session_state.py" 2>&1)"; then
    ok "saved conversations: continued in the same session, empty for another caller (test_session_state)"
  else
    bad "saved conversations (test_session_state)"
    printf '%s\n' "$out" | grep -E 'FAIL|Error' | head -10 | sed 's/^/      /'
  fi
  # The plan guard refuses the shapes a bad refresh produces, and lets a deliberate delete through.
  if out="$(python3 "$ROOT/scripts/lib/plan_guard.py" --self-test 2>&1)"; then
    ok "plan guard: refuses a replaced or read-as-deleted protected resource, allows a plain delete (plan_guard)"
  else
    bad "plan guard (plan_guard --self-test)"
    printf '%s\n' "$out" | grep -E 'FAIL' | head -10 | sed 's/^/      /'
  fi
  # A task agent's worker, with a fake SQS client and no model: answered then deleted, a failure
  # left for a retry, a malformed task refused, a long task kept invisible.
  if out="$("$PYTHON_BIN" "$ROOT/apps/tests/test_tasks.py" 2>&1)"; then
    ok "task worker: one message, answered then deleted, failures retried, long tasks kept (test_tasks)"
  else
    bad "task worker (test_tasks)"
    printf '%s\n' "$out" | grep -E 'FAIL|Error' | head -10 | sed 's/^/      /'
  fi
  # Consolidation's wiring needs only app.py's own imports; Mem0 itself is never imported by it.
  if out="$("$PYTHON_BIN" "$ROOT/apps/tests/test_consolidation.py" 2>&1)"; then
    ok "consolidation wiring: off is off, both model calls on the gateway, memory scoped to the caller (test_consolidation)"
  else
    bad "consolidation wiring (test_consolidation)"
    printf '%s\n' "$out" | grep -E 'FAIL|Error' | head -10 | sed 's/^/      /'
  fi
  # AgentCore memory, with a stand-in client: no AWS call.
  if out="$("$PYTHON_BIN" "$ROOT/apps/tests/test_agentcore_memory.py" 2>&1)"; then
    ok "AgentCore memory: each turn an event, per-person retrieval by namespacePath (test_agentcore_memory)"
  else
    bad "AgentCore memory (test_agentcore_memory)"
    printf '%s\n' "$out" | grep -E 'FAIL|Error' | head -10 | sed 's/^/      /'
  fi
  # The evaluation runner's tests need strands-agents-evals as well, from apps/evals/requirements.txt.
  # Skipped with a warning rather than failed when it is absent, like the rest of this step.
  if "$PYTHON_BIN" -c "import strands_evals, langfuse" >/dev/null 2>&1; then
    if out="$("$PYTHON_BIN" "$ROOT/apps/tests/test_evals_runner.py" 2>&1)"; then
      ok "evaluation runner fails closed (test_evals_runner)"
    else
      bad "evaluation runner fails closed (test_evals_runner)"
      printf '%s\n' "$out" | tail -20 | sed 's/^/      /'
    fi
  else
    warn "skipping test_evals_runner: $PYTHON_BIN cannot import strands_evals and langfuse."
    warn "  .venv/bin/pip install -r apps/evals/requirements.txt"
  fi
else
  warn "skipping the credential tests: $PYTHON_BIN cannot import fastapi, pyjwt[crypto] and strands."
  warn "Run them before any change to apps/common/cluster_auth.py or apps/reference/."
  warn "BOTH requirements files, and Python 3.10+ -- strands-agents has no distribution for 3.9,"
  warn "and the failure reads as 'no matching distribution' rather than a version conflict:"
  warn "  python3.13 -m venv .venv   # in the repository; .gitignore ignores it"
  warn "  .venv/bin/pip install -r apps/reference/requirements.txt -r apps/mcp-server/requirements.txt"
  warn "  PYTHON_BIN=.venv/bin/python ./scripts/validate.sh"
fi

# ---------------------------------------------------------------------------
step "Every serving route verifies a credential"
# ---------------------------------------------------------------------------

# A route added without its gate does not fail a test and does not look wrong in a diff. It is also
# a model an unauthenticated caller can drive, so it is checked mechanically.
python3 "$ROOT/scripts/lib/check_route_gates.py"
if [[ $? -eq 0 ]]; then ok "route gates"; else bad "route gates"; fi

# ---------------------------------------------------------------------------
step "The agent resource hands an agent usable endpoints"
# ---------------------------------------------------------------------------

# A model endpoint with no scheme on it, naming a gateway with no inference target, is a defect that
# renders, lints, syncs and reports healthy. This asserts the shape of both endpoints instead.
python3 "$ROOT/scripts/lib/check_agent_endpoints.py" "$RENDER_DIR"
if [[ $? -eq 0 ]]; then ok "agent endpoints"; else bad "agent endpoints"; fi

# ---------------------------------------------------------------------------
step "Rendered diagrams are in step with their source"
# ---------------------------------------------------------------------------

# The design record's figures are checked by scripts/lib/diagram-checks.sh, which the published tree
# does not carry; there, this step has nothing to check.
if [[ -x "$ROOT/scripts/lib/diagram-checks.sh" ]]; then
  if "$ROOT/scripts/lib/diagram-checks.sh"; then ok "diagrams"; else bad "diagrams"; fi
else
  ok "diagrams (none in this tree)"
fi

# ---------------------------------------------------------------------------
step "The published tree names nothing internal and no past run"
# ---------------------------------------------------------------------------

# scripts/export-public.sh publishes this tree, minus the design record. check_public_ready.py is not
# published itself, so in the published tree this step has nothing to check.
if [[ -f "$ROOT/scripts/lib/check_public_ready.py" ]]; then
  if python3 "$ROOT/scripts/lib/check_public_ready.py"; then ok "public-ready"; else bad "public-ready"; fi
else
  ok "public-ready (checked before export)"
fi

# ---------------------------------------------------------------------------
step "The infrastructure carve-out does not name an agent namespace"
# ---------------------------------------------------------------------------

# The one object in gitops/base that can undo the egress boundary. It exists because the agents'
# nodes run in strict enforcement mode and the DaemonSets that land there are selected by no other
# policy: without it, ztunnel can neither reach istiod nor be probed on the agents' own node. An
# Admin-tier Accept ends evaluation, so an agent namespace in that list would get unrestricted
# egress with every later rule dead and nothing reporting it.
python3 "$ROOT/scripts/lib/check_infra_namespaces.py" "$RENDER_DIR/base-oss.yaml" "$RENDER_DIR/base-aws.yaml"
if [[ $? -eq 0 ]]; then ok "carve-out excludes agent namespaces"; else bad "carve-out excludes agent namespaces"; fi

# ---------------------------------------------------------------------------
step "DNS egress goes to the resolver ranges only"
# ---------------------------------------------------------------------------

# A port-53 rule to 0.0.0.0/0 is a direct line to any resolver on the internet. Every DNS rule names
# networkPolicy.dnsDestinations; the script's docstring says what it reads.
(cd "$ROOT" && python3 scripts/lib/check_dns_egress.py "$RENDER_DIR/base-oss.yaml" "$RENDER_DIR/base-aws.yaml" "$RENDER_DIR/base-oss-all.yaml")
if [[ $? -eq 0 ]]; then ok "DNS egress is scoped to the resolver ranges"; else bad "DNS egress is scoped to the resolver ranges"; fi

# The sandbox reads its network meters from the pod's annotations once, at creation, and reverts a
# value it cannot parse to its own default. The script's docstring says what it checks.
(cd "$ROOT" && python3 scripts/lib/check_sandbox_limits.py "$RENDER_DIR/base-oss.yaml" "$RENDER_DIR/base-aws.yaml" "$RENDER_DIR/base-oss-all.yaml")
if [[ $? -eq 0 ]]; then ok "sandbox network limits"; else bad "sandbox network limits"; fi

# ---------------------------------------------------------------------------
step "The chart renders against the values TERRAFORM writes, not just the placeholder"
# ---------------------------------------------------------------------------

# THE SHAPE VALIDATED IS NOT THE SHAPE DEPLOYED, and that is why this check exists.
#
# Every render above uses gitops/platform/<path>/terraform-values.yaml, the committed placeholder.
# It OMITS whole blocks, so the chart's own defaults apply and every `.Values.a.b.c` resolves. The
# file an apply writes comes from `yamlencode` over a Terraform object and contains every key that
# object has -- including the ones that are NULL because a feature is off. A null in a later values
# file does not merge with the chart's map; it REPLACES it.
#
# Without this check, every other check passes while the base chart cannot render against this
# repo's own `terraform apply` output with ingress off, which is the default.
#
#   Error: ... at <.Values.ingress.oidc.issuer>: nil pointer evaluating interface {}.issuer
#
# So render against a file that carries the nulls, on both paths and with each layer off, because a
# guard that only holds in the default configuration is the one that fails on the cluster.
null_shape_fail=0
for p in open-source aws-services; do
  for gw in true false; do
    for np in true false; do
    for obs in true false; do
      # NEVER AN EMPTY ARRAY. Under `set -u` on bash 3.2 -- which is what macOS ships, and what this
      # script runs on -- "${arr[@]}" on an empty array is an unbound-variable error, not an empty
      # expansion, and the failure would print an empty reason that reads as a render failure.
      extra=(--set "cluster=null-shape")
      # With the gateway off, no gateway value is set at all: that is what Terraform renders, and a
      # template that still requires one would fail here rather than at a customer's first sync.
      if [[ "$p" == "aws-services" && "$gw" == "true" ]]; then
        extra+=(--set gateway.hostname=h --set gateway.modelEndpoint=https://h
                --set gateway.mcpEndpoint=https://h/m --set model.gatewayModelId=bedrock/x)
      fi
      if ! out="$(helm template v "$ROOT/gitops/base" \
            -f "$ROOT/scripts/lib/render-null-shape.yaml" \
            --set "path=$p" --set "gateway.enabled=$gw" --set "networkPolicy.enabled=$np" \
            --set "observability.enabled=$obs" "${extra[@]}" 2>&1)"; then
        null_shape_fail=1
        printf '      ✗ %s gateway=%s networkPolicy=%s observability=%s: %s\n' "$p" "$gw" "$np" "$obs" \
          "$(printf '%s' "$out" | grep -i error | head -1)"
      elif [[ "$obs" == "false" ]] && grep -q "OTEL_EXPORTER_OTLP_ENDPOINT\|allow-telemetry-collector" <<<"$out"; then
        null_shape_fail=1
        printf '      ✗ %s observability=false still gives agents a collector endpoint or egress\n' "$p"
      elif [[ "$gw" == "false" && "$np" == "true" ]] && ! grep -q "bedrock-runtime\." <<<"$out"; then
        null_shape_fail=1
        printf '      ✗ %s gateway=false does not name bedrock-runtime as the model destination\n' "$p"
      fi
    done
    done
  done
done
if [[ "$null_shape_fail" -eq 0 ]]; then
  printf '      ✓ all 16 combinations render against a Terraform-shaped values file\n'
  ok "renders against terraform output"
else
  bad "renders against terraform output"
fi

# ---------------------------------------------------------------------------
step "Consolidation (open source rung 3) renders every piece it needs, and nothing when off"
# ---------------------------------------------------------------------------

# Five pieces, each of which is a separate silent failure on a rung of the memory ladder:
# the login read, the embedding model grant, the egress rule to Secrets Manager, the gateway's
# embeddings backend and route, and the environment. All five or none.
cons_arn="arn:aws:secretsmanager:us-west-2:111122223333:secret:null-shape/platform/agent-memory-db-AbCdEf"
cons_on="$(helm template v "$ROOT/gitops/base" -f "$ROOT/scripts/lib/render-null-shape.yaml" \
  --set path=open-source --set memory.consolidation.dbSecretArn="$cons_arn" 2>&1)"
cons_off="$(helm template v "$ROOT/gitops/base" -f "$ROOT/scripts/lib/render-null-shape.yaml" --set path=open-source 2>&1)"
cons_missing=()
for want in '"Sid": "AgentConsolidationLogin"' 'foundation-model/amazon.titan-embed-text-v2:0' \
            'secretsmanager.us-west-2.amazonaws.com' 'bedrock-embed-${schema.metadata.name}' \
            '/llm/${schema.metadata.name}/embeddings' '"*": Embeddings' 'AGENT_CONSOLIDATION_DB_SECRET_ARN' 'MEM0_TELEMETRY'; do
  grep -qF -- "$want" <<<"$cons_on" || cons_missing+=("$want")
done
if [[ ${#cons_missing[@]} -eq 0 ]] && ! grep -qE 'AgentConsolidationLogin|bedrock-embed-|AGENT_CONSOLIDATION_' <<<"$cons_off"; then
  ok "consolidation: login grant, embedding grant, egress, embeddings route and environment; none when off"
else
  bad "consolidation render: missing ${cons_missing[*]:-nothing}, or present when off"
fi

# ---------------------------------------------------------------------------
step "Durable state is opt-in, and never opens S3 beyond the agents' own bucket"
# ---------------------------------------------------------------------------

# With no bucket (the base) an agent gets no S3 grant, no S3 egress and no CHECKPOINT_* variable.
# With one, the egress rule names that bucket's own host and NEVER the regional s3.<region> host,
# which accepts requests for every bucket.
ck_off="$(helm template v "$ROOT/gitops/base" -f "$ROOT/scripts/lib/render-null-shape.yaml" --set path=open-source --set storage.checkpointBucket= 2>&1)"
ck_on="$(helm template v "$ROOT/gitops/base" -f "$ROOT/scripts/lib/render-null-shape.yaml" --set path=open-source 2>&1)"
if grep -qE 'AgentCheckpoint|allow-checkpoint-storage|name: CHECKPOINT_BUCKET' <<<"$ck_off"; then
  bad "durable state renders with no bucket"
elif ! grep -q 'null-shape-agent-checkpoints-111122223333.s3.us-west-2.amazonaws.com' <<<"$ck_on" || ! grep -q AgentCheckpointObjects <<<"$ck_on"; then
  bad "durable state: the bucket's grant or egress rule is missing with a bucket set"
elif grep -qE '"s3\.[a-z0-9-]+\.amazonaws\.com"' <<<"$ck_on$ck_off"; then
  bad "an egress rule names the regional S3 host, a route to every bucket"
else
  ok "durable state: off renders nothing; on names only the bucket's own host"
fi

# ---------------------------------------------------------------------------
step "Ingress renders in each browser-gate mode, every gate where its Secret is"
# ---------------------------------------------------------------------------

# Direct OIDC depends on a layout: every browser rule in the ingress namespace, beside the one
# Secret and the one eks:managed grant. A rule that drifts back beside its agent still renders and
# syncs, and the load balancer then serves a fixed-response 500. See the script's docstring.
"$PYTHON_BIN" "$ROOT/scripts/lib/check_ingress_modes.py" "$ROOT"
if [[ $? -eq 0 ]]; then ok "ingress gate layout"; else bad "ingress gate layout"; fi

# ---------------------------------------------------------------------------
step "Every vpc_endpoints key a root accepts, the module creates"
# ---------------------------------------------------------------------------

# Three lists name the keys: each root's validation and the module's services map and validation.
# A key added to a root alone passes this script and fails at plan time on the module's validation.
# The roots' lists must be subsets of the module's map.
"$PYTHON_BIN" "$ROOT/scripts/lib/check_vpc_endpoint_keys.py" "$ROOT"
if [[ $? -eq 0 ]]; then ok "vpc_endpoints keys"; else bad "vpc_endpoints keys"; fi

# ---------------------------------------------------------------------------
step "An Agent is a Sandbox by default, a Deployment on request"
# ---------------------------------------------------------------------------

# The runtime is chosen per Agent, and the two workloads must never both be composed, never carry
# different pods, and never be created before the CRDs kro checks them against. See the docstring.
"$PYTHON_BIN" "$ROOT/scripts/lib/check_agent_runtime.py" "$ROOT"
if [[ $? -eq 0 ]]; then ok "agent runtime"; else bad "agent runtime"; fi

# ---------------------------------------------------------------------------
step "Evaluation renders on and off, with the judge bound to one subject"
# ---------------------------------------------------------------------------

# Three charts share the `evals` block, and the bindings that make the judge a gateway principal --
# its route decided on its own subject first, each agent admitting the runner on its own port only,
# one token audience per agent -- are each one line a refactor can drop while every chart still
# renders. See the script's docstring for the full list.
"$PYTHON_BIN" "$ROOT/scripts/lib/check_evals.py" "$ROOT"
if [[ $? -eq 0 ]]; then ok "evaluation layout"; else bad "evaluation layout"; fi

# ---------------------------------------------------------------------------
step "Each layer is turned off in both places, or in neither"
# ---------------------------------------------------------------------------

# Network policy, the gateway and the mesh are each optional, and each is switched in TWO places: a
# chart value, and -- for the two that are also Argo CD Applications -- the root Application's
# `directory.exclude` glob. Nothing at runtime notices when those disagree, and both directions are
# quiet: a gateway that runs with no policy naming it reads as a working cluster, and a policy
# naming an empty gateway namespace produces timeouts that the egress check reports as a PASS.
python3 "$ROOT/scripts/lib/check_layer_toggles.py" "$ROOT"
if [[ $? -eq 0 ]]; then ok "layer toggles agree across Terraform and the charts"; else bad "layer toggles agree across Terraform and the charts"; fi

# ---------------------------------------------------------------------------
step "The controls that are on by default are present in the render"
# ---------------------------------------------------------------------------

# WHY THIS EXISTS. An edit to gitops/base/values.yaml that moves a block into the middle of the
# `networkPolicy` map makes `clusterScoped` and `namespaced` children of `nodeClass`. Both templates
# are gated on those keys. The YAML stays valid, every other check passes, the chart installs, the
# release reports deployed -- and the cluster has NO egress policy at all. The render simply holds
# fewer documents, and a suite that reports what rendered rather than asserting what must says
# nothing.
#
# An agent in a sandboxed pod on that cluster reaches example.com. The control this repository is
# built around is absent and the only signal is a phase in exercise.sh.
#
# So: the kinds below are the controls that are ON by default. If a value stops reaching its
# template, this fails here rather than on a cluster.
python3 - "$RENDER_DIR/base-oss.yaml" "$RENDER_DIR/base-aws.yaml" <<'PY'
import sys, yaml

# kind -> why it must be there, named so a failure explains itself.
REQUIRED = {
    "ClusterNetworkPolicy": "the Admin-tier egress boundary (networkPolicy.clusterScoped)",
    "ApplicationNetworkPolicy": "the namespaced egress policy (networkPolicy.namespaced)",
    "ValidatingAdmissionPolicy": "the admission policy that requires a sandbox runtime class",
    "ValidatingAdmissionPolicyBinding": "the binding without which the admission policy is inert",
    "ConfigMap": "the amazon-vpc-cni ConfigMap that turns network policy enforcement on",
    "ResourceGraphDefinition": "the Agent resource definition",
    "Namespace": "the agent namespaces and their admission labels",
}

failed = False
for path in sys.argv[1:]:
    try:
        kinds = {d.get("kind") for d in yaml.safe_load_all(open(path, encoding="utf-8")) if d}
    except (OSError, yaml.YAMLError) as e:
        print(f"      \u2717 {path}: {e}")
        failed = True
        continue
    missing = {k: why for k, why in REQUIRED.items() if k not in kinds}
    if missing:
        failed = True
        for k, why in sorted(missing.items()):
            print(f"      \u2717 {path}: no {k} rendered -- {why}")
        print(f"        A value gating it is not reaching its template. Check that the keys are "
              f"still where the templates read them: a block moved into the middle of another "
              f"map leaves valid YAML and a missing control.")
    else:
        print(f"      \u2713 {path.split('/')[-1]}: every default-on control rendered")

sys.exit(1 if failed else 0)
PY
if [[ $? -eq 0 ]]; then ok "default-on controls render"; else bad "default-on controls render"; fi

# ---------------------------------------------------------------------------
step "Both paths create the same Kubernetes version"
# ---------------------------------------------------------------------------

# Each root module carries its own kubernetes_version default, so raising one and not the other
# gives the two paths different control planes with nothing to say so. scripts/lib/check_version_parity.py
python3 "$ROOT/scripts/lib/check_version_parity.py"
if [[ $? -eq 0 ]]; then ok "Kubernetes and kubectl versions"; else bad "Kubernetes and kubectl versions"; fi

# ---------------------------------------------------------------------------
step "Every sandboxed pod is pinned to the agents' node pool"
# ---------------------------------------------------------------------------

# A sandboxed pod on a general-purpose node runs in standard network policy mode, and can leave the
# next unsandboxed pod nominated there Pending with no node launched; keeping sandboxed pods on the
# agents' own pool avoids both. scripts/lib/check_sandbox_placement.py has the detail.
# The base renders above leave optional components off, so the chat UI -- the one sandboxed
# workload the chart renders outside the Agent definition -- is rendered on here.
for p in oss aws; do
  helm template placement gitops/base -f gitops/base/values.yaml -f "$RENDER_DIR/$p-values.yaml" \
    -f "$ROOT/scripts/lib/render-ingress-shape.yaml" --api-versions gateway.k8s.aws/v1 \
    > "$RENDER_DIR/placement-$p.yaml" 2>"$RENDER_DIR/placement-$p.err" || { sed 's/^/      /' "$RENDER_DIR/placement-$p.err" | head -5; }
done
python3 "$ROOT/scripts/lib/check_sandbox_placement.py" "$ROOT"/gitops/examples/*/*.yaml "$RENDER_DIR/base-oss.yaml" "$RENDER_DIR/base-aws.yaml" "$RENDER_DIR/placement-oss.yaml" "$RENDER_DIR/placement-aws.yaml"
if [[ $? -eq 0 ]]; then ok "sandboxed pods pinned to the agents' pool"; else bad "sandboxed pods pinned to the agents' pool"; fi

# ---------------------------------------------------------------------------
step "Nothing from one account is committed"
# ---------------------------------------------------------------------------

# These templates are published, so every value in the tree has to be a placeholder, an example, or
# true everywhere. A real account id, OIDC issuer, ECR host or VPC id is wrong three ways at once:
# the next reader starts with somebody else's ARNs, the owner has published their account and
# resource names, and the charts render cleanly against a cluster that reader cannot reach -- which
# is worse than failing, because it looks configured.
#
# The rendered terraform-values.yaml is the file this is really guarding. It is written by
# `terraform apply`, carries the account's values, and is meant to be committed TO A FORK only.
# The check's own cases first: a line naming an allowed value beside a real-looking one still fails.
python3 "$ROOT/scripts/lib/check_no_account_values.py" --self-test
if [[ $? -eq 0 ]]; then ok "the account-values check classifies its own cases"; else bad "the account-values check classifies its own cases"; fi
python3 "$ROOT/scripts/lib/check_no_account_values.py"
if [[ $? -eq 0 ]]; then ok "no account-specific values"; else bad "no account-specific values"; fi

# ---------------------------------------------------------------------------
step "Cross-references resolve"
# ---------------------------------------------------------------------------

# Every docs/ and gitops/ path named in a comment or a doc should exist. A stale path in a comment is
# how a reader is sent to a file that was renamed, which costs more than a wrong comment.
python3 - <<'PY'
import os, re, sys, glob

pattern = re.compile(r'\b((?:docs|gitops|terraform|scripts)/[A-Za-z0-9._*/-]+)')
failed = False
seen = set()

# A trailing slash is how prose names a directory, so it has to be checked rather than skipped:
# otherwise a reference to a deleted directory survives. A glob is
# still skipped, because it is a pattern rather than a path.

files = []
for root, dirs, names in os.walk("."):
    dirs[:] = [d for d in dirs if d not in {".git", ".terraform", "refs"}]
    for n in names:
        if n.endswith((".tf", ".yaml", ".yml", ".md", ".tfvars", ".sh")):
            files.append(os.path.join(root, n))

for path in files:
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        continue
    for m in pattern.finditer(text):
        # A match preceded by "/" or "." is a fragment of a longer path or a URL, not a
        # repository-relative reference -- "istio.io/latest/docs/overview/..." is not our docs/.
        if m.start() > 0 and text[m.start() - 1] in "/.":
            continue
        ref = m.group(1).rstrip(".,;:)").rstrip("/")
        if "*" in ref or ref in seen:
            continue
        # `*.local.yaml` is written by `terraform apply` and excluded by .gitignore -- the rendered
        # bootstrap objects carry this cluster's ARN and CA data, so they are deliberately not in
        # Git. A reference to one is a correct instruction, not a broken link.
        if ref.endswith(".local.yaml"):
            continue
        seen.add(ref)
        # Paths that exist only where this repository is developed, and that the published tree
        # (scripts/export-public.sh) leaves out: a reference to one is guarded where it is used.
        if ref.split("/")[0] in ("docs", "diagrams") or ref in (
                "scripts/export-public.sh", "scripts/render-diagrams.sh", "scripts/lib/diagram-checks.sh",
                "scripts/lib/check_public_ready.py", "scripts/lib/check_diagrams.py",
                "scripts/lib/check_diagram_geometry.py"):
            if not os.path.exists(ref):
                continue
        if not os.path.exists(ref):
            print(f"      ✗ {path}: references {ref}, which does not exist")
            failed = True

# RELATIVE MARKDOWN LINKS, which the pattern above cannot see.
#
# The pattern matches a repository-relative path written in prose, such as gitops/base. It does not
# match a link written relative to the file it is in -- `](../../gitops/base/README.md)` -- and
# every directory README is written that way, because a README has to read correctly on a file
# browser as well as in the repository root. Most READMEs carry such links, so an unchecked relative
# link is the most likely reference to rot next.
link = re.compile(r'\]\(([^)\s#]+)')
links = 0
for path in files:
    # comment-evidence.md quotes old comments verbatim, links and all; it is an archive, not a guide.
    if not path.endswith(".md") or path.endswith("docs/comment-evidence.md"):
        continue
    try:
        text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        continue
    base = os.path.dirname(path)
    for m in link.finditer(text):
        target = m.group(1)
        if target.startswith(("http://", "https://", "mailto:", "#")):
            continue
        resolved = os.path.normpath(os.path.join(base, target))
        key = ("link", resolved, path)
        if key in seen:
            continue
        seen.add(key)
        links += 1
        if not os.path.exists(resolved):
            print(f"      ✗ {path}: links to {target}, which does not exist")
            failed = True

if not failed:
    paths = len([x for x in seen if not isinstance(x, tuple)])
    print(f"      ✓ {paths} referenced paths and {links} relative links all exist")
sys.exit(1 if failed else 0)
PY
if [[ $? -eq 0 ]]; then ok "cross-references"; else bad "cross-references"; fi

# ---------------------------------------------------------------------------
printf '\n'
if [[ $fails -eq 0 ]]; then
  printf '%s%d/%d checks passed.%s\n' "$GREEN" "$checks" "$checks" "$RESET"
  warn "This checks syntax and rendering. The three things it cannot check are listed at the top of this script; do them on a cluster before relying on the egress boundary."
  exit 0
fi

printf '%s%d of %d checks failed.%s\n' "$RED" "$fails" "$checks" "$RESET"
exit 1
