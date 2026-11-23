#!/usr/bin/env python3
"""Every HTTP route in this repository's serving workloads verifies a credential.

    check_route_gates.py

Three workloads here accept requests -- the agent's HTTP server, the MCP server and the chat UI --
and each one fronts something that costs money or holds authority. A route added without its gate is
the defect this catches: it does not fail any test, it does not look wrong in a diff, and it is a
model an unauthenticated caller can drive.

The rule is mechanical, so it is checked mechanically:

  /healthz    unauthenticated, and must stay that way. The kubelet calls it and cannot present a
              credential, so gating it would fail the probe and roll the pod forever.
  everything  calls the module's verifier (_verify for a workload token, _person or _verified for an
  else        ALB-signed identity) before it does anything else.

What this cannot check is whether the verifier is correct -- that it checks a signature rather than
the presence of a header. That is apps/common/cluster_auth.py, which is one file so that it can be
reviewed once.
"""
import ast
import pathlib
import sys

SERVICES = [
    "apps/chat-ui/app.py",
    "apps/mcp-server/app.py",
    "apps/reference/server.py",
]
VERIFIERS = {"_verify", "_person", "_verified"}


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[2]
    problems = []
    checked = 0

    for rel in SERVICES:
        path = root / rel
        if not path.exists():
            problems.append(f"{rel} is missing: a serving workload lost its source")
            continue

        for node in ast.walk(ast.parse(path.read_text())):
            if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                continue
            routes = [d for d in node.decorator_list
                      if isinstance(d, ast.Call) and getattr(d.func, "attr", "") in ("get", "post")]
            if not routes:
                continue

            route = routes[0].args[0].value if routes[0].args else "?"
            calls = {n.func.id for n in ast.walk(node)
                     if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
            gated = bool(calls & VERIFIERS)
            checked += 1

            if route == "/healthz" and gated:
                problems.append(
                    f"{rel}:{route} gates the health endpoint. The kubelet cannot present a "
                    f"credential, so the probe would fail and the pod would roll forever")
            elif route != "/healthz" and not gated:
                problems.append(
                    f"{rel}:{route} does not call a verifier, so it is reachable by any caller "
                    f"that can reach the pod")

    if problems:
        for p in problems:
            print(f"      ✗ {p}")
        return 1

    print(f"      ✓ {checked} routes across {len(SERVICES)} workloads: "
          f"all gated except /healthz")
    return 0


if __name__ == "__main__":
    sys.exit(main())
