#!/usr/bin/env python3
"""Exercise a temporal (Dogwood) policy through the AgentCore Gateway, from inside an agent pod.

    kubectl -n agents exec deploy/research -- python - < scripts/lib/temporal_probe.py \
        <prerequisite tool> <gated tool> [gated tool arguments as JSON]

The policy under test permits <gated tool> only after <prerequisite tool> answered earlier in the
SAME policy session. Asserts, in order:
  1. a call with no x-amzn-bedrock-agentcore-policy-session-id header is rejected;
  2. in a fresh session, the gated tool is denied;
  3. the prerequisite is allowed;
  4. in that same session, the gated tool is now allowed;
  5. in another fresh session, the gated tool is denied again.
Reads the agent's own MCP URL and token from its environment, so it calls exactly as the agent does.
Exit status 0 only when all five hold.
"""
import json, os, sys, uuid
import httpx

pre, gated = sys.argv[1], sys.argv[2]
args = json.loads(sys.argv[3]) if len(sys.argv) > 3 else {}
url = os.environ["AGENT_MCP_URL"]
token = open(os.environ.get("AGENT_MCP_TOKEN_FILE") or os.environ["AGENT_IDENTITY_TOKEN_FILE"]).read().strip()
H = "x-amzn-bedrock-agentcore-policy-session-id"


def rpc(method, params, session=None, mcp_session=None, rid=1):
    h = {"Authorization": f"Bearer {token}", "Content-Type": "application/json",
         "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-06-18"}
    if session:
        h[H] = session
    if mcp_session:
        h["Mcp-Session-Id"] = mcp_session
    r = httpx.post(url, headers=h, json={"jsonrpc": "2.0", "id": rid, "method": method, "params": params}, timeout=60)
    body = r.text
    if "text/event-stream" in r.headers.get("content-type", ""):
        body = "".join(l[5:].strip() for l in body.splitlines() if l.startswith("data:"))
    try:
        data = json.loads(body) if body else {}
    except ValueError:
        data = {"raw": body[:300]}
    return r.status_code, data, r.headers.get("mcp-session-id")


def call(tool, session):
    code, init, ms = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                        "clientInfo": {"name": "temporal-probe", "version": "1"}}, session)
    if code >= 400 or "error" in init:
        return False, f"initialize HTTP {code}: {json.dumps(init)[:240]}"
    code, res, _ = rpc("tools/call", {"name": tool, "arguments": args if tool == gated else {}}, session, ms, 2)
    err = res.get("error") or (res.get("result", {}).get("isError") and res["result"].get("content"))
    return (code < 400 and not err), f"HTTP {code}: {json.dumps(err or res.get('result', res))[:240]}"


results = []
def expect(name, ok_wanted, outcome):
    ok, detail = outcome
    good = ok == ok_wanted
    results.append(good)
    print(f"{'PASS' if good else 'FAIL'} {name}: {'allowed' if ok else 'refused'} -- {detail}")

expect("no policy-session header is rejected", False, call(gated, None))
s1 = f"probe-{uuid.uuid4().hex[:12]}"
expect(f"{gated} before {pre}, fresh session", False, call(gated, s1))
expect(f"{pre} is allowed", True, call(pre, s1))
expect(f"{gated} after {pre}, same session", True, call(gated, s1))
expect(f"{gated} in another fresh session", False, call(gated, f"probe-{uuid.uuid4().hex[:12]}"))
sys.exit(0 if all(results) else 1)
