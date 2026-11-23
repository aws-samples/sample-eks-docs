"""The reference agent as an HTTP service, so something can talk to it.

The CLI in app.py takes one prompt and exits, which is enough to prove the model path and not enough
to demonstrate anything end to end. This serves the same agent over HTTP so the chat UI, another
agent, or a schedule can call it.

    AGENT_SERVE=1 python server.py        # or just: python server.py

Two endpoints:

    GET  /healthz    liveness and readiness. Unauthenticated by design -- the kubelet calls it, it
                     takes no input and returns no agent data.
    POST /chat       {"prompt": "...", "session_id": "...", "user_id": "..."} -> server-sent events, one `data:` per
                     chunk. session_id is optional: a new one is generated when it is absent, and
                     either way it comes back in the X-Session-Id response header. Send it again to
                     continue the conversation in the same session.

WHY STREAMING. The load balancer's idle timeout is a raised limit rather than a removed one, so a
response that goes quiet while the agent thinks can be cut off mid-turn. A stream that emits text as
it arrives keeps the connection busy. This is the same reason agent chat runs over WebSocket and the
same reason session state lives outside the pod.

WHO MAY CALL IT. Every request to /chat must present a projected service account token whose
audience names this agent, verified against the cluster's OIDC issuer -- the same mechanism the
egress gateway uses, so a caller needs no second credential. There is no unauthenticated path to the
agent.

That check is here, in the application, rather than being left to the mesh. The mesh is the stronger
control when it is on, because it verifies both ends below the application and an agent cannot
decline it -- but mesh_mode is `none` by default on both paths, and a service whose only
gate is an optional component is ungated on the default configuration. Both run together where the
mesh is on: the mesh decides which workloads may connect, this decides whether the caller presented
a credential naming this agent.
"""

from __future__ import annotations

import asyncio
import base64
import collections
import json
import logging
import os
import re
import sys
import time
import uuid
from pathlib import Path

# The shared verifier. Copied into the image next to this file; see the Dockerfile.
sys.path.insert(0, str(Path(__file__).parent))

import uvicorn  # noqa: E402
from cluster_auth import AuthError, allowed_namespaces_from_env, bearer_token, person_token, verify_cluster_token  # noqa: E402
from fastapi import FastAPI, Header, HTTPException, Request  # noqa: E402
from fastapi.responses import StreamingResponse  # noqa: E402
from opentelemetry import baggage, context  # noqa: E402

from app import build_agent, setup_telemetry  # noqa: E402

log = logging.getLogger("agent.server")

# The audience a caller's token must name to reach this agent. The Agent resource sets it to the
# agent's own name, so a token minted for the gateway cannot be replayed here.
INBOUND_AUDIENCE = os.environ.get("AGENT_INBOUND_AUDIENCE", "") or os.environ.get("AGENT_NAME", "")
OIDC_ISSUER = os.environ.get("CLUSTER_OIDC_ISSUER", "")
# Who may call this agent, by the caller's namespace. The Agent resource sets its own namespace;
# empty admits any namespace, for a developer running the server outside a cluster.
ALLOWED_CALLER_NAMESPACES = allowed_namespaces_from_env("AGENT_ALLOWED_CALLER_NAMESPACES")

# Bind to every interface inside the container, and publish nothing.
#
# This is the correct shape for a Kubernetes workload and not an exposure: the pod publishes no host
# port, the Service the Agent resource creates is ClusterIP, and the only route in from outside the
# cluster is the shared Gateway, whose load balancer defaults to `internal`. Narrowing this to
# loopback would make the pod unreachable from its own Service and break the readiness probe.
#
# What governs exposure is therefore the Service and the route, not this bind. See
# gitops/examples/mcp-ingress for ingress, and `expose` on the Agent resource for whether
# one is created at all.
HOST = os.environ.get("AGENT_BIND_HOST", "0.0.0.0")  # noqa: S104 - see the comment above
PORT = int(os.environ.get("AGENT_PORT", "8080"))

# FastAPI's own OpenTelemetry tracing, metrics and logs are off. They would make an HTTP server span
# with no session id the root of every trace, above the agent's invoke_agent span, and the evaluation
# runner, which reads a session's spans from Langfuse, then finds no agent invocation and grades
# nothing. The GenAI spans this image exports are the ones the platform reads.
app = FastAPI(title="eks-agents reference agent", docs_url=None, redoc_url=None,
              telemetry={"tracing": False, "metrics": False, "logs": False})

_ready = False
_gateway_url = ""

# What a caller may send as a session id. It becomes a span attribute and a Langfuse session key, so
# it is bounded and restricted to characters that cannot break a query in either backend: the
# CloudWatch provider interpolates it into a Logs Insights `like` filter.
SESSION_ID_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")

