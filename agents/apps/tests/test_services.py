"""The serving workloads refuse what they should, at the HTTP layer.

    python apps/tests/test_services.py

test_gates.py proves the verifier is correct. This proves each service is actually wired to it: a
correct verifier that a route forgets to call is the same outcome as no verifier at all.

Every route is exercised through the real ASGI app, so what is being tested is the response an
unauthenticated caller would receive rather than a function in isolation.

The two apps both live in a module called `app`, so they are loaded under distinct names. Loading
them normally would give the second import the first module and silently test one service twice.
"""

from __future__ import annotations

import base64
import importlib.util
import json
import os
import sys
from pathlib import Path

AGENTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS_DIR / "common"))

from fastapi.testclient import TestClient  # noqa: E402

RESULTS = []


def load(name: str, path: Path):
    """Load a module under an explicit name, so two files called app.py do not collide."""
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def check(name: str, got, want):
    ok = got == want
    RESULTS.append((ok, f"{name}: got {got}, want {want}"))
    colour = "\033[32mPASS\033[0m" if ok else "\033[31mFAIL\033[0m"
    print(f"  {colour} {name} -> {got}")


def main() -> int:
    # Point both services at an issuer that does not exist. Every token verification therefore
    # fails, which is the correct behaviour under a broken issuer and is what makes these
    # assertions about the ROUTE rather than about the token.
    os.environ["CLUSTER_OIDC_ISSUER"] = "http://127.0.0.1:1/unreachable"
    os.environ["MCP_INBOUND_AUDIENCE"] = "mcp-server"
    os.environ["AWS_REGION"] = "us-west-2"
    os.environ["CHAT_UI_AGENTS"] = "research=http://127.0.0.1:1"
    os.environ.pop("AUTH_TEST_BYPASS", None)

    print("\nMCP server")
    mcp = load("mcp_service", AGENTS_DIR / "mcp-server" / "app.py")
    with TestClient(mcp.app) as c:
        check("/healthz is open (the kubelet cannot authenticate)",
              c.get("/healthz").status_code, 200)
        check("/mcp with no token is refused",
              c.post("/mcp", json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).status_code,
              401)
        check("/mcp with a forged bearer token is refused",
              c.post("/mcp", headers={"Authorization": "Bearer forged.not.ajwt"},
                     json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).status_code,
              401)
        check("tools/list does not leak the catalogue to an unauthenticated caller",
              "lookup_order" in c.post(
                  "/mcp", json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).text,
              False)

    print("\nchat UI")
    ui = load("chatui_service", AGENTS_DIR / "chat-ui" / "app.py")
    with TestClient(ui.app) as c:
        check("/healthz is open", c.get("/healthz").status_code, 200)
        check("/ with no ALB identity is refused", c.get("/").status_code, 401)
        check("/ with a forged ALB identity is refused",
              c.get("/", headers={"x-amzn-oidc-data": "forged.not.ajwt"}).status_code, 401)
        check("/chat with no ALB identity is refused",
              c.post("/chat?agent=research", json={"prompt": "x"}).status_code, 401)
        check("/ does not leak which agents exist to an unauthenticated caller",
              "research" in c.get("/").text, False)
        # An unauthenticated caller must not be able to tell a configured agent from an unknown one:
        # the gate has to run before any input is looked at.
        check("an unknown agent is still refused at the gate, not at validation",
              c.post("/chat?agent=does-not-exist", json={"prompt": "x"}).status_code, 401)

    print("\nMCP server, with a verified caller")
    # Reusing the issuer fixture from test_gates proves the whole chain: a token this cluster would
    # issue, verified by the service, admitting a real MCP call. Refusals alone would also pass on a
    # service that is simply broken.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from test_gates import _Issuer, _make_key  # noqa: PLC0415

    issuer = _Issuer(_make_key())
    os.environ["CLUSTER_OIDC_ISSUER"] = issuer.url
    mcp2 = load("mcp_service_authed", AGENTS_DIR / "mcp-server" / "app.py")
    auth = {"Authorization": "Bearer " + issuer.sign(audience="mcp-server")}

    with TestClient(mcp2.app) as c:
        r = c.post("/mcp", headers=auth,
                   json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        check("tools/list is answered for a verified caller", r.status_code, 200)
        names = sorted(t["name"] for t in r.json().get("result", {}).get("tools", []))
        check("all three tools are listed", names,
              ["describe_cluster", "get_time", "lookup_order"])

        r = c.post("/mcp", headers=auth, json={
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": {"name": "lookup_order", "arguments": {"order_id": "ORD-12345"}}})
        check("tools/call returns the order", r.status_code, 200)
        check("the order payload is in a text content block",
              "in transit" in r.json()["result"]["content"][0]["text"], True)

        r = c.post("/mcp", headers=auth, json={
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": {"name": "lookup_order", "arguments": {"order_id": "NOPE"}}})
        check("an unknown order is an isError result, not an exception",
              r.json()["result"]["isError"], True)

        r = c.post("/mcp", headers=auth, json={
            "jsonrpc": "2.0", "id": 4, "method": "tools/call",
            "params": {"name": "rm_rf", "arguments": {}}})
        check("an unknown tool is a JSON-RPC error", r.json()["error"]["code"], -32602)

        r = c.post("/mcp", headers=auth, json={"jsonrpc": "2.0", "id": 5, "method": "initialize"})
        check("initialize advertises the tools capability",
              "tools" in r.json()["result"]["capabilities"], True)

        # A token minted for a different audience must not work here even though it is validly
        # signed by the same issuer -- this is the replay case.
        r = c.post("/mcp", headers={"Authorization": "Bearer " + issuer.sign(audience="agentgateway")},
                   json={"jsonrpc": "2.0", "id": 6, "method": "tools/list"})
        check("a gateway-audience token is refused at the MCP server", r.status_code, 401)

    issuer.stop()

    print("\nagent HTTP server")
    # The third serving workload. It needs the agent framework, so it is skipped rather than failed
    # when strands is absent -- check_route_gates.py still asserts its routes call a verifier.
    try:
        import strands  # noqa: F401, PLC0415
    except ImportError:
        print("  \033[33mSKIP\033[0m strands is not installed; agent server not exercised")
    else:
        issuer2 = _Issuer(_make_key())
        tokfile = Path(os.environ.get("TMPDIR", "/tmp")) / "eks-agents-test-token"
        tokfile.write_text(issuer2.sign(audience="agentgateway"))

        os.environ.update({
            "AGENT_NAME": "research",
            "AGENT_INBOUND_AUDIENCE": "research",
            "CLUSTER_OIDC_ISSUER": issuer2.url,
            "OPENAI_BASE_URL": "http://127.0.0.1:1/llm/research",
            "AGENT_IDENTITY_TOKEN_FILE": str(tokfile),
        })
        srv = load("agent_server", AGENTS_DIR / "reference" / "server.py")
        with TestClient(srv.app) as c:
            check("/healthz is open", c.get("/healthz").status_code, 200)
            check("/chat with no token is refused",
                  c.post("/chat", json={"prompt": "x"}).status_code, 401)
            check("/chat with a forged token is refused",
                  c.post("/chat", headers={"Authorization": "Bearer forged.not.ajwt"},
                         json={"prompt": "x"}).status_code, 401)
            # A token for the gateway's audience must not open the agent's own door.
            check("/chat with a gateway-audience token is refused",
                  c.post("/chat", headers={"Authorization": "Bearer " + issuer2.sign(audience="agentgateway")},
                         json={"prompt": "x"}).status_code, 401)

            good = {"Authorization": "Bearer " + issuer2.sign(audience="research")}
            check("/chat with a valid token is admitted",
                  c.post("/chat", headers=good, json={"prompt": "hello"}).status_code, 200)
            check("a missing prompt is rejected after the gate, not before",
                  c.post("/chat", headers=good, json={}).status_code, 400)
            check("/chat with a prompt over the limit is refused (413)",
                  c.post("/chat", headers=good, json={"prompt": "x" * (srv.MAX_PROMPT + 1)}).status_code, 413)
            check("/chat with a body over the limit is refused (413)",
                  c.post("/chat", headers=good, content=b"{" + b" " * (srv.MAX_BODY_BYTES + 1) + b"}",
                         ).status_code, 413)
            # The session id is what joins turns into one conversation in the trace backend and what
            # the evaluation runner fetches a trajectory by, so it has to round-trip and be bounded.
            r = c.post("/chat", headers=good, json={"prompt": "hello", "session_id": "eval-case-1"})
            check("a caller's session id comes back in X-Session-Id",
                  r.headers.get("x-session-id"), "eval-case-1")
            r = c.post("/chat", headers=good, json={"prompt": "hello"})
            check("a session id is generated when the caller sends none",
                  len(r.headers.get("x-session-id", "")) >= 32, True)
            check("a session id that could break a Logs Insights filter is rejected",
                  c.post("/chat", headers=good,
                         json={"prompt": "hello", "session_id": "x' or 1=1"}).status_code, 400)
            # The model endpoint is unreachable here, so the turn must surface as an error event in
            # the stream rather than a crash or a hung connection.
            body = c.post("/chat", headers=good, json={"prompt": "hello"}).text
            check("an unreachable model surfaces as an error event in the stream",
                  "error" in body and "[DONE]" in body, True)

            # TURNS PER PERSON: one person over the limit is refused 429 with Retry-After, another
            # person behind the same caller is not, and a person token's sub is the key.
            srv.TURNS_PER_PERSON_PER_MINUTE = 2
            srv._turns.clear()
            for _ in range(2):
                c.post("/chat", headers=good, json={"prompt": "hello", "user_id": "alice"})
            r = c.post("/chat", headers=good, json={"prompt": "hello", "user_id": "alice"})
            check("a person over the per-person limit is refused (429)", r.status_code, 429)
            check("the refusal says when to retry", int(r.headers.get("retry-after", "0")) >= 1, True)
            check("another person behind the same caller is admitted",
                  c.post("/chat", headers=good, json={"prompt": "hello", "user_id": "bob"}).status_code, 200)
            caller = "system:serviceaccount:default:test"
            def ptok(sub):
                enc = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).decode().rstrip("=")
                return enc({"alg": "RS256"}) + "." + enc({"sub": sub}) + ".sig"
            check("a person token's sub is the key, beneath the caller",
                  srv._person_key(caller, caller + "/anything", ptok("p-1")), caller + "/person:p-1")
            check("without a person token, the user_id the caller names is the key",
                  srv._person_key(caller, caller + "/alice", ""), caller + "/alice")
            check("a window refills after a minute",
                  (srv._admit_turn("k", 0.0), srv._admit_turn("k", 1.0), srv._admit_turn("k", 2.0) > 0,
                   srv._admit_turn("k", 61.0)), (0.0, 0.0, True, 0.0))
            srv.TURNS_PER_PERSON_PER_MINUTE = 0
            check("0 turns the limit off", all(srv._admit_turn("off") == 0.0 for _ in range(50)), True)

            # A SLOW AGENT BUILD DOES NOT STALL THE SERVER. Building the agent connects its MCP client,
            # which blocks until the tool server answers; on the event loop, a few such turns starved
            # /healthz and failed the liveness probe. With the build in a thread, /healthz answers at
            # once while a turn's build is still blocked.
            import asyncio, time as _time  # noqa: E401, PLC0415
            import httpx  # noqa: PLC0415
            real_build = srv.build_agent
            def slow_build(**_kw):
                _time.sleep(2)
                raise RuntimeError("tool server did not answer")
            srv.build_agent = slow_build
            async def race():
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=srv.app), base_url="http://t") as ac:
                    turn = asyncio.create_task(ac.post("/chat", headers=good, json={"prompt": "hello", "user_id": "slow"}))
                    await asyncio.sleep(0.2)
                    t0 = _time.monotonic()
                    hz = await ac.get("/healthz")
                    took = _time.monotonic() - t0
                    await turn
                    return hz.status_code, took
            code, took = asyncio.run(race())
            srv.build_agent = real_build
            check("/healthz answers while a turn's agent build is blocked", (code, took < 1.0), (200, True))
        issuer2.stop()
        tokfile.unlink(missing_ok=True)

    failed = [m for ok, m in RESULTS if not ok]
    print()
    if failed:
        for m in failed:
            print(f"\033[31m  {m}\033[0m")
        print(f"\033[31m{len(failed)} of {len(RESULTS)} route checks failed\033[0m")
        return 1
    print(f"\033[32mall {len(RESULTS)} route checks behave correctly\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
