#!/usr/bin/env python3
"""Refuse an agent namespace in the infrastructure carve-out.

    python3 scripts/lib/check_infra_namespaces.py <rendered-base-chart.yaml> ...

WHY. `networkPolicy.infrastructureNamespaces` renders an Admin-tier ClusterNetworkPolicy at
priority 1 that accepts all traffic in both directions, because the agents' nodes run in strict
enforcement mode and the DaemonSets that land there -- ztunnel above all -- are selected by no other
policy. That carve-out is necessary and it is also the one object in this chart that can undo the
whole egress boundary: an Admin-tier Accept ENDS EVALUATION, so an agent namespace listed here gets
unrestricted egress and every later rule naming it is dead.

The failure would be silent. The policy applies, reports nothing, and the egress phase of
exercise.sh keeps passing for a destination no rule permits -- because the carve-out permits
everything.
"""

import sys
import yaml

AGENT_NAMESPACE_HINTS = ("agents", "agents-execution")


def main() -> int:
    failed = False
    for path in sys.argv[1:]:
        try:
            docs = [d for d in yaml.safe_load_all(open(path, encoding="utf-8")) if d]
        except (OSError, yaml.YAMLError) as exc:
            print(f"      ✗ {path}: {exc}")
            failed = True
            continue

        # The namespaces this chart creates for agents, read from the render rather than assumed:
        # whoever renamed them in values.yaml did not come here to update a constant.
        agent_namespaces = {
            d["metadata"]["name"]
            for d in docs
            if d.get("kind") == "Namespace"
            and (d.get("metadata", {}).get("labels", {}) or {}).get("eks-agents/admission")
        }
        agent_namespaces |= {n for n in AGENT_NAMESPACE_HINTS}

        for d in docs:
            if d.get("kind") != "ClusterNetworkPolicy":
                continue
            if d["metadata"]["name"] != "eks-agents-infrastructure":
                continue
            listed = set()
            for expr in (
                d["spec"].get("subject", {}).get("namespaces", {}).get("matchExpressions") or []
            ):
                listed |= set(expr.get("values") or [])
            overlap = sorted(listed & agent_namespaces)
            if overlap:
                failed = True
                print(f"      ✗ {path}: the infrastructure carve-out lists agent namespace(s): "
                      f"{', '.join(overlap)}")
                print("        That policy is an Admin-tier Accept at priority 1, and an Admin-tier "
                      "Accept ENDS EVALUATION -- so every agent in those namespaces would have "
                      "unrestricted egress and every rule below would be dead. Remove them from "
                      "networkPolicy.infrastructureNamespaces.")
            else:
                print(f"      ✓ {path.split('/')[-1]}: the carve-out names no agent namespace "
                      f"({len(listed)} infrastructure namespaces)")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
