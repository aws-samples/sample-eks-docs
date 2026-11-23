#!/usr/bin/env python3
"""The Agent's sandbox network limits have valid defaults and reach every agent pod.

    python3 scripts/lib/check_sandbox_limits.py <rendered.yaml> ...

The Nitro sandbox reads its network meters from the pod's sandbox.amazonaws.com/ annotations once,
at pod creation. An unparsable value reverts to the service default without a word, and a value
that resolves to 0 leaves the pod in ContainerCreating, so a bad chart default is a fleet-wide
outage or a silent no-op. For each Agent ResourceGraphDefinition this checks that

  * the four fields exist, each string field's default matches its own pattern, and the
    connection limit's default lies within its minimum and maximum;
  * the defaults are the ones in gitops/base/values.yaml (agentResource.sandboxLimits);
  * every pod template the definition composes carries all six annotations, each from its field.
"""
import re
import sys

import yaml

LIMITS = yaml.safe_load(open("gitops/base/values.yaml", encoding="utf-8"))["agentResource"]["sandboxLimits"]

STRING_FIELDS = {
    "networkBandwidth": ["ingress-bandwidth", "egress-bandwidth"],
    "networkPacketsPerSecond": ["ingress-packets-per-second", "egress-packets-per-second"],
    "dnsQueriesPerSecond": ["dns-packets-per-second"],
}
# Values that must be refused, so a pattern that admits anything fails here.
MUST_REFUSE = ["0", "0G", "", "1.5.G", "-1", "1 G", "ten"]


def markers(field):
    """{marker: value} from a kro simpleschema field string."""
    _, _, rest = field.partition("|")
    return {m.group(1): m.group(2) if m.group(2) is not None else m.group(3)
            for m in re.finditer(r'(\w+)=(?:"([^"]*)"|(\S+))', rest)}


def pod_annotations(obj, found):
    """Every metadata.annotations map under a `template` key, anywhere in a composed resource."""
    if isinstance(obj, dict):
        tpl = obj.get("template")
        if isinstance(tpl, dict) and isinstance(tpl.get("spec"), dict) and "containers" in tpl["spec"]:
            found.append((tpl.get("metadata") or {}).get("annotations") or {})
        for v in obj.values():
            pod_annotations(v, found)
    elif isinstance(obj, list):
        for v in obj:
            pod_annotations(v, found)


failed = 0


def bad(msg):
    global failed
    print(f"      ✗ {msg}")
    failed += 1


checked = 0
for path in sys.argv[1:]:
    for doc in yaml.safe_load_all(open(path, encoding="utf-8")):
        if not isinstance(doc, dict) or doc.get("kind") != "ResourceGraphDefinition":
            continue
        spec = (((doc.get("spec") or {}).get("schema") or {}).get("spec")) or {}
        if "cpuRequest" not in spec:
            continue
        name = f"{path.rsplit('/', 1)[-1]}: {doc['metadata']['name']}"
        checked += 1
        before = failed

        for field in STRING_FIELDS:
            if field not in spec:
                bad(f"{name}: no {field} field")
                continue
            m = markers(spec[field])
            pattern, default = m.get("pattern"), m.get("default")
            if not pattern:
                bad(f"{name}: {field} has no pattern")
                continue
            if default != str(LIMITS[field]):
                bad(f"{name}: {field} default {default!r} is not agentResource.sandboxLimits.{field} {LIMITS[field]!r}")
            if not re.fullmatch(pattern, default or ""):
                bad(f"{name}: {field} default {default!r} does not match its own pattern {pattern}")
            for v in MUST_REFUSE:
                if re.fullmatch(pattern, v):
                    bad(f"{name}: {field} pattern admits {v!r}")

        if "connectionLimit" not in spec:
            bad(f"{name}: no connectionLimit field")
        else:
            m = markers(spec["connectionLimit"])
            try:
                lo, hi, d = int(m["minimum"]), int(m["maximum"]), int(m["default"])
            except (KeyError, ValueError):
                bad(f"{name}: connectionLimit needs integer default, minimum and maximum: {spec['connectionLimit']}")
            else:
                if (lo, hi) != (64, 65536):
                    bad(f"{name}: connectionLimit bounds are {lo}-{hi}, the sandbox accepts 64-65536")
                if not lo <= d <= hi or d != int(LIMITS["connectionLimit"]):
                    bad(f"{name}: connectionLimit default {d} is outside {lo}-{hi} or differs from values.yaml")

        pods = []
        pod_annotations((doc.get("spec") or {}).get("resources") or [], pods)
        if not pods:
            bad(f"{name}: composes no pod template")
        want = {f"sandbox.amazonaws.com/{a}": f"${{schema.spec.{f}}}" for f, al in STRING_FIELDS.items() for a in al}
        want["sandbox.amazonaws.com/conntrack-limit"] = "${string(schema.spec.connectionLimit)}"
        for i, ann in enumerate(pods):
            for k, v in want.items():
                if ann.get(k) != v:
                    bad(f"{name}: pod template {i} annotation {k} is {ann.get(k)!r}, expected {v}")
        if failed == before:
            print(f"      ✓ {name}: 4 fields, {len(pods)} pod template(s)")

if not checked:
    bad("no Agent ResourceGraphDefinition in the rendered files")
sys.exit(1 if failed else 0)
