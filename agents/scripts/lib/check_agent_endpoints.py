#!/usr/bin/env python3
"""Check the agent resource hands an agent usable model and tool endpoints.

    check_agent_endpoints.py <render-dir>

Why it exists: on the AWS services path, a model endpoint that defaults to
`.Values.gateway.hostname` -- a bare hostname, no scheme, no path -- is set as OPENAI_BASE_URL, and
if the gateway it names has no inference target there is no model endpoint on that path at all.
Every object is healthy, the agent deploys and passes its readiness probe, and no model call can
ever succeed. Nothing in the render flags it, because a string is a valid string.

Five assertions, each one a failure that reported healthy:

  0. The schema DEFAULTS are empty and the pod falls back to the platform's gateway. A schema default
     is written into the Agent when it is created, so a default naming the gateway freezes it: an
     Agent created with the gateway off keeps an empty URL after the gateway is turned on, and
     calls "/llm/<name>" with no host. The checks below read the fallback.
  1. The model base URL carries a scheme. A bare hostname is not a base URL.
  2. The model endpoint and the MCP endpoint are different. One gateway serves tools and models on
     different paths, so an agent handed one URL for both has whichever it was not broken.
  3. On the AWS path the model endpoint carries /inference/v1, which is the path an inference target
     serves. Pointing at the gateway root reaches the MCP surface instead.
  4. On the open source path the model route is per agent (/llm/<name>), because the gateway's
     assumeRole.roleArn must be a literal ARN and one backend cannot derive the caller's role.

What it cannot check is whether the gateway really has an inference target, or whether a model call
returns anything. That needs an account and a cluster: scripts/exercise.sh.
"""
import glob
import os
import pathlib
import re
import sys

try:
    import yaml
except ImportError:
    print("      ! PyYAML not installed; skipping the agent endpoint check")
    sys.exit(0)


def agent_rgd(path):
    """The ResourceGraphDefinition that defines the Agent kind, if this file holds one."""
    for doc in yaml.safe_load_all(open(path, encoding="utf-8", errors="ignore")):
        if not isinstance(doc, dict):
            continue
        if doc.get("kind") != "ResourceGraphDefinition":
            continue
        schema = (doc.get("spec") or {}).get("schema") or {}
        if schema.get("kind") == "Agent":
            return doc
    return None


def pod_env(rgd):
    """Every env entry on the agent container, as a name -> value dict."""
    out = {}
    text = yaml.safe_dump(rgd, width=1 << 30)   # unfolded: a folded value is half a value
    # The Deployment sits inside the graph's resource list as a template, so walk the dumped text
    # rather than guessing the nesting. Each entry is a - name:/value: pair.
    for m in re.finditer(r"- name:\s*(\S+)\s*\n\s*value:\s*(\S.*)", text):
        out.setdefault(m.group(1), m.group(2).strip().strip("'\""))
    return out


def fallback(env_value):
    """The platform URL a pod falls back to: the else-branch of `${spec.x != "" ? spec.x : "URL"}`."""
    m = re.search(r':\s*"([^"]*)"\}', env_value or "")
    return m.group(1) if m else None


def schema_default(rgd, field):
    spec = ((rgd.get("spec") or {}).get("schema") or {}).get("spec") or {}
    raw = spec.get(field)
    if not isinstance(raw, str):
        return None
    m = re.search(r'default="([^"]*)"', raw)
    return m.group(1) if m else None


def cross_chart_gateway_name(root):
    """gitops/base's gateway.serviceName must equal agentgateway-config's gateway.name.

    AgentGateway's controller materialises one Service per Gateway object, taking the Gateway's
    name. So the name an agent addresses is authored in one chart and created by another, with
    nothing between them to notice a disagreement.

    The disagreement presents as ConnectTimeout from the agent: a base chart that defaults
    to the CONTROLLER's Service ("agentgateway"), which serves xDS and metrics on
    9977/9092/9093, reaches nothing on the data plane port.
    """
    def value_of(path, key):
        text = (root / path).read_text()
        m = re.search(rf"^\s*{key}:\s*(\S+)", text, re.M)
        return m.group(1).strip().strip('"\'') if m else None

    base = value_of("gitops/base/values.yaml", "serviceName")
    agw = value_of("gitops/charts/agentgateway-config/values.yaml", "name")

    if base is None:
        return ["gitops/base/values.yaml has no gateway.serviceName"]
    if agw is None:
        return ["gitops/charts/agentgateway-config/values.yaml has no gateway.name"]
    if base != agw:
        return [f"gitops/base gateway.serviceName is {base!r} but agentgateway-config gateway.name "
                f"is {agw!r}. An agent would address a Service that does not exist, and the symptom "
                f"is ConnectTimeout rather than an error anywhere"]
    return []


def main():
    render_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    failed = False
    checked = 0

    repo_root = pathlib.Path(__file__).resolve().parents[2]
    for problem in cross_chart_gateway_name(repo_root):
        print(f"      ✗ {problem}")
        failed = True

    for path in sorted(glob.glob(os.path.join(render_dir, "base-*.yaml"))):
        rgd = agent_rgd(path)
        if rgd is None:
            continue
        name = os.path.basename(path)
        is_oss = "oss" in name
        problems = []

        env = pod_env(rgd)
        for field in ("gatewayBaseUrl", "mcpUrl"):
            d = schema_default(rgd, field)
            if d:
                problems.append(
                    f"{field} defaults to {d!r}. A schema default is stored in the Agent at creation, "
                    f"so it freezes the platform's gateway as it was then; leave it empty and resolve "
                    f"the URL in the pod template")
        base = fallback(env.get("AGENT_GATEWAY_URL"))
        mcp = fallback(env.get("AGENT_MCP_URL"))

        if not base:
            problems.append("no platform gateway URL for an Agent that names none: it has no model endpoint")
        elif not re.match(r"^https?://", base):
            problems.append(
                f"gatewayBaseUrl default {base!r} has no scheme. A bare hostname is not a "
                f"base URL, and an SDK given one fails on the first call")

        if base and mcp and base.rstrip("/") == mcp.rstrip("/"):
            problems.append(
                "the model endpoint and the MCP endpoint are the same URL. One gateway serves "
                "tools and models on different paths")

        if base and not is_oss and "/inference/" not in base:
            problems.append(
                f"gatewayBaseUrl default {base!r} does not carry /inference/, which is the path an "
                f"AgentCore inference target serves. The gateway root is the MCP surface")

        for var in ("OPENAI_BASE_URL", "AGENT_GATEWAY_URL", "AGENT_MCP_URL"):
            if var not in env:
                problems.append(f"{var} is not set on the agent container")

        if is_oss and "OPENAI_BASE_URL" in env and "/llm/" not in env["OPENAI_BASE_URL"]:
            problems.append(
                "OPENAI_BASE_URL does not carry the per-agent /llm/<name> route. The gateway's "
                "assumeRole.roleArn is a literal ARN, so one backend cannot serve every agent")

        if ("OPENAI_BASE_URL" in env and "AGENT_MCP_URL" in env
                and env["OPENAI_BASE_URL"] == env["AGENT_MCP_URL"]):
            problems.append("OPENAI_BASE_URL and AGENT_MCP_URL resolve to the same value")

        checked += 1
        if problems:
            print(f"      ✗ {name}")
            for p in problems:
                print(f"          {p}")
            failed = True
        else:
            print(f"      ✓ {name}: model {base}, tools {mcp}")

    if not checked:
        print("      ✗ no rendered agent resource definition found")
        return 1
    if not failed:
        print("      ! a reachable model still needs a gateway inference target: scripts/exercise.sh")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