# The largest turn this server accepts. A prompt over MAX_PROMPT characters, or a body over
# MAX_BODY_BYTES, is refused with 413 before the body is parsed or any model call is made, so an
# authenticated caller cannot spend the agent's model budget or memory on one oversized request.
# The task worker applies the same prompt limit.
MAX_PROMPT = int(os.environ.get("AGENT_MAX_PROMPT_CHARS", "20000") or 20000)
MAX_BODY_BYTES = 4 * MAX_PROMPT + 8192

# TURNS PER PERSON, so one signed-in person cannot exhaust an agent that many people share. The
# gateway's model budget is keyed on the calling agent, which every person behind it shares; this
# is the limit keyed on the person a turn is for. That person is the one the verified caller names:
# the sub of the person token it forwards, else its user_id (the chat UI names the signed-in
# person's sub, which the load balancer verified), else the caller itself. A caller can only rename
# the people beneath its own subject, so it cannot spend another caller's allowance. Counted in this
# pod, over a sliding minute: an agent's runtime is one pod by default. 0 turns the limit off.
TURNS_PER_PERSON_PER_MINUTE = int(os.environ.get("AGENT_TURNS_PER_PERSON_PER_MINUTE", "20") or 0)
_TURN_WINDOW_SECONDS = 60.0
_TURN_KEYS_MAX = 10000
_turns: "collections.OrderedDict[str, collections.deque]" = collections.OrderedDict()


def _person_key(caller: str, user_id: str, person: str) -> str:
    """Who a turn is for, for the per-person limit, always beneath the verified caller."""
    if person:
        try:
            part = person.split(".")[1]
            sub = json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))).get("sub", "")
        except Exception:  # noqa: BLE001 - an unreadable token is keyed by the caller's naming below
            sub = ""
        if isinstance(sub, str) and sub and SESSION_ID_PATTERN.match(sub):
            return f"{caller}/person:{sub}"
    return user_id


def _admit_turn(key: str, now: float | None = None) -> float:
    """0 if the person may start a turn now (and count it), else the seconds until they may."""
    if TURNS_PER_PERSON_PER_MINUTE <= 0:
        return 0.0
    now = time.monotonic() if now is None else now
    q = _turns.pop(key, None) or collections.deque()
    while q and now - q[0] >= _TURN_WINDOW_SECONDS:
        q.popleft()
    wait = 0.0
    if len(q) >= TURNS_PER_PERSON_PER_MINUTE:
        wait = _TURN_WINDOW_SECONDS - (now - q[0])
    else:
        q.append(now)
    _turns[key] = q
    while len(_turns) > _TURN_KEYS_MAX:
        _turns.popitem(last=False)
    return wait


