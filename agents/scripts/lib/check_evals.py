#!/usr/bin/env python3
"""Agent evaluation renders with its judge bound to one subject and its runner admitted only where it must be.

    python3 scripts/lib/check_evals.py <repo root>

Renders the three charts that share the `evals` block -- gitops/base, agentgateway-config and
agent-evals -- with evaluation on and off, on both paths, and asserts:

  - OFF renders nothing: no runner namespace, no judge route or backend, no ingress rule on any
    agent, no runner objects. A flag that is off and still admits a namespace to every agent is the
    quiet failure.
  - the judge's route is /judge/<serviceAccount> and the gateway's authorization decides that prefix
    on the judge's own subject, FIRST -- so a /judge/ path never falls through to the agents'
    membership check, and the judge's subject (another namespace) cannot use /llm/ or /mcp.
  - each Agent's composed network policy admits the runner's pods, from the runner's namespace,
    on the agent's own port only.
  - the runner presents a token for the gateway's audience to the judge and a token for EACH
    agent's own audience to that agent, and never mounts the default service account token.
  - online grading exists on the langfuse backend only, the experiment is a suspended CronJob, and
    the runner's egress is the gateway and Langfuse on one path, 443 and the Pod Identity agent on
    the other, with DNS to the same resolver ranges as the agents (networkPolicy.dnsDestinations in
    gitops/base/values.yaml) on both.
  - Langfuse and the collector's export to it are one Terraform switch (enable_langfuse), the
    Langfuse file's prerequisites sync ahead of it, every OCI chart repository is registered for
    Argo CD, and the release gate's cases are read from Git.
"""
from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
import platform_render  # noqa: E402  the platform's Applications, rendered

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
NS = "agent-evals"
SA = "agent-evals"
failures: list[str] = []


def check(cond: bool, msg: str) -> None:
    if not cond:
        failures.append(msg)


def render(chart: str, values: dict, extra: list[str] = ()) -> list[dict]:
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        yaml.safe_dump(values, f)
    cmd = ["helm", "template", "v", str(ROOT / chart), "-f", str(ROOT / chart / "values.yaml"), *extra, "-f", f.name]
    out = subprocess.run(cmd, capture_output=True, text=True)
    Path(f.name).unlink(missing_ok=True)
    if out.returncode != 0:
        failures.append(f"helm template {chart} failed: {out.stderr.strip()[:400]}")
        return []
    return [d for d in yaml.safe_load_all(out.stdout) if d]


def evals_block(enabled: bool, path: str) -> dict:
    oss = path == "open-source"
    return {
        "enabled": enabled, "namespace": NS, "serviceAccount": SA,
        "backend": "langfuse" if oss else "agentcore",
        "judge": {
            "baseUrl": f"http://egress.agentgateway-system.svc.cluster.local:8080/judge/{SA}" if oss
            else "https://gw.example.com/inference/v1",
            "model": "judge" if oss else "bedrock/openai.gpt-oss-120b",
            "audience": "agentgateway",
            "roleArn": "arn:aws:iam::111122223333:role/eks-agents/c-evals-judge" if oss else "",
            "bedrockModelId": "",
        },
        "agentcore": {"logGroup": "" if oss else "/aws/eks/c/agents", "region": "us-west-2",
                      "resultsName": "c-release-gate"},
    }


def base_values(enabled: bool, path: str) -> dict:
    v = {"cluster": "c", "path": path, "evals": evals_block(enabled, path),
         "namespaces": {"evals": NS}}
    if path == "aws-services":
        v["gateway"] = {"hostname": "h", "modelEndpoint": "https://h/inference/v1", "mcpEndpoint": "https://h/mcp"}
        v["model"] = {"gatewayModelId": "bedrock/x"}
        v["observability"] = {"collectorNamespace": "opentelemetry-operator-system"}
    return v


def rgd_template(docs: list[dict]) -> str:
    for d in docs:
        if d.get("kind") == "ResourceGraphDefinition" and d["spec"]["schema"]["kind"] == "Agent":
            for r in d["spec"]["resources"]:
                if r["id"] == "networkPolicy":
                    return yaml.safe_dump(r["template"])
    return ""


def by_kind(docs, kind):
    return [d for d in docs if d.get("kind") == kind]


null_shape = ["-f", str(ROOT / "scripts/lib/render-null-shape.yaml")]

