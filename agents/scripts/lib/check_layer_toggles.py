#!/usr/bin/env python3
"""Each optional layer is turned off in TWO places, and they must agree.

A layer has a chart value (`networkPolicy.enabled`, `gateway.enabled`, `observability.enabled`,
`evals.enabled`, `mesh.mode`) and, where it is also Argo CD Applications, an entry in Terraform's
platform_excluded list, which the root Application passes to the platform chart as `excluded` and
which leaves those templates unrendered. The gateway is Applications on the
open source path (AgentGateway) and a managed endpoint on the AWS services path (AgentCore Gateway),
so only the first excludes files for it. Nothing at runtime notices when those two disagree, and each direction fails
differently and quietly:

  chart off, files synced     the component runs and nothing references it. The gateway comes up,
                              holds an IAM role that can assume every agent identity, and no policy
                              names it as a destination. Reads as a working cluster.
  chart on, files excluded    the policy names a gateway namespace that is empty, and every model
                              call times out against a Service that does not exist. The egress
                              check still passes, because a timeout is what it asserts.

So this checks the one thing that cannot be checked at runtime: that the Terraform that renders both
decides them from the SAME variable. It reads the HCL rather than a plan, because a plan needs
credentials and this suite runs without them.

Usage:  check_layer_toggles.py <repo-root>
"""
import os
import re
import sys

# layer -> (terraform variable, chart values path, {path: templates platform_excluded must list when off})
LAYERS = {
    "network policy": ("enable_network_policy", "networkPolicy.enabled", {}),
    "gateway": ("enable_gateway", "gateway.enabled", {
        "open-source": ["29-agentgateway-crds.yaml", "30-agentgateway.yaml", "31-agentgateway-config.yaml"],
    }),
    # Off, the collector and dashboards are excluded AND the base chart gives an agent no OTLP
    # endpoint and no collector egress. Disagreeing either way is quiet: a collector nobody exports
    # to, or agents exporting into a namespace with nothing in it.
    "observability": ("enable_observability", "observability.enabled", {
        "open-source": ["50-observability.yaml"],
        "aws-services": ["45-cert-manager.yaml", "50-adot.yaml"],
    }),
    # Off, the runner's Application is excluded AND the base chart renders no evals namespace or
    # per-agent ingress rule for it. Disagreeing either way is quiet: an excluded runner with agents
    # still admitting its namespace, or a synced runner whose every turn times out at the agent.
    "evaluation": ("enable_evaluations", "evals.enabled", {
        "open-source": ["52-agent-evals.yaml"], "aws-services": ["52-agent-evals.yaml"],
    }),
}


def fail(msg):
    print(f"      ✗ {msg}")
    return 1


def main(root):
    bad = 0
    oss = f"{root}/terraform/open-source/main.tf"
    aws = f"{root}/terraform/aws-services/main.tf"

    for path in (oss, aws):
        src = open(path, encoding="utf-8").read()
        name = path.split("/")[-2]

        # 1. The excluded list is rendered into the root Application at all. Without this the
        #    committed placeholder reaches the cluster, `excluded: PLATFORM_EXCLUDED` is a string
        #    rather than a list, and every layer is synced whatever the chart says. The root
        #    Application must also hand it to the chart under the key the templates test.
        root_app = open(f"{root}/gitops/bootstrap/{name}/root-app.yaml", encoding="utf-8").read()
        if not re.search(r"^\s*excluded: PLATFORM_EXCLUDED\s*$", root_app, re.M):
            bad |= fail(f"{name}: root-app.yaml does not pass PLATFORM_EXCLUDED as `excluded`")

        # 2. It is rendered as a LIST, from platform_excluded itself. The templates test
        #    `has "<file>" .Values.excluded`, which matches whole entries of a list; anything else
        #    -- a glob, a joined string -- matches nothing, so the sync succeeds and installs the
        #    layer that was meant to be left out.
        if '"PLATFORM_EXCLUDED", jsonencode(local.platform_excluded))' not in src:
            bad |= fail(f"{name}: PLATFORM_EXCLUDED is not rendered as jsonencode(local.platform_excluded)")

        # 3. The chart value and the exclude list come from the same variable.
        for layer, (tf_var, chart_path, by_path) in LAYERS.items():
            files = by_path.get(name, [])
            if f"var.{tf_var}" not in src:
                bad |= fail(f"{name}: {layer} has no var.{tf_var}")
                continue
            key = chart_path.split(".")[0]
            # The rendered values block must set the flag from the variable, not from a literal.
            block = re.search(r"\n    %s = \{(.*?)\n    \}" % re.escape(key), src, re.S)
            if not block:
                bad |= fail(f"{name}: no rendered `{key}` values block")
            elif f"var.{tf_var}" not in block.group(1):
                bad |= fail(f"{name}: {chart_path} is not rendered from var.{tf_var}")
            for f in files:
                if f not in src:
                    bad |= fail(f"{name}: {f} is never excluded, so disabling {layer} leaves it synced")
            # Every platform template named must exist, so a rename cannot leave the list
            # excluding a file that does not exist while the real one syncs.
            for f in files:
                if not os.path.exists(f"{root}/gitops/platform/{name}/templates/{f}"):
                    bad |= fail(f"{name}: {f} is excluded for {layer} but does not exist")

        # Every file platform_excluded names, for any variable, is a template of this path's chart,
        # so no toggle in the list is one a rename has quietly disconnected. A glob is not a
        # template name and the chart matches entries whole, so it excludes nothing either way.
        m = re.search(r"platform_excluded = concat\((.*?)\n  \)", src, re.S)
        if not m:
            bad |= fail(f"{name}: no platform_excluded list")
        else:
            body = "\n".join(l.split("#", 1)[0] for l in m.group(1).splitlines())
            for f in sorted(set(re.findall(r'"([^"*]+\.yaml)"', body))):
                if not os.path.exists(f"{root}/gitops/platform/{name}/templates/{f}"):
                    bad |= fail(f"{name}: platform_excluded names {f}, which is not in templates/")

        # 4. The mesh's own files are excluded when mesh_mode is none. This is the case that was
        #    wrong before these toggles existed, and on the aws-services path it was wrong by
        #    DEFAULT -- mesh_mode defaults to "none" there and both Istio Applications synced anyway.
        if 'var.mesh_mode == "none"' not in src:
            bad |= fail(f"{name}: mesh_mode=none does not exclude the Istio Applications")

    if not bad:
        print("      ✓ both paths render each layer's chart flag and excluded templates from one variable")
    return bad


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))