@app.on_event("startup")
def _startup() -> None:
    """Prove the agent can be built, and refuse to start if it cannot.

    An agent that starts without its model endpoint or its credential passes its readiness probe,
    rolls out, and then fails while serving traffic. Building one here means the rollout stops
    instead.

    The instance built here is discarded. Each turn builds its own, because the credential is read
    when the model is built and the kubelet rewrites the token file in place -- an agent holding one
    built at startup would work until the first token refresh and fail afterwards.
    """
    global _ready, _gateway_url
    # Once per process, not per turn: a provider per request would leak exporters.
    setup_telemetry()
    _, _gateway_url = build_agent()
    _ready = True

    if not INBOUND_AUDIENCE or not OIDC_ISSUER:
        # Fail closed, loudly, rather than serving an unauthenticated agent. Both values come from
        # the Agent resource; a pod without them cannot verify any caller.
        sys.exit(
            "Refusing to serve: AGENT_INBOUND_AUDIENCE (or AGENT_NAME) and CLUSTER_OIDC_ISSUER are "
            "both required to verify a caller's token. The Agent resource sets them. Without them "
            "every request would have to be admitted unchecked, so this exits instead."
        )

    log.info(
        "serving on %s:%s, model endpoint %s, inbound audience %r",
        HOST, PORT, _gateway_url, INBOUND_AUDIENCE,
    )


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Liveness and readiness. No authentication, no input, no agent data."""
    return {"status": "ok" if _ready else "starting"}


def _verify(request: Request) -> str:
    """Verify the caller and return its subject, or raise 401."""
    try:
        caller = verify_cluster_token(
            bearer_token(dict(request.headers)),
            audience=INBOUND_AUDIENCE,
            issuer=OIDC_ISSUER,
            allowed_namespaces=ALLOWED_CALLER_NAMESPACES,
        )
    except AuthError as exc:
        # 401 with the reason, because every failure here is a credential problem the caller can
        # act on. The reason names what was wrong with the token, never why a key fetch failed in a
        # way that would describe this service's configuration to an unauthenticated caller.
        log.info("refused a request: %s", exc)
        raise HTTPException(status_code=401, detail="unauthenticated") from exc
    return caller.subject


@app.post("/chat")
async def chat(request: Request, accept: str = Header(default="")) -> StreamingResponse:
    subject = _verify(request)

    declared = request.headers.get("content-length", "")
    if declared.isdigit() and int(declared) > MAX_BODY_BYTES:
        raise HTTPException(status_code=413, detail=f"the request body is over {MAX_BODY_BYTES} bytes")
    raw = await request.body()
    if len(raw) > MAX_BODY_BYTES:
        raise HTTPException(status_code=413, detail=f"the request body is over {MAX_BODY_BYTES} bytes")
    try:
        body = json.loads(raw or b"{}")
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=400, detail="body must be JSON") from exc
    if not isinstance(body, dict):
        raise HTTPException(status_code=400, detail="body must be a JSON object")

    prompt = str(body.get("prompt") or "").strip()
    if not prompt:
        raise HTTPException(status_code=400, detail="prompt is required")
    if len(prompt) > MAX_PROMPT:
        raise HTTPException(status_code=413, detail=f"prompt is longer than {MAX_PROMPT} characters")

    session_id = str((body or {}).get("session_id") or "").strip() or str(uuid.uuid4())
    # Whose memories a consolidating agent recalls and writes: ALWAYS the verified caller, and the
    # user it names only beneath that. A body field alone would let any authenticated caller ask
    # for anyone's memories by naming them. Scoped under the caller's own subject, a front end such
    # as the chat UI (one verified caller, many signed-in people) keeps its people apart, and no
    # other caller can reach them by naming the same user.
    named_user = str((body or {}).get("user_id") or "").strip()
    if named_user and not SESSION_ID_PATTERN.match(named_user):
        raise HTTPException(status_code=400, detail="user_id must be 1-128 characters of letters, digits and . _ : -")
    user_id = f"{subject}/{named_user}" if named_user else subject
    if not SESSION_ID_PATTERN.match(session_id):
        raise HTTPException(
            status_code=400,
            detail="session_id must be 1-128 characters of letters, digits and . _ : -",
        )

    # The person's own token, when the caller sent one (the chat UI with enable_person_access, or an
    # application that signed the person in). Not authority here: the caller above is what this agent
    # authorized. It is passed on, so a tool or AWS can decide what that person may reach.
    on_behalf = person_token(dict(request.headers))

    wait = _admit_turn(_person_key(subject, user_id, on_behalf))
    if wait > 0:
        log.info("turn refused for %s: over %d turns a minute for this person", user_id, TURNS_PER_PERSON_PER_MINUTE)
        raise HTTPException(status_code=429, detail=f"over {TURNS_PER_PERSON_PER_MINUTE} turns a minute for this person",
                            headers={"Retry-After": str(max(1, int(wait + 0.999)))})

    log.info("turn for %s in session %s: %d chars%s", subject, session_id, len(prompt),
             ", with a person token" if on_behalf else "")

    async def events():
        """Emit the agent's output as server-sent events.

        Strands' stream_async yields events as the model produces them. Anything that is not a text
        delta is skipped rather than forwarded: the internal event shape is not this service's
        contract, and a client that parsed it would break on a library upgrade.
        """
        # Built per turn, so the token is current. OFF THE EVENT LOOP: building the agent connects its
        # MCP client, which blocks until the tool server answers (up to its startup timeout), and the
        # memory tier may open a connection. On the event loop that would stall every other turn and
        # /healthz with it, so a few turns against a slow tool server would fail the liveness probe
        # and restart the agent.
        # A build that fails (the tool server down with AGENT_TOOLS_REQUIRED, a memory tier refusing)
        # is reported in the stream like a failed turn, not as a broken connection.
        token = None
        try:
            agent, _ = await asyncio.to_thread(build_agent, session_id=session_id, user_id=user_id, person_token=on_behalf)

            # Baggage as well as the span attribute build_agent sets. The attribute is what reaches the
            # trace backend; baggage is what carries the session onward on the agent's own outbound
            # calls, and it is the form AWS's guide for agents outside AgentCore Runtime shows.
            token = context.attach(baggage.set_baggage("session.id", session_id))
            async for event in agent.stream_async(prompt):
                chunk = ""
                if isinstance(event, dict):
                    chunk = event.get("data") or ""
                elif isinstance(event, str):
                    chunk = event
                if chunk:
                    yield f"data: {json.dumps({'delta': chunk})}\n\n"
        except Exception as exc:  # noqa: BLE001
            # The turn failed mid-stream. The status line is already sent, so the only way to tell
            # the client is in the stream itself.
            log.exception("turn failed for %s", subject)
            yield f"data: {json.dumps({'error': str(exc)[:200]})}\n\n"
        finally:
            if token is not None:
                context.detach(token)
            yield "data: [DONE]\n\n"

    return StreamingResponse(
        events(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-store", "X-Accel-Buffering": "no", "X-Session-Id": session_id},
    )


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    uvicorn.run(app, host=HOST, port=PORT, log_level=os.environ.get("LOG_LEVEL", "info").lower())


if __name__ == "__main__":
    main()
