"""The chat UI relays a turn to the agent, and the agent accepts the UI's own token.

    python apps/tests/test_relay.py


This is the handoff the architecture describes and nothing had exercised: the UI verifies the
person, then calls the agent with ITS OWN credential. If that token were wrong, or the agent's
audience check rejected it, the UI would report "agent returned 401" and the end-to-end demo would
fail with a message that looks like a UI bug.

The UI's own person-gate is bypassed here with its documented escape hatch, because forging an
ALB signature is not possible without AWS's private key. That gate is covered by test_services.py.
What is under test here is the second hop.

This test found two defects that nothing else would have: the credential was attached to a sync
httpx client the OpenAI SDK rejects at construction, and both the agent and the UI emitted a
terminating [DONE] so a client saw two per turn. Neither is visible without running both services
and looking at what crosses between them.
"""
import importlib.util, os, sys, threading, time
from pathlib import Path

AGENTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS / "common"))
sys.path.insert(0, str(AGENTS / "tests"))
from test_gates import _Issuer, _make_key  # noqa: E402

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec); sys.modules[name] = m
    spec.loader.exec_module(m); return m

issuer = _Issuer(_make_key())
tok = Path("/tmp/relay-ui-token"); tok.write_text(issuer.sign(audience="research"))

# The agent, on loopback.
os.environ.update({
    "AGENT_NAME": "research", "AGENT_INBOUND_AUDIENCE": "research",
    "CLUSTER_OIDC_ISSUER": issuer.url,
    "OPENAI_BASE_URL": "http://127.0.0.1:1/llm/research",
    "AGENT_IDENTITY_TOKEN_FILE": str(tok),
    "AGENT_BIND_HOST": "127.0.0.1", "AGENT_PORT": "8771",
})
srv = load("agent_server", AGENTS / "reference" / "server.py")
import uvicorn
cfg = uvicorn.Config(srv.app, host="127.0.0.1", port=8771, log_level="error")
server = uvicorn.Server(cfg)
threading.Thread(target=server.run, daemon=True).start()
for _ in range(80):
    time.sleep(0.1)
    if server.started: break

# The UI, pointed at it.
os.environ.update({
    "CHAT_UI_AGENTS": "research=http://127.0.0.1:8771",
    "AWS_REGION": "us-west-2",
    "AGENT_IDENTITY_TOKEN_FILE": str(tok),
    "AUTH_TEST_BYPASS": "i-understand-this-is-insecure",
})
ui = load("chatui", AGENTS / "chat-ui" / "app.py")
from fastapi.testclient import TestClient

fails = []
with TestClient(ui.app) as c:
    r = c.post("/chat?agent=research", json={"prompt": "hello"})
    body = r.text
    print("status:", r.status_code)
    print("stream:", body.replace("\n", " ")[:260])

    if r.status_code != 200:
        fails.append(f"UI did not relay: HTTP {r.status_code}")
    if "agent returned 401" in body:
        fails.append("the agent REFUSED the UI's token: the credential handoff is broken")
    if "[DONE]" not in body:
        fails.append("the stream did not terminate with [DONE]")
    # The model endpoint is dead, so an error event is expected -- it proves the request reached the
    # agent's turn rather than being refused at its door.
    if "error" not in body:
        fails.append("expected an error event from the unreachable model")

    r2 = c.post("/chat?agent=nope", json={"prompt": "x"})
    if r2.status_code != 400:
        fails.append(f"an unknown agent should be 400 after the gate, got {r2.status_code}")

    # WHO THE TURN IS FOR. The UI must name the signed-in person to the agent as user_id, or every
    # person behind the UI shares the UI's one memory scope. Two people, through a stand-in agent
    # that records what arrives.
    from types import SimpleNamespace
    alice = SimpleNamespace(subject="alice@example.com", claims={"sub": "a1b2c3d4-aaaa-4aaa-8aaa-aaaaaaaaaaa1"})
    bob = SimpleNamespace(subject="bob@example.com", claims={"sub": "b1b2c3d4-bbbb-4bbb-8bbb-bbbbbbbbbbb2"})
    noclaims = SimpleNamespace(subject="carol@example.com", claims={})
    if ui.person_scope(alice) != "a1b2c3d4-aaaa-4aaa-8aaa-aaaaaaaaaaa1":
        fails.append(f"person_scope ignores the verified sub: {ui.person_scope(alice)}")
    if ui.person_scope(alice) == ui.person_scope(bob):
        fails.append("two people get the same scope")
    if not srv.SESSION_ID_PATTERN.match(ui.person_scope(noclaims)):
        fails.append(f"an email-only subject gives a user_id the agent refuses: {ui.person_scope(noclaims)}")
    seen = []
    import httpx as _httpx
    real_client = _httpx.AsyncClient
    class Recorder(real_client):
        def stream(self, method, url, **kw):
            seen.append(kw.get("json"))
            return super().stream(method, url, **kw)
    ui.httpx.AsyncClient = Recorder
    try:
        for who in (alice, bob):
            ui._verified = lambda request, who=who: who
            c.post("/chat?agent=research", json={"prompt": "hello"})
    finally:
        ui.httpx.AsyncClient = real_client
    sent = [(j or {}).get("user_id") for j in seen]
    print("user_id relayed:", sent)
    if sent != [ui.person_scope(alice), ui.person_scope(bob)]:
        fails.append(f"the UI did not relay each person's scope as user_id: {sent}")

server.should_exit = True
issuer.stop(); tok.unlink(missing_ok=True)

print()
if fails:
    for f in fails: print("FAIL:", f)
    sys.exit(1)
print("\033[32mthe UI relayed a turn, the agent accepted the UI's own token, and each person arrived as their own user_id\033[0m")
