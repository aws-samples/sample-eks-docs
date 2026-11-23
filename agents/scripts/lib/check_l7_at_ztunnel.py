#!/usr/bin/env python3
"""Refuse an AuthorizationPolicy that enforces something other than what it reads as.

    check_l7_at_ztunnel.py <render-dir>

Two shapes, both of which report Accepted and leave a GitOps sync green.

FIRST: a catch-all DENY. `action: DENY` with an empty rule, no selector and no targetRefs reads as
a namespace default-deny and is not one. DENY is evaluated before ALLOW and a matching DENY wins, so
it denies every connection in its scope and no ALLOW policy can ever match. The correct default-deny
is `action: ALLOW` with no rules, which selects everything and admits nothing while leaving the
allows free to match. gitops/base/templates/50-mesh-authz.yaml carries the two log lines.

SECOND: L7 rules at ztunnel.

AMBIENT ONLY. ztunnel is an L4 proxy, so Istio omits the attributes it cannot evaluate. The outcome
depends on the action AND on where the L7 attribute sits in the rule -- and TWO of the four fail
OPEN:

    ALLOW + any L7                  rules omitted, nothing matches, denied         (fails closed)
    DENY  + L4 and L7, SAME entry   enforced without the L7 attributes, overblocks (fails closed)
    DENY  + L4 and L7, DIFFERENT    the L7 entry is skipped, rule never matches    (FAILS OPEN)
          entries
    DENY  + only L7                 no enforceable rule left, no effect            (FAILS OPEN)

This check does not distinguish the two DENY-with-L4 rows: it refuses any DENY carrying an L7
attribute without targetRefs, because the safe answer is the same either way and the difference is
one entry boundary in a hand-written rule.

Istio reports all four as a warning condition on the policy, so the object is Accepted and a GitOps
sync is green. This turns that warning into a build failure. Note the condition's own wording was
wrong for both fail-open shapes before Istio 1.32.0 (it claimed "more restrictive than requested"):
istio/istio#61126, fixed by PR #61166, not backported to 1.30.x or 1.31.x. Four-case breakdown is at
https://istio.io/latest/docs/ambient/usage/l4-policy/ under "Policies with Layer 7 conditions".

The examples in this repo are built for ambient, the only mesh mode, so that is what is checked.

Attribute lists are from Istio's own conversion, pilot/pkg/serviceregistry/ambient/authorization.go.
"""
import glob
import os
import sys

try:
    import yaml
except ImportError:
    print("      ! PyYAML not installed; skipping")
    sys.exit(0)

# requestPrincipals is here and not in the L4 set: a rule naming the subject of a TOKEN is L7 in
# ambient, even though it reads like an identity check. That surprises people.
L7_OPERATION = {"hosts", "notHosts", "methods", "notMethods", "paths", "notPaths"}
L7_SOURCE = {"remoteIpBlocks", "notRemoteIpBlocks", "requestPrincipals", "notRequestPrincipals"}
L4_CONDITION_KEYS = {
    "source.ip", "source.namespace", "source.principal", "destination.ip", "destination.port",
}


def l7_attributes(spec):
    found = set()
    for rule in spec.get("rules") or []:
        for frm in rule.get("from") or []:
            found |= L7_SOURCE & set((frm.get("source") or {}).keys())
        for to in rule.get("to") or []:
            found |= L7_OPERATION & set((to.get("operation") or {}).keys())
        for cond in rule.get("when") or []:
            key = cond.get("key", "")
            if key and key not in L4_CONDITION_KEYS:
                found.add(key)
    return found


def main():
    render_dir = sys.argv[1]
    paths = sorted(
        set(glob.glob(os.path.join(render_dir, "mesh-ambient.yaml")))
        | set(glob.glob(os.path.join(render_dir, "base-*.yaml")))
        | set(glob.glob("gitops/examples/**/*.yaml", recursive=True))
        # The platform charts' own files, and their Applications and template alternatives as
        # validate.sh rendered them into <render dir>/platform: a template is not a manifest until
        # rendered, and the raw one fails to parse and is skipped below.
        | {p for p in glob.glob("gitops/platform/**/*.yaml", recursive=True) if "/templates/" not in p}
        | set(glob.glob(os.path.join(render_dir, "platform", "**", "*.yaml"), recursive=True))
    )

    failed = False
    checked = 0

    for path in paths:
        try:
            with open(path, encoding="utf-8") as f:
                docs = [d for d in yaml.safe_load_all(f) if isinstance(d, dict)]
        except yaml.YAMLError:
            continue  # the parse step owns this

        for d in docs:
            if d.get("kind") != "AuthorizationPolicy":
                continue
            spec = d.get("spec") or {}
            meta = d.get("metadata") or {}
            name = f"{meta.get('namespace', '?')}/{meta.get('name', '?')}"
            checked += 1

            # A catch-all DENY makes every ALLOW in the same scope inert.
            #
            # DENY is evaluated before ALLOW and a matching DENY wins, so `action: DENY` with a rule
            # that has no conditions denies every connection it covers and NO ALLOW POLICY CAN TAKE
            # EFFECT. Written as a namespace default-deny -- no selector, no targetRefs -- it closes
            # the namespace rather than defaulting it, and every allowlist beside it is decoration
            # while reporting Accepted. See gitops/base/templates/50-mesh-authz.yaml.
            #
            # The correct default-deny is `action: ALLOW` with no rules. A catch-all DENY is still
            # right for a destination nothing may reach, so this only refuses the unscoped form.
            if (
                spec.get("action") == "DENY"
                and not spec.get("selector")
                and not spec.get("targetRefs")
                and any(not r for r in (spec.get("rules") or []))
            ):
                print(f"      ✗ {os.path.basename(path)}: {name} is a catch-all DENY with no "
                      f"selector and no targetRefs. DENY is evaluated before ALLOW and wins, so "
                      f"this denies every connection in its scope and no ALLOW policy can ever "
                      f"match -- the scope is closed, not default-denied. For a default-deny use "
                      f"`action: ALLOW` with no rules.")
                failed = True
                continue

            found = l7_attributes(spec)
            if not found:
                continue

            attrs = ", ".join(sorted(found))
            if spec.get("targetRefs"):
                print(f"      ✓ {name}: L7 ({attrs}) and attached with targetRefs")
                continue

            where = os.path.basename(path)
            if spec.get("action", "ALLOW") == "DENY":
                print(f"      ✗ {where}: {name} is a DENY with L7 attributes ({attrs}) and no "
                      f"targetRefs. In ambient, Istio omits those attributes for ztunnel; if "
                      f"nothing enforceable is left the policy HAS NO EFFECT and the workload is "
                      f"open. Attach it to a waypoint, or a Service that uses one.")
            else:
                print(f"      ✗ {where}: {name} is an ALLOW with L7 attributes ({attrs}) and no "
                      f"targetRefs. In ambient, ztunnel omits those rules, so no ALLOW rule "
                      f"matches and every connection is refused.")
            failed = True

    if not failed:
        print(f"      ✓ {checked} AuthorizationPolicy objects, no catch-all DENY and none "
              f"L7-at-ztunnel")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