# --- gitops/base ---------------------------------------------------------------------------------
for path in ("open-source", "aws-services"):
    for enabled in (True, False):
        docs = render("gitops/base", base_values(enabled, path), null_shape)
        nss = [d["metadata"]["name"] for d in by_kind(docs, "Namespace")]
        anp = rgd_template(docs)
        tag = f"base {path} evals={'on' if enabled else 'off'}"
        if enabled:
            check(NS in nss, f"{tag}: no {NS} Namespace")
            ns = next((d for d in by_kind(docs, "Namespace") if d["metadata"]["name"] == NS), {})
            labels = ns.get("metadata", {}).get("labels", {})
            check(labels.get("pod-security.kubernetes.io/enforce") == "restricted", f"{tag}: {NS} is not PSA restricted")
            check("eks-agents/admission" not in labels, f"{tag}: {NS} is labelled as an agent namespace")
            check(f"kubernetes.io/metadata.name: {NS}" in anp and "app.kubernetes.io/name: agent-evals" in anp,
                  f"{tag}: the Agent's network policy does not admit the runner's pods from {NS}")
            m = re.search(r"namespaceSelector:\s*\n\s*matchLabels:\s*\n\s*kubernetes.io/metadata.name: agent-evals[\s\S]*?ports:\s*\n\s*- port: (\S+)", anp)
            check(bool(m) and m.group(1).strip("'\"") == "${schema.spec.port}",
                  f"{tag}: the runner's ingress rule is not limited to the agent's own port")
        # Both paths, evaluation on or off: an agent that cannot reach the collector exports no
        # span, and every trace-reading evaluator then grades nothing. The rule belongs on both
        # paths.
        coll = "monitoring" if path == "open-source" else "opentelemetry-operator-system"
        check(f"kubernetes.io/metadata.name: {coll}" in anp and "4318" in anp,
              f"{tag}: the Agent's network policy has no egress to the collector in {coll}")
        if not enabled:
            check(NS not in nss, f"{tag}: {NS} Namespace rendered with evaluation off")
            check("agent-evals" not in anp, f"{tag}: the Agent's network policy admits the runner with evaluation off")

# --- agentgateway-config -------------------------------------------------------------------------
agw_base = {"accountId": "111122223333", "region": "us-west-2", "cluster": "c",
            "oidcIssuerUrl": "https://oidc.example.com", "agentResource": {"enabled": True}}
for enabled in (True, False):
    docs = render("gitops/charts/agentgateway-config", {**agw_base, "evals": evals_block(enabled, "open-source")})
    tag = f"agentgateway-config evals={'on' if enabled else 'off'}"
    routes = [r for r in by_kind(docs, "HTTPRoute") if r["metadata"]["name"].startswith("judge-")]
    backends = [b for b in by_kind(docs, "AgentgatewayBackend") if b["metadata"]["name"].startswith("bedrock-judge-")]
    auth = next((p for p in by_kind(docs, "AgentgatewayPolicy") if p["metadata"]["name"] == "agent-inbound-auth"), None)
    exprs = (auth or {}).get("spec", {}).get("traffic", {}).get("authorization", {}).get("policy", {}).get("matchExpressions", [])
    expr = " ".join(exprs)
    if enabled:
        check(len(routes) == 1, f"{tag}: expected one judge route, got {len(routes)}")
        if routes:
            paths = [m["path"]["value"] for rule in routes[0]["spec"]["rules"] for m in rule["matches"]]
            check(paths == [f"/judge/{SA}"], f"{tag}: judge route matches {paths}, want /judge/{SA}")
        check(len(backends) == 1, f"{tag}: expected one judge backend, got {len(backends)}")
        if backends:
            ar = backends[0]["spec"]["policies"]["auth"]["aws"]["assumeRole"]
            check(ar["roleArn"].endswith("-evals-judge"), f"{tag}: judge backend assumes {ar['roleArn']}")
        check(expr.startswith('request.path.startsWith("/judge/") ? jwt.sub == "system:serviceaccount:%s:"' % NS),
              f"{tag}: the gateway does not decide /judge/ on the judge's subject first: {expr[:160]}")
    else:
        check(not routes and not backends, f"{tag}: judge route or backend rendered with evaluation off")
        check("/judge/" not in expr, f"{tag}: the authorization expression mentions /judge/ with evaluation off")

# --- agent-evals ---------------------------------------------------------------------------------
agents = {"research": {"namespace": "agents", "port": 8080,
                       "cases": [{"name": "capital", "input": "Capital of France?", "expectedOutput": "Paris"}]},
          "specialist": {"cases": [{"name": "x", "input": "y"}]}}
