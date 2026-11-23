"""Every vpc_endpoints key a root module accepts must be one the vpc-endpoints module creates.

Reads the module's `services` map and validation list and each root's validation list. Standard
library only.
"""
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
mod = root / "terraform/modules/vpc-endpoints"
main = (mod / "main.tf").read_text()
services = set(re.findall(r'^\s*([a-z0-9-]+)\s*=\s*"com\.amazonaws\.', main, re.M))


def validation_keys(path: Path, var: str) -> set[str]:
    text = path.read_text()
    block = re.search(r'variable "%s" \{(.*?)\n\}' % var, text, re.S).group(1)
    lists = re.findall(r"contains\(\[([^\]]*)\]", block)
    return set(re.findall(r'"([a-z0-9-]+)"', lists[0])) if lists else set()


failures = []
module_keys = validation_keys(mod / "variables.tf", "endpoints")
if module_keys != services:
    failures.append(f"module validation {sorted(module_keys ^ services)} differs from its services map")
for r in ("open-source", "aws-services"):
    keys = validation_keys(root / f"terraform/{r}/variables.tf", "vpc_endpoints")
    missing = keys - services
    if missing:
        failures.append(f"terraform/{r} accepts {sorted(missing)}, which the module does not create")
for f in failures:
    print(f"      ✗ {f}")
sys.exit(1 if failures else 0)
