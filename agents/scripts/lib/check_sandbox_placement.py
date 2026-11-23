#!/usr/bin/env python3
"""Every pod spec that asks for the Nitro sandbox also asks for the agents' own node pool.

  check_sandbox_placement.py FILE...   (raw manifests, or rendered chart output)

A pod spec here is any mapping with `runtimeClassName: isolated-sandbox`; it must carry
`nodeSelector: {karpenter.sh/nodepool: <pool>}` and a toleration for `eks-agents/dedicated`.

WHY. A sandboxed pod on a general-purpose node runs in standard network policy mode (the strict
mode is on the agents' NodeClass only). And on a node that holds sandboxed pods, the scheduler
counts more memory against the node than its pods' requests plus RuntimeClass overhead: the next
unsandboxed pod Karpenter nominates to that node is refused for memory, and no node is launched.
That pod sits Pending for minutes, whichever it is (ADOT collector, MCP server, an example's test
caller, the release gate, the chat UI). Keeping sandboxed pods on the agents' own pool keeps them
off the general-purpose nodes; scripts/lib/unstick.sh handles a pod still caught.
"""
import sys
import yaml

TAINT = "eks-agents/dedicated"
failed = []


def walk(node, path, src):
    if isinstance(node, dict):
        if node.get("runtimeClassName") == "isolated-sandbox":
            sel = (node.get("nodeSelector") or {}).get("karpenter.sh/nodepool")
            tol = any(isinstance(t, dict) and t.get("key") == TAINT for t in (node.get("tolerations") or []))
            if not sel or not tol:
                missing = [n for n, ok in (("nodeSelector karpenter.sh/nodepool", sel), (f"toleration {TAINT}", tol)) if not ok]
                failed.append(f"{src}: {path or '<root>'}: isolated-sandbox without {', '.join(missing)}")
        for k, v in node.items():
            walk(v, f"{path}.{k}" if path else str(k), src)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, f"{path}[{i}]", src)


checked = 0
sandboxed = 0
for f in sys.argv[1:]:
    try:
        docs = list(yaml.safe_load_all(open(f)))
    except yaml.YAMLError:
        continue  # Helm templates and other non-YAML; the rendered output is checked instead
    if not any(docs):
        # A render that failed writes nothing, and nothing has no unpinned pod in it, so an empty
        # input would pass. It is a failure, not a pass.
        failed.append(f"{f}: empty -- the render that should have produced it failed")
        continue
    sandboxed += open(f).read().count("isolated-sandbox")
    for d in docs:
        if d:
            name = f"{f} ({d.get('kind', '?')}/{(d.get('metadata') or {}).get('name', '?')})" if isinstance(d, dict) else f
            before = len(failed)
            walk(d, "", name)
            checked += 1
for line in failed:
    print("      ✗ " + line)
if not failed and sandboxed == 0:
    failed.append("no isolated-sandbox pod spec in any input: nothing was checked")
    print("      ✗ " + failed[-1])
if not failed:
    print(f"      ✓ every isolated-sandbox pod spec is pinned to the agents' pool ({checked} documents)")
sys.exit(1 if failed else 0)