for path in ("open-source", "aws-services"):
    docs = render("gitops/charts/agent-evals", {
        "evals": evals_block(True, path), "region": "us-west-2",
        "registry": {"agents/evals": "111122223333.dkr.ecr.us-west-2.amazonaws.com/agents/evals"},
        "experiment": {"agents": agents}})
    tag = f"agent-evals {path}"
    crons = {c["metadata"]["name"]: c for c in by_kind(docs, "CronJob")}
    check(("agent-evals-online" in crons) == (path == "open-source"),
          f"{tag}: online CronJob present={('agent-evals-online' in crons)}; it belongs to the langfuse backend only")
    exp = crons.get("agent-evals-experiment")
    check(exp is not None and exp["spec"].get("suspend") is True, f"{tag}: the experiment is not a suspended CronJob")
    for name, c in crons.items():
        pod = c["spec"]["jobTemplate"]["spec"]["template"]["spec"]
        check(pod.get("automountServiceAccountToken") is False, f"{tag}/{name}: mounts the default service account token")
        check(c["spec"]["jobTemplate"]["spec"].get("backoffLimit") == 0, f"{tag}/{name}: retries a failed run")
        auds = {v["name"]: v["projected"]["sources"][0]["serviceAccountToken"]["audience"]
                for v in pod["volumes"] if "projected" in v}
        check(auds.get("gateway-identity") == "agentgateway", f"{tag}/{name}: judge token audience is {auds.get('gateway-identity')}")
        if name == "agent-evals-experiment":
            for a in agents:
                check(auds.get(f"agent-{a}") == a, f"{tag}/{name}: token for agent {a} has audience {auds.get(f'agent-{a}')}")
        else:
            check(not any(k.startswith("agent-") for k in auds), f"{tag}/{name}: the online run holds agent tokens")
    cm = next((c for c in by_kind(docs, "ConfigMap") if c["metadata"]["name"] == "agent-evals"), None)
    cfg = yaml.safe_load(cm["data"]["config.yaml"]) if cm else {}
    check(cfg.get("experiment", {}).get("agents", {}).get("research", {}).get("url")
          == "http://research.agents.svc.cluster.local:8080/chat", f"{tag}: research's /chat URL is wrong in the config")
    np = next(iter(by_kind(docs, "NetworkPolicy")), None)
    egress = yaml.safe_dump(np["spec"]["egress"]) if np else ""
    check(np is not None and np["spec"].get("ingress") == [], f"{tag}: the runner admits ingress")
    if path == "open-source":
        check("kubernetes.io/metadata.name: langfuse" in egress, f"{tag}: no egress to Langfuse")
        check("port: 443" not in egress, f"{tag}: open-source runner has 443 egress to anywhere")
    else:
        check("port: 443" in egress and "169.254.170.23/32" in egress, f"{tag}: no 443 / Pod Identity egress")
        check("langfuse" not in egress, f"{tag}: AWS runner has egress to Langfuse")
    check("eks-agents/agent: research" in egress and "eks-agents/agent: specialist" in egress,
          f"{tag}: egress is not scoped to each agent's pods")
    # DNS goes to the resolver ranges the agents' DNS rule uses, and nowhere else: a port-53 rule
    # with no `to` is DNS to any address, a resolver on the internet included.
    want_dns = yaml.safe_load((ROOT / "gitops/base/values.yaml").read_text())["networkPolicy"]["dnsDestinations"]
    for rule in (np or {}).get("spec", {}).get("egress", []):
        if any(p.get("port") == 53 for p in rule.get("ports", [])):
            got = [peer.get("ipBlock", {}).get("cidr") for peer in rule.get("to", [])]
            check(got == want_dns, f"{tag}: DNS egress goes to {got or 'any address'}, not networkPolicy.dnsDestinations {want_dns}")

    off = render("gitops/charts/agent-evals", {"evals": evals_block(False, path)})
    check(off == [], f"{tag}: renders {len(off)} objects with evaluation off")

# --- the runner reads the Secret Terraform actually creates -------------------------------------
# A chart naming langfuse-api while platform-secrets creates langfuse-evals-api leaves every
# runner pod in CreateContainerConfigError.
chart_secret = yaml.safe_load((ROOT / "gitops/charts/agent-evals/values.yaml").read_text())["langfuse"]["existingSecret"]
ps = (ROOT / "terraform/modules/platform-secrets/main.tf").read_text()
m = re.search(r"evals_secrets = \{ for name, spec in \{\s*\n\s*([a-z0-9-]+) = \{", ps)
check(bool(m) and m.group(1) == chart_secret,
      f"agent-evals reads Secret {chart_secret!r} but platform-secrets creates {m.group(1) if m else None!r}")

