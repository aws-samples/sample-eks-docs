#!/usr/bin/env python3
"""An Agent runs as an Agent Sandbox Sandbox by default, as a Deployment on request, and nothing else.

    python3 scripts/lib/check_agent_runtime.py <repo root>

Renders gitops/base on both paths and asserts:

  - the schema's `runtime` defaults to sandbox and allows only sandbox, deployment and tasks; tasks
    composes none of the long-lived workloads, and its ScaledJob is rendered only with tasks.enabled
    (kro rejects the whole Agent kind if a graph names keda.sh on a cluster without KEDA);
  - exactly one workload is composed for every combination of runtime, workspace and expose -- a
    missing or overlapping includeWhen composes two pods for one agent, or none;
  - every variant carries the SAME pod (_agent-pod.tpl) but for the probes, so no control holds on
    one runtime and not the other; serving variants carry exec probes, `expose: none` ones none
    (a network probe on a sandboxed pod in ambient crash-loops it);
  - the workspace variant adds a ReadWriteOncePod claim named `workspace`, and the admission
    policy refuses workspaceSize off the sandbox runtime and any change to it after creation;
  - the container is told its port (AGENT_PORT), which the Service and the probe point at;
  - the Sandbox sets service: false (the Agent composes its own Service) and failedPodPolicy: Recreate
    (the upstream default leaves an evicted pod down);
  - an admission policy, bound to Deny, refuses replicas above 1 on a Sandbox (kro's schema cannot);
  - kro is granted agents.x-k8s.io sandboxes, without which the Sandbox is never created and nothing
    says so;
  - on both paths the Agent Sandbox Application and the CRD-only Applications sync ahead of the base
    chart, because kro rejects the whole Agent kind while any composed kind is unregistered.
"""
from __future__ import annotations

import ast
import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import platform_render  # noqa: E402  the platform's Applications, rendered

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    if not cond:
        failures.append(msg)


def render(path: str) -> list[dict]:
    values = {"cluster": "c", "path": path, "capabilities": {"kro": {"roleName": "c-capability-kro"}, "ack": {"roleName": "c-capability-ack"}}}
    if path == "aws-services":
        values["gateway"] = {"hostname": "h", "modelEndpoint": "https://h/inference/v1", "mcpEndpoint": "https://h/mcp"}
        values["model"] = {"gatewayModelId": "bedrock/x"}
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        yaml.safe_dump(values, f)
    out = subprocess.run(["helm", "template", "v", str(ROOT / "gitops/base"),
                          "-f", str(ROOT / "gitops/base/values.yaml"),
                          "-f", str(ROOT / "scripts/lib/render-null-shape.yaml"), "-f", f.name],
                         capture_output=True, text=True)
    Path(f.name).unlink(missing_ok=True)
    if out.returncode != 0:
        failures.append(f"helm template gitops/base ({path}) failed: {out.stderr.strip()[:300]}")
        return []
    return [d for d in yaml.safe_load_all(out.stdout) if d]


def wave(app: dict) -> int:
    return int(((app.get("metadata") or {}).get("annotations") or {}).get("argocd.argoproj.io/sync-wave", "0"))


