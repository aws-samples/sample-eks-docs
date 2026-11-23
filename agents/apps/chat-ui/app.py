"""A chat UI, so an operator can talk to an agent and see the end-to-end path work.

Without this, the model call through the gateway is something you assert from a log line. With it,
you type a question and watch tokens arrive, which is the demonstration the architecture diagrams
describe.

It is deliberately one file and no front-end framework: a static page, an SSE proxy to the agent,
and nothing else. The UI is not the point.

WHO MAY USE IT, and why this is the most carefully gated service in the repository.

A chat UI in front of an agent is a restricted audience -- operators, not the public -- and it is
reachable through ingress, which is the only component here that an external network touches.
So it has a real gate rather than a header check:

  1. The ALB runs the OIDC flow (`ListenerRuleConfiguration` on the route) and signs the resulting
     claims into x-amzn-oidc-data.
  2. This service verifies that signature against the regional ALB public key endpoint, checks
     expiry, and takes the person's identity from the verified claims.
  3. Only then does it call the agent, presenting its OWN projected service account token -- not
     the person's. The agent authorizes the UI as a workload; the person's identity travels as
     context for the audit log, never as authority.

Point 3 is the part worth pausing on. Carrying a person's authority through to the agent is the
delegation problem, and nothing in this stack solves it: the agent's own IAM role is what bounds
what the turn can do, whoever asked for it. So a person who may use this UI can cause anything the
agent's role permits. Scope the agent's role accordingly, and keep the UI's route restricted to the
operators you mean.

If x-amzn-oidc-data is absent or does not verify, every request to /chat is refused. There is no
configuration that serves this UI unauthenticated -- the fail-closed path is the only path.
"""

from __future__ import annotations

import base64
import hashlib
import html
import json
import logging
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

import httpx  # noqa: E402
import uvicorn  # noqa: E402
from cluster_auth import PERSON_TOKEN_HEADER, AuthError, person_token, verify_alb_oidc  # noqa: E402
from fastapi import FastAPI, HTTPException, Request  # noqa: E402
from fastapi.responses import HTMLResponse, StreamingResponse  # noqa: E402

log = logging.getLogger("chat-ui")

# The agents this UI offers, as name=url pairs: "research=http://research.agents.svc:8080".
# Configuration rather than discovery, so the UI cannot be pointed at a workload nobody approved by
# anything that can create a Service.
AGENTS = {}
for pair in os.environ.get("CHAT_UI_AGENTS", "").split(","):
    name, _, url = pair.partition("=")
    if name.strip() and url.strip():
        AGENTS[name.strip()] = url.strip().rstrip("/")

# This UI's own credential for calling an agent. The Agent-resource-shaped projected token, with the
# audience naming the agent being called.
TOKEN_FILE = os.environ.get("AGENT_IDENTITY_TOKEN_FILE", "")

# Forward the signed-in person's own access token to the agent (enable_person_access), so a tool can
# act with that person's authority rather than this UI's. Off: the agent gets the person as context
# (user_id) and nothing it could act on.
FORWARD_PERSON_TOKEN = os.environ.get("CHAT_UI_FORWARD_PERSON_TOKEN", "").strip().lower() == "true"
REGION = os.environ.get("AWS_REGION", "")
# Which load balancer and identity-provider client may sign x-amzn-oidc-data. Every ALB in a
# Region signs with the same keys, so the signature alone admits another account's ALB.
ALB_ACCOUNT_ID = os.environ.get("ALB_EXPECTED_ACCOUNT_ID", "")
ALB_CLIENT_ID = os.environ.get("ALB_EXPECTED_CLIENT_ID", "")

# All interfaces inside the container, no host port published. Exposure is governed by the
# ClusterIP Service and the HTTPRoute, whose load balancer defaults to `internal`; see
# gitops/examples/chat-ui. Narrowing to loopback would break the readiness probe and the Service.
HOST = os.environ.get("CHAT_UI_BIND_HOST", "0.0.0.0")  # noqa: S104 - see the comment above


