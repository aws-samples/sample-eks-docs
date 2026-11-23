#!/usr/bin/env python3
"""Every ClusterNetworkPolicy the base chart can render is deleted by name in scripts/teardown.sh.

    python3 scripts/lib/check_teardown_cnps.py <repo root>

Teardown deletes them by name, before uninstalling the base release, because the release owns the
network policy controller that clears each policy's finalizer: a policy left for `helm uninstall`
hangs its delete forever. A name added to 30-cluster-egress-policy.yaml and not to both lists in
teardown.sh is that hang waiting to happen.
"""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
tpl = (root / "gitops/base/templates/30-cluster-egress-policy.yaml").read_text()
names = set(re.findall(r"kind: ClusterNetworkPolicy\nmetadata:\n  name: ([a-z0-9-]+)", tpl))
td = (root / "scripts/teardown.sh").read_text()
lists = re.findall(r"for p in ((?:[a-z0-9-]+\s*\\?\s*)+); do\n\s*kubectl get clusternetworkpolicies", td)
fails = []
if not names:
    fails.append("no ClusterNetworkPolicy names found in 30-cluster-egress-policy.yaml")
if len(lists) < 2:
    fails.append(f"expected two name lists in teardown.sh, found {len(lists)}")
for i, l in enumerate(lists, 1):
    missing = names - set(re.findall(r"[a-z0-9-]+", l))
    if missing:
        fails.append(f"teardown.sh list {i} does not delete {sorted(missing)}")
for f in fails:
    print(f"      ✗ {f}")
if fails:
    sys.exit(1)
print(f"      ✓ teardown deletes all {len(names)} ClusterNetworkPolicies by name, in both places")