for path in ("open-source", "aws-services"):
    docs = render(path)
    rgd = next((d for d in docs if d.get("kind") == "ResourceGraphDefinition"
                and d["spec"]["schema"]["kind"] == "Agent"), None)
    if not rgd:
        failures.append(f"{path}: no Agent ResourceGraphDefinition rendered")
        continue
    schema = rgd["spec"]["schema"]
    runtime = schema["spec"].get("runtime", "")
    check('default="sandbox"' in runtime and 'enum="sandbox,deployment,tasks"' in runtime,
          f"{path}: runtime is {runtime!r}, want default sandbox, enum sandbox,deployment,tasks")
    check(not any(r.get("template", {}).get("kind") == "ScaledJob" for r in rgd["spec"]["resources"]),
          f"{path}: a ScaledJob is composed with tasks off, which names keda.sh on a cluster without KEDA")
    # kro's schema has no cross-field validation (a `validation` block is dropped on apply), so the
    # one-pod rule is an admission policy, bound to Deny.
    vap = next((d for d in docs if d.get("kind") == "ValidatingAdmissionPolicy"
                and d["metadata"]["name"] == "eks-agents-agent-runtime"), None)
    vapb = next((d for d in docs if d.get("kind") == "ValidatingAdmissionPolicyBinding"
                 and d["spec"].get("policyName") == "eks-agents-agent-runtime"), None)
    rule = " ".join(v.get("expression", "") for v in (vap or {}).get("spec", {}).get("validations", []))
    check(vap is not None and "object.spec.replicas <= 1" in rule and "'deployment'" in rule,
          f"{path}: no admission policy refuses replicas > 1 on the sandbox runtime")
    check(vapb is not None and vapb["spec"].get("validationActions") == ["Deny"],
          f"{path}: the runtime admission policy is not bound to Deny")
    check("validation" not in schema, f"{path}: the RGD carries a schema `validation` block kro drops")

    check("workspaceSize" in rule and "oldObject.spec" in rule,
          f"{path}: the admission policy does not guard workspaceSize")

    # modelArns is joined unescaped into the agent's IAM policy JSON, so admission is what keeps
    # each entry one Bedrock ARN. The pattern must admit every ARN an example ships and refuse a
    # quote, a bare "*" and a non-Bedrock ARN.
    m = re.search(r"modelArns\.all\(a, a\.matches\(\s*'([^']+)'\)\)", rule)
    check(m is not None, f"{path}: the admission policy does not pin modelArns to Bedrock ARNs")
    if m:
        arn = re.compile(m.group(1))
        for f in (ROOT / "gitops/examples").rglob("*.yaml"):
            for d in yaml.safe_load_all(f.read_text()):
                if d and d.get("kind") == "Agent":
                    for a in (d.get("spec") or {}).get("modelArns") or []:
                        a = a.replace("REGION", "us-west-2").replace("ACCOUNT_ID", "111122223333")
                        check(bool(arn.match(a)), f"{path}: admission refuses {a} from {f.relative_to(ROOT)}")
        for a in ("*", "arn:aws:s3:::bucket/*",
                  'arn:aws:bedrock:us-east-1::foundation-model/x"]},{"Effect":"Allow","Action":"s3:*","Resource":["*'):
            check(not arn.match(a), f"{path}: admission admits modelArns entry {a!r}")
    check("namespaceObject.metadata" in rule and "eks-agents/admission" in rule,
          f"{path}: the admission policy admits an Agent outside an agent namespace")

    res = {r["id"]: r for r in rgd["spec"]["resources"]}
    variants = {i: r for i, r in res.items() if r["template"].get("kind") in ("Deployment", "Sandbox")}
    want = {"deployment", "deploymentUnprobed", "sandbox", "sandboxUnprobed",
            "sandboxWorkspace", "sandboxWorkspaceUnprobed"}
    check(set(variants) == want, f"{path}: workload variants are {sorted(variants)}, want {sorted(want)}")

    # Exactly one variant per combination: evaluate each includeWhen. The conditions are string
    # comparisons joined by && and ||, so they are parsed and walked rather than run: anything else
    # in one is an error here, not code.
    def _bool_expr(e: str) -> bool:
        def ev(n):
            if isinstance(n, ast.Expression):
                return ev(n.body)
            if isinstance(n, ast.BoolOp) and isinstance(n.op, (ast.And, ast.Or)):
                vals = [ev(v) for v in n.values]
                return all(vals) if isinstance(n.op, ast.And) else any(vals)
            if isinstance(n, ast.Compare) and len(n.ops) == 1 and isinstance(n.ops[0], (ast.Eq, ast.NotEq)):
                a, b = ev(n.left), ev(n.comparators[0])
                return (a == b) if isinstance(n.ops[0], ast.Eq) else (a != b)
            if isinstance(n, ast.Constant) and isinstance(n.value, str):
                return n.value
            raise ValueError(f"unsupported includeWhen expression: {e}")
        return bool(ev(ast.parse(e, mode="eval")))

    def matches(r: dict, runtime: str, ws: str, expose: str) -> bool:
        conds = r.get("includeWhen") or []
        env = {"runtime": runtime, "workspaceSize": ws, "expose": expose}
        ok = True
        for c in conds:
            e = c.strip()[2:-1].replace("&&", " and ").replace("||", " or ")
            for k, v in env.items():
                e = e.replace(f"schema.spec.{k}", repr(v))
            ok = ok and _bool_expr(e)
        return ok
    for expose in ("none",):
        hit = [i for i, r in variants.items() if matches(r, "tasks", "", expose)]
        check(not hit, f"{path}: runtime=tasks also composes {hit}, a long-lived pod beside its task pods")
    for runtime in ("sandbox", "deployment"):
        for ws in ("", "1Gi"):
            for expose in ("none", "cluster", "route"):
                hit = [i for i, r in variants.items() if matches(r, runtime, ws, expose)]
                if runtime == "deployment" and ws:
                    continue   # refused at admission
                check(len(hit) == 1, f"{path}: runtime={runtime} workspaceSize={ws!r} expose={expose} composes {hit or 'nothing'}")

    def pod(r: dict) -> dict:
        t = r["template"]
        return t["spec"]["template"] if t["kind"] == "Deployment" else t["spec"]["podTemplate"]

    def strip_probes(p: dict) -> dict:
        p = yaml.safe_load(yaml.safe_dump(p))
        for c in p["spec"]["containers"]:
            c.pop("readinessProbe", None); c.pop("livenessProbe", None)
        return p
    if variants:
        base_pod = strip_probes(pod(next(iter(variants.values()))))
        for i, r in variants.items():
            p = pod(r)
            check(strip_probes(p) == base_pod, f"{path}: {i}'s pod differs from the others beyond its probes")
            c = p["spec"]["containers"][0]
            if i.endswith("Unprobed"):
                check("readinessProbe" not in c and "livenessProbe" not in c, f"{path}: {i} carries a probe")
            else:
                for k in ("readinessProbe", "livenessProbe"):
                    check("exec" in (c.get(k) or {}), f"{path}: {i}'s {k} is not an exec probe")
            check(p["spec"].get("runtimeClassName") == "isolated-sandbox", f"{path}: {i}'s pod is not in the isolated-sandbox runtime class")
            check(any(e.get("name") == "AGENT_PORT" for e in c.get("env") or []), f"{path}: {i} does not set AGENT_PORT")
            t = r["template"]
            if t["kind"] == "Sandbox":
                check(t["apiVersion"] == "agents.x-k8s.io/v1beta1", f"{path}: {i} is {t['apiVersion']}")
                check(t["spec"].get("service") is False, f"{path}: {i} does not set service: false")
                check(t["spec"].get("failedPodPolicy") == "Recreate", f"{path}: {i} does not set failedPodPolicy: Recreate")
                vct = t["spec"].get("volumeClaimTemplates")
                if "Workspace" in i:
                    check(bool(vct) and vct[0]["metadata"]["name"] == "workspace"
                          and vct[0]["spec"]["accessModes"] == ["ReadWriteOncePod"],
                          f"{path}: {i} has no ReadWriteOncePod `workspace` claim")
                else:
                    check(not vct, f"{path}: {i} carries a volume claim template")
    check("availableReplicas" not in str(schema.get("status")),
          f"{path}: status reads the Deployment, which the default runtime does not compose")

    granted = any("agents.x-k8s.io" in (r.get("apiGroups") or []) and "sandboxes" in (r.get("resources") or [])
                  for d in docs if d.get("kind") in ("ClusterRole", "Role") for r in d.get("rules") or [])
    check(granted, f"{path}: kro is not granted agents.x-k8s.io sandboxes")

    apps = platform_render.applications(ROOT, path)
    base = wave(apps["eks-agents-base"])
    for name in ("agent-sandbox", "gateway-api-crds", "aws-gateway-api-crds"):
        if name in apps:
            check(wave(apps[name]) < base, f"{path}: {name} syncs at wave {wave(apps[name])}, not ahead of the base chart ({base})")
    sb = apps.get("agent-sandbox", {})
    vo = ((sb.get("spec") or {}).get("source") or {}).get("helm", {}).get("valuesObject", {})
    check((vo.get("namespace") or {}).get("create") is False,
          f"{path}: agent-sandbox's chart creates its own namespace, which install-platform.sh's --create-namespace collides with")

if failures:
    for f in failures:
        print(f"      ✗ {f}")
    sys.exit(1)
print("      ✓ an Agent is a Sandbox by default, a Deployment on request, with one pod definition and the CRDs ahead of it")