def _port() -> int:
    """The listen port, ignoring a value Kubernetes injected rather than a human.

    KUBERNETES WILL SHADOW THIS KEY. With service links enabled -- the default -- the kubelet
    injects one environment variable per Service in the namespace, named from the Service with
    dashes as underscores and uppercased. A Service called `chat-ui` therefore sets
    CHAT_UI_PORT=tcp://10.100.62.101:8080, which is exactly this variable, and `int()` on it
    crash-loops the pod:

        ValueError: invalid literal for int() with base 10: 'tcp://10.100.62.101:8080'

    It reads as a broken image rather than a name collision. The
    manifests set `enableServiceLinks: false`, which is the real fix; this is the second line of
    defence, because nothing stops someone deploying this without that field.

    A service-link value is recognised rather than merely rejected: it means the variable was not
    set by configuration at all, so the default is correct and silence is right.
    """
    raw = os.environ.get("CHAT_UI_PORT", "").strip()
    if not raw or "://" in raw:
        return 8080
    try:
        return int(raw)
    except ValueError:
        sys.exit(
            f"CHAT_UI_PORT is {raw!r}, which is not a port number. Unset it to use 8080."
        )


PORT = _port()

# FastAPI's own OpenTelemetry tracing, metrics and logs are off. They would make an HTTP server span
# with no session id the root of every trace, above the agent's invoke_agent span, and the evaluation
# runner, which reads a session's spans from Langfuse, then finds no agent invocation and grades
# nothing. The GenAI spans this image exports are the ones the platform reads.
app = FastAPI(title="eks-agents chat", docs_url=None, redoc_url=None,
              telemetry={"tracing": False, "metrics": False, "logs": False})

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Agents on EKS</title>
<style>
 :root { color-scheme: light dark; --fg:#0f1b2d; --dim:#5b6b80; --line:#d6dde6; --accent:#1d4ed8; }
 @media (prefers-color-scheme: dark) {
   :root { --fg:#e8eef6; --dim:#93a4b8; --line:#2a3647; --accent:#7aa2ff; } body { background:#0d1420; }
 }
 body { font:15px/1.55 ui-sans-serif,system-ui,-apple-system,sans-serif; color:var(--fg);
        max-width:46rem; margin:0 auto; padding:2rem 1.25rem 4rem; }
 h1 { font-size:1.15rem; margin:0 0 .25rem; }
 .sub { color:var(--dim); font-size:.85rem; margin:0 0 1.5rem; }
 .who { color:var(--dim); font-size:.78rem; border:1px solid var(--line); border-radius:999px;
        padding:.15rem .6rem; display:inline-block; }
 #log { margin:1.5rem 0; }
 .turn { margin:0 0 1.25rem; }
 .role { font-size:.72rem; letter-spacing:.06em; text-transform:uppercase; color:var(--dim); }
 .body { white-space:pre-wrap; margin-top:.2rem; }
 form { display:flex; gap:.5rem; align-items:flex-start; }
 select, textarea, button { font:inherit; border:1px solid var(--line); border-radius:.5rem;
        padding:.5rem .6rem; background:transparent; color:inherit; }
 textarea { flex:1; resize:vertical; min-height:3.1rem; }
 button { background:var(--accent); color:#fff; border-color:transparent; cursor:pointer; }
 button[disabled] { opacity:.55; cursor:progress; }
 .err { color:#b4232a; }
</style></head><body>
<h1>Agents on EKS</h1>
<p class="sub">Signed in as <span class="who">__WHO__</span> &middot; the turn runs in a Nitro
sandbox and reaches its model through the egress gateway.</p>
<div id="log"></div>
<form id="f">
  <select id="agent">__OPTIONS__</select>
  <textarea id="p" placeholder="Ask the agent something" autofocus></textarea>
  <button id="go">Send</button>
</form>
<script>
const log = document.getElementById('log');
function turn(role, text, cls) {
  const d = document.createElement('div'); d.className = 'turn';
  const r = document.createElement('div'); r.className = 'role'; r.textContent = role;
  const b = document.createElement('div'); b.className = 'body ' + (cls || ''); b.textContent = text;
  d.append(r, b); log.append(d); window.scrollTo(0, document.body.scrollHeight); return b;
}
document.getElementById('f').addEventListener('submit', async (e) => {
  e.preventDefault();
  const prompt = document.getElementById('p').value.trim();
  if (!prompt) return;
  const agent = document.getElementById('agent').value;
  const go = document.getElementById('go');
  document.getElementById('p').value = '';
  turn('you', prompt);
  const out = turn(agent, '');
  go.disabled = true;
  try {
    const res = await fetch('chat?agent=' + encodeURIComponent(agent), {
      method: 'POST', headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({prompt}),
    });
    if (!res.ok) { out.textContent = 'refused: HTTP ' + res.status; out.className = 'body err';
                   go.disabled = false; return; }
    const reader = res.body.getReader(); const dec = new TextDecoder(); let buf = '';
    for (;;) {
      const {value, done} = await reader.read(); if (done) break;
      buf += dec.decode(value, {stream: true});
      const lines = buf.split('\\n'); buf = lines.pop();
      for (const line of lines) {
        if (!line.startsWith('data:')) continue;
        const payload = line.slice(5).trim();
        if (payload === '[DONE]') continue;
        try { const o = JSON.parse(payload);
              if (o.delta) out.textContent += o.delta;
              if (o.error) { out.textContent += '\\n[error] ' + o.error; out.className = 'body err'; }
        } catch (_) {}
      }
    }
  } catch (err) { out.textContent = 'transport error: ' + err; out.className = 'body err'; }
  go.disabled = false;
});
</script></body></html>
"""


def _verified(request: Request):
    """Verify the ALB-signed claims and return the person, or raise 401."""
    try:
        return verify_alb_oidc(
            dict(request.headers), region=REGION, account_id=ALB_ACCOUNT_ID, client_id=ALB_CLIENT_ID
        )
    except AuthError as exc:
        log.info("refused a request: %s", exc)
        raise HTTPException(status_code=401, detail="unauthenticated") from exc


def _person(request: Request) -> str:
    return _verified(request).subject


# The agent's user_id rule (apps/reference/server.py SESSION_ID_PATTERN).
_USER_ID_OK = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")


def person_scope(caller) -> str:
    """The user_id this person's turns carry, which the agent scopes saved sessions and memories by.

    WHY THE UI SENDS ONE. The agent authorizes this UI as one workload, so to the agent every person
    signed in here is the same caller. It keeps people apart only by the user_id a verified caller
    names, beneath the caller's own subject. Without it, everyone using the UI shared one memory
    scope: what one person told a consolidating agent could be recalled in another person's turn.

    The provider's `sub` is stable and unique per person; an email is not a valid user_id (`@`), so
    a subject that does not fit the agent's pattern is digested instead.
    """
    sub = str((getattr(caller, "claims", None) or {}).get("sub") or "")
    if _USER_ID_OK.match(sub):
        return sub
    return "p-" + hashlib.sha256(caller.subject.encode()).hexdigest()[:40]


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Liveness and readiness. No authentication, no input, no agent data."""
    return {"status": "ok", "agents": ",".join(sorted(AGENTS))}


@app.get("/")
def index(request: Request) -> HTMLResponse:
    # The page itself is gated too. Serving the shell to an unauthenticated caller would leak which
    # agents exist, and the operator would then hit a 401 on their first turn with no explanation.
    # Both go into the page as HTML, and the page's CSP allows inline script, so escaping is the
    # control: a subject or an agent name with markup in it renders as text.
    who = html.escape(_person(request))
    options = "".join(f'<option value="{html.escape(n, quote=True)}">{html.escape(n)}</option>' for n in sorted(AGENTS))
    if not options:
        options = '<option value="">no agents configured</option>'
    page = PAGE.replace("__WHO__", who).replace("__OPTIONS__", options)
    return HTMLResponse(page, headers={
        # No inline-script allowance beyond this page's own, and nothing embeds it.
        "Content-Security-Policy":
            "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
            "connect-src 'self'; frame-ancestors 'none'",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
        "Cache-Control": "no-store",
    })


def forwarded_person_token(request: Request, caller) -> str:
    """The person's access token from the load balancer, when it is the verified person's.

    The load balancer puts it in x-amzn-oidc-accesstoken next to the claims it signed. It is the
    identity provider's token, signed by the provider -- so this UI does not verify it (the tool that
    acts on it does) -- but it is bound here: forwarded only when its subject is the subject of the
    claims verified above, so a request can never carry one person's claims and another's token.
    """
    if not FORWARD_PERSON_TOKEN:
        return ""
    token = person_token({PERSON_TOKEN_HEADER: request.headers.get("x-amzn-oidc-accesstoken", "")})
    if not token:
        return ""
    try:
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        sub = json.loads(base64.urlsafe_b64decode(part)).get("sub", "")
    except Exception:  # noqa: BLE001
        return ""
    if not sub or sub != (caller.claims or {}).get("sub"):
        log.warning("not forwarding an access token whose subject is not the signed-in person's")
        return ""
    return token


@app.post("/chat")
async def chat(request: Request) -> StreamingResponse:
    caller = _verified(request)
    person = caller.subject

    agent = request.query_params.get("agent", "")
    if agent not in AGENTS:
        raise HTTPException(status_code=400, detail="unknown agent")

    body = await request.json()
    prompt = (body or {}).get("prompt", "").strip()
    if not prompt:
        raise HTTPException(status_code=400, detail="prompt is required")

    if not TOKEN_FILE:
        # Fail closed: without its own credential this UI cannot authenticate to the agent, and the
        # agent would refuse it anyway. Saying so here is clearer than a 401 from downstream.
        raise HTTPException(status_code=503, detail="this UI has no agent credential configured")

    # Re-read per request: the kubelet rewrites the projected token in place when it refreshes it.
    token = Path(TOKEN_FILE).read_text().strip()
    on_behalf = forwarded_person_token(request, caller)
    log.info("turn for %s against %s%s", person, agent, ", with their token" if on_behalf else "")

    async def relay():
        try:
            async with httpx.AsyncClient(timeout=httpx.Timeout(300.0, connect=10.0)) as client:
                async with client.stream(
                    "POST",
                    f"{AGENTS[agent]}/chat",
                    headers={
                        "Authorization": f"Bearer {token}",
                        "Content-Type": "application/json",
                        # The person's identity as context for the agent's own audit trail. It is
                        # NOT authority: the agent authorizes this UI as a workload, and its own IAM
                        # role bounds the turn whoever asked for it.
                        "X-Agent-On-Behalf-Of": person,
                        # The person's own token (enable_person_access): what a tool verifies to
                        # act with this person's authority. Absent, the turn is the UI's alone.
                        **({PERSON_TOKEN_HEADER: on_behalf} if on_behalf else {}),
                    },
                    # Who the turn is for, as the agent's scope for sessions and memories -- not as
                    # authority (see person_scope).
                    json={"prompt": prompt, "user_id": person_scope(caller)},
                ) as upstream:
                    if upstream.status_code != 200:
                        detail = (await upstream.aread()).decode()[:200]
                        yield f"data: {json.dumps({'error': f'agent returned {upstream.status_code}: {detail}'})}\n\n"
                        return
                    async for line in upstream.aiter_lines():
                        if not line.startswith("data:"):
                            continue
                        # Swallow the agent's terminator. This relay emits exactly one, in the
                        # finally below, so a client never sees two [DONE] events for one turn.
                        if line.strip() == "data: [DONE]":
                            continue
                        yield line + "\n\n"
        except Exception as exc:  # noqa: BLE001
            log.exception("relay failed for %s", person)
            yield f"data: {json.dumps({'error': str(exc)[:200]})}\n\n"
        finally:
            yield "data: [DONE]\n\n"

    return StreamingResponse(relay(), media_type="text/event-stream", headers={
        "Cache-Control": "no-store", "X-Accel-Buffering": "no",
    })


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    if not REGION:
        sys.exit(
            "Refusing to serve: AWS_REGION is required to fetch the ALB signing key that verifies "
            "the operator's identity. Without it no request could be authenticated."
        )
    if not AGENTS:
        log.warning("CHAT_UI_AGENTS is empty: the UI will render with no agent to talk to.")
    log.info("serving on %s:%s for agents %s", HOST, PORT, ",".join(sorted(AGENTS)) or "(none)")
    uvicorn.run(app, host=HOST, port=PORT, log_level=os.environ.get("LOG_LEVEL", "info").lower())


if __name__ == "__main__":
    main()
