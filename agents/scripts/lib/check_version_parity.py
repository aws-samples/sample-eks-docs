#!/usr/bin/env python3
"""Both paths create the same control plane, and the bastion's kubectl is within one minor of it.

Each root module carries its own `kubernetes_version` default, so raising one and not the other
leaves the open source path on a 1.37 cluster and the AWS services path on 1.36. kubectl supports
one minor of skew either way, so a bastion kubectl pinned at v1.33.3, four minors behind 1.37, is
out of range.
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
FILES = {
    "kubernetes_version": ["terraform/open-source/variables.tf", "terraform/aws-services/variables.tf",
                           "terraform/modules/agent-cluster/variables.tf"],
    "bastion_kubectl_version": ["terraform/open-source/variables.tf", "terraform/aws-services/variables.tf"],
    "kubectl_version": ["terraform/modules/bastion/variables.tf"],
}


def default(path, var):
    text = (ROOT / path).read_text()
    m = re.search(r'variable "%s" \{.*?\n  default\s*=\s*"([^"]+)"' % re.escape(var), text, re.S)
    return m.group(1) if m else None


found = {}
for var, paths in FILES.items():
    for p in paths:
        found[(var, p)] = default(p, var)

failed = False
for key, v in found.items():
    if v is None:
        print(f"      ✗ {key[1]}: no default for {key[0]}"); failed = True
if failed:
    sys.exit(1)

k8s = {v for (var, _), v in found.items() if var == "kubernetes_version"}
kubectl = {v for (var, _), v in found.items() if var != "kubernetes_version"}
if len(k8s) != 1:
    print("      ✗ kubernetes_version differs: " + ", ".join(f"{p}={v}" for (var, p), v in found.items()
                                                       if var == "kubernetes_version")); failed = True
if len(kubectl) != 1:
    print("      ✗ the bastion kubectl version differs: " + ", ".join(sorted(kubectl))); failed = True
if not failed:
    cp, kc = k8s.pop(), kubectl.pop()
    cp_minor = int(cp.split(".")[1]); kc_minor = int(kc.lstrip("v").split(".")[1])
    if abs(cp_minor - kc_minor) > 1:
        print(f"      ✗ kubectl {kc} is {abs(cp_minor - kc_minor)} minors from the {cp} control plane; the limit is 1")
        failed = True
    else:
        print(f"      ✓ both paths default to Kubernetes {cp}; the bastion's kubectl is {kc}")
sys.exit(1 if failed else 0)
