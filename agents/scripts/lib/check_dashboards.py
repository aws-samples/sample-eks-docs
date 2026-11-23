#!/usr/bin/env python3
"""Check the agent dashboard is internally consistent.

    check_dashboards.py <rendered-agent-dashboards.yaml>

A Grafana dashboard fails silently: a panel whose query names a metric that nothing produces renders
as an empty graph, and an empty graph on an agent platform reads as "no traffic" rather than as "this
panel is broken". Three things are checked, all of them consequences of the dashboard being
templated from values rather than hand-written:

  1. The dashboard JSON parses, and every panel has a title.
  2. Every metric a panel references is either a recording rule this chart defines, or built from
     the metric names in values.yaml. A rename in one place and not the other fails here.
  3. Every recording rule the panels use is actually defined by the PrometheusRule.

What this cannot check is whether the collector really exports those names -- that depends on the
collector version's rendering of the OpenTelemetry metric names, and values.yaml carries the command
to confirm it against a live endpoint.
"""
import json
import re
import sys

try:
    import yaml
except ImportError:
    print("      ! PyYAML not installed; skipping")
    sys.exit(0)

# A PromQL metric or recording-rule reference: an identifier, optionally with a colon for a rule.
METRIC_REF = re.compile(r"\b([a-zA-Z_][a-zA-Z0-9_]*(?::[a-zA-Z0-9_:]+)*)\s*(?:\{|\[|\))")

# Names that are PromQL itself, not metrics.
PROMQL = {
    "sum", "rate", "increase", "by", "without", "histogram_quantile", "vector", "avg", "max", "min",
    "count", "topk", "bottomk", "label_values", "le", "on", "group_left", "group_right", "ignoring",
    "irate", "delta", "idelta", "absent", "clamp_max", "clamp_min", "round", "time", "quantile",
}


# A metric reference whose name rendered empty leaves the suffix behind: `_sum`, `_bucket`,
# `_count`, or `_total` with nothing in front of it. Helm does not error on a missing values key --
# it substitutes the empty string -- so this is the only place the mistake can be caught before a
# human notices a permanently empty panel.
EMPTY_METRIC = re.compile(r"(?<![a-zA-Z0-9_:])(_sum|_bucket|_count|_total)\b")

# A Go template that did not render at all, which would make the query invalid rather than empty.
UNRENDERED = re.compile(r"\{\{|\}\}")


def _empty_template_artifacts(expr: str) -> list:
    """Metric references in `expr` whose name is missing, as the leftover suffix."""
    out = [m.group(1) for m in EMPTY_METRIC.finditer(expr)]
    # Grafana's own legend interpolation uses {{label}}, which is legitimate in legendFormat but
    # never in an expr, so an expr carrying braces is an unrendered template.
    if UNRENDERED.search(expr):
        out.append(expr[:60])
    return out