# --- the collector and Langfuse ------------------------------------------------------------------
oss_platform = platform_render.render(ROOT, "open-source")
obs = oss_platform.get("50-observability.yaml", [])
coll = next((d for d in obs if d and d["metadata"]["name"] == "opentelemetry-collector"), None)
coll_chart = next((x for x in (coll or {}).get("spec", {}).get("sources", []) if x.get("chart")), {})
coll_vo = coll_chart.get("helm", {}).get("valuesObject", {})
cfg = coll_vo.get("config", {})
check("otlphttp/langfuse" in cfg.get("exporters", {}), "collector: no otlphttp/langfuse exporter defined")
# The export header's variable comes only from collector-values.yaml: Terraform renders it there
# with enable_langfuse, as a REQUIRED ref, so the pod waits for the Secret. As an optional ref, a
# collector that starts before the Secret exists runs with it unset and Langfuse refuses every
# span with 401. With the committed (Langfuse-off) file, the Application sets none.
check("extraEnvs" not in coll_vo,
      "collector: extraEnvs are set with Langfuse off; they must come only from collector-values.yaml")
tf_main = (ROOT / "terraform/open-source/main.tf").read_text()
blk = tf_main[tf_main.find('resource "local_file" "collector_values"'):]
blk = blk[:blk.find("\nresource ")]
check('name      = "LANGFUSE_OTLP_AUTHORIZATION"' in blk and 'name = "langfuse-otlp"' in blk
      and "var.enable_langfuse ?" in blk and not re.search(r"optional\s*=", blk),
      "collector: Terraform does not render a required LANGFUSE_OTLP_AUTHORIZATION ref with enable_langfuse")
lf_apps = {d["metadata"]["name"]: d for d in oss_platform.get("51-langfuse.yaml", [])}
lf = lf_apps.get("langfuse", {})

# Langfuse and the collector's export to it are ONE switch. The root Application passes the
# rendered collector-values.yaml in as `collector`, and the Application carries its exporters and
# extraEnvs INSIDE its one valuesObject. Never as helm.values beside it: Argo CD uses valuesObject
# instead of values when both are set, so the exporters would never apply and the release gate
# fails with "never reached the trace backend". Terraform renders both that file and the exclusion
# from var.enable_langfuse.
traces = cfg.get("service", {}).get("pipelines", {}).get("traces", {})
collector_values = yaml.safe_load((ROOT / "gitops/platform/open-source/collector-values.yaml").read_text())
check(not coll_chart.get("helm", {}).get("values"),
      "collector: helm.values is set beside valuesObject, and Argo CD ignores it")
check(traces.get("exporters") == collector_values["config"]["service"]["pipelines"]["traces"]["exporters"],
      "collector: valuesObject's traces exporters are not collector-values.yaml's")
lf_on = {"config": {"service": {"pipelines": {"traces": {"exporters": ["debug", "otlphttp/langfuse"]}}}},
         "extraEnvs": [{"name": "LANGFUSE_OTLP_AUTHORIZATION",
                        "valueFrom": {"secretKeyRef": {"name": "langfuse-otlp", "key": "authorization"}}}]}
on_obs = platform_render.render(ROOT, "open-source", overrides={"collector": lf_on}).get("50-observability.yaml", [])
on_coll = next((d for d in on_obs if d and d["metadata"]["name"] == "opentelemetry-collector"), {})
on_vo = next((x for x in on_coll.get("spec", {}).get("sources", []) if x.get("chart")), {}).get("helm", {}).get("valuesObject", {})
check(on_vo.get("config", {}).get("service", {}).get("pipelines", {}).get("traces", {}).get("exporters") == ["debug", "otlphttp/langfuse"],
      "collector: with Langfuse on, valuesObject's traces do not export to otlphttp/langfuse")
check(on_vo.get("extraEnvs") == lf_on["extraEnvs"],
      "collector: with Langfuse on, valuesObject does not carry collector-values.yaml's required LANGFUSE_OTLP_AUTHORIZATION ref")
oss_tf = (ROOT / "terraform/open-source/main.tf").read_text()
check('var.enable_langfuse ? [] : ["51-langfuse.yaml"]' in oss_tf,
      "terraform/open-source: 51-langfuse.yaml is not excluded from enable_langfuse")
check('var.enable_langfuse ? ["debug", "otlphttp/langfuse"] : ["debug"]' in oss_tf,
      "terraform/open-source: collector-values.yaml is not rendered from enable_langfuse")
# A values file is never rendered as a manifest: the chart renders only templates/, and the
# .helmignore keeps every *-values.yaml out of the chart, so a values file cannot become one.
for root in ("open-source", "aws-services"):
    ignore = (ROOT / f"gitops/platform/{root}/.helmignore").read_text().split()
    check("*-values.yaml" in ignore,
          f"gitops/platform/{root}/.helmignore: not every *-values.yaml is left out of the chart")
    check(not any(f.endswith("-values.yaml") for f in platform_render.render(ROOT, root)),
          f"gitops/platform/{root}: a *-values.yaml renders as a manifest")
