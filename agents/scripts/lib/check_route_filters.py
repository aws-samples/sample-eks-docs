#!/usr/bin/env python3
"""Every rule of an HTTPRoute on the ingress Gateway carries the OIDC filter.

The static half of the ValidatingAdmissionPolicy in gitops/base/templates/46-admission-ingress.yaml.
That policy governs what reaches a cluster; this governs what this repository ships as an example,
which is what a reader copies.

The failure it catches is per RULE, not per route. The gate attaches through an ExtensionRef filter
on each `rules[]` entry, so a route with two rules and one filter serves the other path
unauthenticated -- with the Gateway reporting Accepted, the ListenerRuleConfiguration reporting
nothing, and no status condition anywhere saying a rule has no authentication on it.

Scans rendered YAML only. Helm templates under gitops/base/templates are skipped: the chart
deliberately renders an UNauthenticated route variant for a cluster whose callers were already
authenticated in front of it, and the two variants are selected by a condition a text scan cannot
evaluate.

Usage: check_route_filters.py <file>...
Exit 1 if any rule on an ingress route lacks the filter.
"""
import sys

import yaml

# The Gateway the chart names. A route on any other Gateway -- an in-cluster AgentGateway, an Istio
# waypoint -- has its own policy surface and is not this check's business.
INGRESS_GATEWAYS = {"agent-ingress"}


def rules_without_filter(doc):
    """Indices of rules carrying no ExtensionRef to a ListenerRuleConfiguration."""
    out = []
    for i, rule in enumerate(doc.get("spec", {}).get("rules") or []):
        gated = any(
            f.get("type") == "ExtensionRef"
            and (f.get("extensionRef") or {}).get("kind") == "ListenerRuleConfiguration"
            for f in (rule.get("filters") or [])
            if isinstance(f, dict)
        )
        if not gated:
            out.append(i)
    return out


def on_ingress(doc):
    for p in doc.get("spec", {}).get("parentRefs") or []:
        if not isinstance(p, dict):
            continue
        if p.get("name") in INGRESS_GATEWAYS and p.get("kind", "Gateway") == "Gateway":
            return True
    return False


def main(paths):
    failed = False
    checked = 0
    for path in paths:
        try:
            with open(path) as fh:
                docs = list(yaml.safe_load_all(fh))
        except (OSError, yaml.YAMLError) as exc:
            print(f"      {path}: could not parse ({exc.__class__.__name__})")
            failed = True
            continue

        for doc in docs:
            if not isinstance(doc, dict) or doc.get("kind") != "HTTPRoute":
                continue
            if not on_ingress(doc):
                continue
            checked += 1
            ungated = rules_without_filter(doc)
            if ungated:
                name = (doc.get("metadata") or {}).get("name", "?")
                print(
                    f"      {path}: HTTPRoute/{name} rule(s) {ungated} attach to the ingress Gateway "
                    f"with no ExtensionRef filter naming a ListenerRuleConfiguration, so those "
                    f"paths are served unauthenticated and nothing reports it"
                )
                failed = True

    if checked == 0:
        print("      no ingress HTTPRoutes found, so this check proved nothing")
        return 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
