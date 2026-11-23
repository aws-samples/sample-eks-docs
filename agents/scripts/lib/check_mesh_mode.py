#!/usr/bin/env python3
"""Assert a rendered base chart carries exactly the mesh shape its mode asked for.

    check_mesh_mode.py <rendered.yaml> <none|ambient>

The failure this exists for is the one Istio makes silent: a namespace labelled for both data planes
is resolved in favour of sidecar injection, with nothing in any object's status to show it. The
stack has no sidecar mode, so the labels are checked positively and negatively -- the mode's own
label present, istio-injection never.

A separate file rather than an inline heredoc because validate.sh already nests one level of
heredoc, and a second does not survive it.
"""
import sys

try:
    import yaml
except ImportError:  # the parse step in validate.sh reports this once
    sys.exit(0)

AMBIENT_LABEL = "istio.io/dataplane-mode"
SIDECAR_LABEL = "istio-injection"

WANTED = {"ambient": AMBIENT_LABEL, "none": None}
FORBIDDEN = {
    "ambient": [SIDECAR_LABEL],
    "none": [AMBIENT_LABEL, SIDECAR_LABEL],
}


def namespaces_by_tier(docs):
    out = {}
    for d in docs:
        if d.get("kind") != "Namespace":
            continue
        labels = (d.get("metadata") or {}).get("labels") or {}
        tier = labels.get("eks-agents/tier")
        if tier:
            out[tier] = labels
    return out


def main():
    path, mode = sys.argv[1], sys.argv[2]
    with open(path, encoding="utf-8") as f:
        docs = [d for d in yaml.safe_load_all(f) if isinstance(d, dict)]

    failed = False
    tiers = namespaces_by_tier(docs)

    reasoning = tiers.get("reasoning")
    if reasoning is None:
        print(f"      ✗ mesh.mode={mode}: no reasoning-tier Namespace rendered")
        failed = True
    else:
        want = WANTED[mode]
        if want and want not in reasoning:
            print(f"      ✗ mesh.mode={mode}: reasoning namespace is missing {want}, so the "
                  f"data plane is installed and nothing is enrolled in it")
            failed = True
        for bad in FORBIDDEN[mode]:
            if bad in reasoning:
                print(f"      ✗ mesh.mode={mode}: reasoning namespace carries {bad}. "
                      f"Istio resolves a namespace labelled for both in favour of sidecar, silently.")
                failed = True

    # The execution tier is never enrolled, in any mode: its pods have no network device, so ambient
    # captures nothing.
    execution = tiers.get("execution")
    if execution is not None:
        for bad in (AMBIENT_LABEL, SIDECAR_LABEL):
            if bad in execution:
                print(f"      ✗ mesh.mode={mode}: the execution tier carries {bad}. Those pods "
                      f"have no network device.")
                failed = True

    # Authorization policy follows the mode: without a data plane it is accepted and enforces
    # nothing, and with one its absence means the mesh authenticates both ends and then allows.
    has_authz = any(d.get("kind") == "AuthorizationPolicy" for d in docs)
    if mode == "none" and has_authz:
        print("      ✗ mesh.mode=none: mesh authorization policies rendered with no data plane "
              "to enforce them.")
        failed = True
    if mode != "none" and not has_authz:
        print(f"      ✗ mesh.mode={mode}: no AuthorizationPolicy rendered, so the mesh "
              f"authenticates both ends of every call and then allows it")
        failed = True

    if not failed:
        print(f"      ✓ mesh.mode={mode}: {len(docs)} docs, labels and policies consistent")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