placeholder = collector_values
check(placeholder["config"]["service"]["pipelines"]["traces"]["exporters"] == ["debug"],
      "collector-values.yaml: the committed copy is not the Langfuse-off form")

# Langfuse's prerequisites are Applications, ordered ahead of it, and every Application in the file
# syncs on its own: the gate is Terraform's exclusion, not a missing syncPolicy.
wave = lambda n: int(lf_apps.get(n, {}).get("metadata", {}).get("annotations", {}).get("argocd.argoproj.io/sync-wave", 99))
check(wave("cert-manager") < wave("clickhouse-operator") < wave("langfuse"),
      "51-langfuse.yaml: cert-manager, then the ClickHouse operator, then Langfuse is not the wave order")
check(all(a["spec"].get("syncPolicy", {}).get("automated") is not None for a in lf_apps.values()),
      "51-langfuse.yaml: an Application has no automated sync, so enable_langfuse would not install it")

# Every scheme-less (OCI) chart repository the open source Applications use is registered for Argo CD,
# by the base chart's 05-oci-repositories.yaml (each one with the component that needs it).
import re as _re
registered = set(_re.findall(r'"([a-z0-9.-]+\.[a-z]{2,}/[a-z0-9./-]+)"\)', (ROOT / "gitops/base/templates/05-oci-repositories.yaml").read_text()))
used = set()
for docs in oss_platform.values():
    for d in docs:
        if d.get("kind") != "Application":
            continue
        for x in [d["spec"].get("source")] + list(d["spec"].get("sources") or []):
            r = (x or {}).get("repoURL", "")
            if x and x.get("chart") and r and "://" not in r:
                used.add(r)
check(used <= registered, f"05-oci-repositories.yaml: OCI chart repositories not registered: {sorted(used - registered)}")

# The release gate's cases live in Git, read by the Application, on both paths.
# The Application's helm.values is terraform-values.yaml with agent-evals-values.yaml merged over
# it, so every value the platform team declares there reaches the chart and wins.
def declared_in(want, got) -> bool:
    if isinstance(want, dict):
        return isinstance(got, dict) and all(k in got and declared_in(v, got[k]) for k, v in want.items())
    return want == got

for root in ("open-source", "aws-services"):
    evals_file = ROOT / f"gitops/platform/{root}/agent-evals-values.yaml"
    app = next(iter(platform_render.render(ROOT, root).get("52-agent-evals.yaml", [])), {})
    got = yaml.safe_load(((app.get("spec") or {}).get("source") or {}).get("helm", {}).get("values") or "null")
    check(evals_file.exists() and declared_in(yaml.safe_load(evals_file.read_text()) or {}, got),
          f"{root}: 52-agent-evals.yaml's helm.values does not carry agent-evals-values.yaml over terraform-values.yaml")
hdrs = cfg.get("exporters", {}).get("otlphttp/langfuse", {}).get("headers", {})
check(str(hdrs.get("x-langfuse-ingestion-version")) == "4",
      "collector: the Langfuse exporter does not send x-langfuse-ingestion-version: 4, so spans can take 15 minutes to be readable")
s3 = lf["spec"]["source"]["helm"]["valuesObject"].get("s3", {})
size_gi = float(str(s3.get("allInOne", {}).get("data", {}).get("size", "50Gi")).rstrip("Gi"))
limit_mb = float(s3.get("master", {}).get("volumeSizeLimitMB", 1000))
check(size_gi * 1024 / limit_mb >= 8,
      f"langfuse: SeaweedFS disk {size_gi}Gi / volumeSizeLimitMB {limit_mb} fits fewer than 8 volumes; it creates none and refuses every write")
env = {e["name"]: e for e in lf["spec"]["source"]["helm"]["valuesObject"]["langfuse"].get("additionalEnv", [])}
for k in ("LANGFUSE_INIT_PROJECT_PUBLIC_KEY", "LANGFUSE_INIT_PROJECT_SECRET_KEY", "LANGFUSE_INIT_USER_PASSWORD"):
    check(env.get(k, {}).get("valueFrom", {}).get("secretKeyRef", {}).get("name") == "langfuse-init",
          f"langfuse: {k} is not read from the langfuse-init Secret")

if failures:
    for f in failures:
        print(f"      ✗ {f}")
    sys.exit(1)
print("      ✓ evaluation renders on and off, on both paths, with the judge and runner bound as designed")
