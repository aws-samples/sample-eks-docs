"""Print only the CustomResourceDefinitions from a rendered manifest stream on stdin.

Used by scripts/install-platform.sh to apply a chart's own CRDs before the chart, which Helm cannot
do in one release. Standard library only: the bastion's python has no yaml module.
"""
import re
import sys

docs = re.split(r"(?m)^---\s*$", sys.stdin.read())
crds = [d.strip() for d in docs if re.search(r"(?m)^kind:\s*CustomResourceDefinition\s*$", d)]
if crds:
    print("---\n" + "\n---\n".join(crds))