def main():
    docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if isinstance(d, dict)]

    dashboards = [d for d in docs if d.get("kind") == "ConfigMap"]
    rules = [d for d in docs if d.get("kind") == "PrometheusRule"]
    monitors = [d for d in docs if d.get("kind") == "ServiceMonitor"]

    failed = False

    pod_monitors = [d for d in docs if d.get("kind") == "PodMonitor"]

    if not monitors:
        print("      ✗ no ServiceMonitor: the collector would export the agent's metrics to an "
              "endpoint nothing scrapes, and those panels would be empty while everything "
              "reported healthy")
        failed = True

    # Everything priced and everything per-model comes from the gateway's data plane, on a port its
    # Service does not publish. A ServiceMonitor cannot reach it, so a chart that references an
    # agentgateway_ metric and renders no PodMonitor has panels that can never fill.
    all_text = sys.argv and open(sys.argv[1], encoding="utf-8").read()
    if "agentgateway_" in all_text and not pod_monitors:
        print("      ✗ panels or rules reference agentgateway_* metrics but no PodMonitor is "
              "rendered. Those series are on port 15020 of the gateway's data plane pod, which the "
              "Service does not publish, so a ServiceMonitor cannot reach them and every spend and "
              "per-model panel stays empty with nothing reporting a fault.")
        failed = True

    # A PrometheusRule Prometheus will not load is worse than a missing one: the object exists,
    # nothing reports a fault, and every panel built on a recording rule is permanently empty.
    # kube-prometheus-stack's Prometheus selects rules by label, as its spec shows:
    #
    #   kubectl -n monitoring get prometheus -o jsonpath='{.items[0].spec.ruleSelector}'
    #   -> {"matchLabels":{"release":"kube-prometheus-stack"}}
    #
    # So a rule carrying only this repo's own part-of label is ignored: the rules sit unloaded while
    # `kubectl get prometheusrule` shows them present.
    OWN_LABELS = {"app.kubernetes.io/part-of", "app.kubernetes.io/managed-by",
                  "app.kubernetes.io/name", "helm.sh/chart"}
    for r in rules:
        labels = set((r.get("metadata", {}).get("labels") or {}).keys())
        if not (labels - OWN_LABELS):
            print(f"      ✗ PrometheusRule {r.get('metadata', {}).get('name')!r} carries no "
                  f"selector label, so Prometheus will not load it. kube-prometheus-stack selects "
                  f"on `release: <its helm release>`; set ruleSelectorLabels. The object is "
                  f"created either way and nothing reports a fault.")
            failed = True

    # Recording rules this chart defines.
    defined = set()
    for r in rules:
        for group in r.get("spec", {}).get("groups", []):
            for rule in group.get("rules", []):
                if "record" in rule:
                    defined.add(rule["record"])

    panel_count = 0
    for cm in dashboards:
        for filename, body in (cm.get("data") or {}).items():
            try:
                dash = json.loads(body)
            except json.JSONDecodeError as e:
                print(f"      ✗ {filename}: dashboard JSON does not parse: {e}")
                failed = True
                continue

            for key in ("uid", "title", "panels"):
                if key not in dash:
                    print(f"      ✗ {filename}: dashboard has no {key!r}")
                    failed = True

            # Template-variable queries are checked too, not just panel queries. A query built
            # from a values key that does not exist renders as `label_values(_sum, eks_agent)`:
            # Helm does not error, the dashboard loads, and the Agent picker is simply always
            # empty.
            queries = [
                (v.get("name", "?"), v.get("query", ""))
                for v in (dash.get("templating", {}) or {}).get("list", []) or []
                if isinstance(v.get("query"), str)
            ]
            for var_name, q in queries:
                for bad in _empty_template_artifacts(q):
                    print(f"      ✗ {filename}: template variable {var_name!r} queries {bad!r}, "
                          f"which is a metric name that rendered empty -- check the values key the "
                          f"template reads")
                    failed = True

            for panel in dash.get("panels", []):
                panel_count += 1
                if not panel.get("title") and panel.get("type") != "row":
                    print(f"      ✗ {filename}: a {panel.get('type')} panel has no title")
                    failed = True

                for target in panel.get("targets", []) or []:
                    expr = target.get("expr", "")

                    for bad in _empty_template_artifacts(expr):
                        print(f"      ✗ {filename}: panel {panel.get('title')!r} references "
                              f"{bad!r}, a metric name that rendered empty. Helm does not error on "
                              f"a missing values key, so this renders and the panel is silently "
                              f"always empty.")
                        failed = True

                    for name in METRIC_REF.findall(expr):
                        if name in PROMQL or name.isdigit():
                            continue
                        if ":" in name:  # a recording rule
                            if name not in defined:
                                print(f"      ✗ {filename}: panel {panel.get('title')!r} uses "
                                      f"recording rule {name!r}, which no PrometheusRule in this "
                                      f"chart defines")
                                failed = True
                        # Bare metric names are checked by eye against values.yaml: the chart
                        # templates them from one place, so a mismatch here would mean the template
                        # itself is inconsistent, which the render would already have caught.

    if not dashboards:
        print("      ✗ no dashboard ConfigMap rendered")
        failed = True

    if not failed:
        print(f"      ✓ {panel_count} panels, {len(defined)} recording rules, all references resolve")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
