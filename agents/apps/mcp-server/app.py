"""A small MCP server, so the tool path has something on the end of it.

The gateway on both paths is configured to aggregate MCP servers and this repository shipped none,
which left `tools/list` returning an empty catalogue and the tool half of the architecture
undemonstrated. This is that missing piece: three tools over MCP's streamable HTTP transport.

The tools are deliberately dull -- a clock, a cluster fact, and a deterministic order lookup over a
fixed dict. What is being demonstrated is the path (agent -> gateway -> MCP server, with a verified
identity at each hop) rather than the tools. Replace them with yours; nothing below depends on what
they do.

WHO MAY CALL IT. Behind the gateway, the gateway does -- it authenticates the agent and forwards no
caller token, so `MCP_REQUIRE_TOKEN=false` defers to the AuthorizationPolicy and network policy that
admit only the gateway. Reached directly, every MCP request must present a projected service account
token whose audience
names this server, verified against the cluster's OIDC issuer. The caller is the gateway on the open
source path, or an agent reaching it directly in-cluster; either way it is a workload with a token
this cluster issued, so there is no new credential type and nothing minted here.

REACHABILITY DIFFERS BY PATH, and it is worth knowing before you wire it:

  open source   AgentGateway runs in the cluster and aggregates this server as an MCP target,
                selected by label. Set mcpServers in gitops/charts/agentgateway-config.

  AWS services  AgentCore Gateway runs outside the cluster, so it cannot reach a ClusterIP Service.
                An agent on that path reaches this server directly over the mesh -- east-west
                traffic the mesh and the network policy govern, not egress -- and AgentCore
                aggregates MCP servers that are already reachable from AWS. Exposing this one to
                AgentCore instead would mean putting it behind ingress and giving the gateway
                a credential for it, which is a larger change than it looks and is not what these
                templates do.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import logging
import os
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).parent))

import uvicorn  # noqa: E402
from cluster_auth import (  # noqa: E402
    AuthError,
    allowed_namespaces_from_env,
    bearer_token,
    delegated_token,
    person_token,
    verify_cluster_token,
    verify_delegated_token,
    verify_person_token,
)
from fastapi import FastAPI, HTTPException, Request  # noqa: E402

log = logging.getLogger("mcp")

INBOUND_AUDIENCE = os.environ.get("MCP_INBOUND_AUDIENCE", "mcp-server")

# WHETHER THIS SERVER AUTHENTICATES ITS CALLER AT ALL, and the reason it is a choice.
#
# Behind an aggregating gateway it cannot. The gateway authenticates the agent, terminates that
# credential, and forwards the request upstream WITHOUT the caller's bearer token: the gateway logs
# `jwt.sub=system:serviceaccount:agents:orchestrator` on the same request this server refuses with
# "no bearer token on the request". There is nothing for the
# server to verify, whatever audience it is configured with.
#
# So on that topology the gateway IS the authentication boundary, and what keeps other workloads out
# is the pair of objects gitops/examples/mcp-server ships beside this: an Istio AuthorizationPolicy
# admitting only the gateway's principal, and an ApplicationNetworkPolicy admitting only its pods.
# Those are enforced by infrastructure rather than by this process.
#
# Reached DIRECTLY by an agent -- `mcpAudience` on the Agent, bypassing the gateway -- the token
# does arrive and this check is the whole gate. Then it must be on.
REQUIRE_TOKEN = os.environ.get("MCP_REQUIRE_TOKEN", "true").strip().lower() in ("1", "true", "t", "yes")
OIDC_ISSUER = os.environ.get("CLUSTER_OIDC_ISSUER", "")
# Who may call this server directly, by namespace. Empty admits any namespace.
ALLOWED_CALLER_NAMESPACES = allowed_namespaces_from_env("MCP_ALLOWED_CALLER_NAMESPACES")
CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "unknown")

# All interfaces inside the container, no host port published. The Service is ClusterIP and nothing
# routes to this from outside the cluster, so the Service is the exposure boundary rather than this
# bind -- narrowing it to loopback would make the pod unreachable from its own Service.
# ACTING FOR A PERSON (enable_person_access). Two tools below answer only for the person a request
# is for, and that person is whoever the identity provider signed the x-person-token for -- not
# whatever the agent or the model says. The caller check above still decides who may call at all.
# Unset: the two tools are not listed, because a tool that can only refuse wastes a model's turn.
PERSON_TOKEN_ISSUER = os.environ.get("PERSON_TOKEN_ISSUER", "").strip()
PERSON_TOKEN_CLIENT_IDS = frozenset(c.strip() for c in os.environ.get("PERSON_TOKEN_CLIENT_IDS", "").split(",") if c.strip())
# THE AGENTS THAT MAY ACT FOR A PERSON HERE, by their workload subject
# (system:serviceaccount:<namespace>:<agent>), from person_access_agents. A person's token proves
# who a call is for, not who is making it: without this, any workload that held a person's token
# could act as that person through these tools. Checked only where this server verifies its caller
# (MCP_REQUIRE_TOKEN true, the AWS services path); behind a gateway that forwards no caller token,
# the gateway is where this decision belongs. Empty, with the person tools on and the caller
# verified: no agent may act for a person, which fails closed.
PERSON_ACCESS_AGENTS = frozenset(a.strip() for a in os.environ.get("PERSON_ACCESS_AGENTS", "").split(",") if a.strip())
# ONE DELEGATED TOKEN INSTEAD OF TWO (person_access_delegated_token, the open source path). The
# gateway exchanges the person's access token and the calling agent's own token at the pool and
# sends this server the result in Authorization: sub is the person, aud is PERSON_DELEGATED_AUDIENCE,
# act.sub is the agent, act.iss is PERSON_ACTOR_ISSUER (the cluster's issuer). With these set the
# person tools accept ONLY that token, and check the agent against PERSON_ACCESS_AGENTS whether or
# not this server verifies its caller -- so behind the gateway the agent side is decided here too,
# from a claim the pool signed. A bare x-person-token is refused: it names no agent.
PERSON_DELEGATED_AUDIENCE = os.environ.get("PERSON_DELEGATED_AUDIENCE", "").strip()
PERSON_ACTOR_ISSUER = os.environ.get("PERSON_ACTOR_ISSUER", "").strip()
# THE ACTOR IS AN AGENT'S OWN COGNITO CLIENT on the AWS services path: each agent makes the exchange
# itself, with AgentCore Identity, and its client is the actor. client-id=subject pairs, from
# person_access_agents. Set, this server also reads the delegated token from x-delegated-token
# (Authorization carries the agent's own token for the caller check above), and requires the
# token's actor to be the agent that called: an agent can't present another agent's token.
PERSON_ACTOR_CLIENTS = dict(
    pair.strip().split("=", 1) for pair in os.environ.get("PERSON_ACTOR_CLIENTS", "").split(",") if "=" in pair)

HOST = os.environ.get("MCP_BIND_HOST", "0.0.0.0")  # noqa: S104 - see the comment above
PORT = int(os.environ.get("MCP_PORT", "8080"))

PROTOCOL_VERSION = "2025-06-18"

# FastAPI's own OpenTelemetry tracing, metrics and logs are off. They would make an HTTP server span
# with no session id the root of every trace, above the agent's invoke_agent span, and the evaluation
# runner, which reads a session's spans from Langfuse, then finds no agent invocation and grades
# nothing. The GenAI spans this image exports are the ones the platform reads.
app = FastAPI(title="eks-agents reference MCP server", docs_url=None, redoc_url=None,
              telemetry={"tracing": False, "metrics": False, "logs": False})

# A fixed dataset, so a tool call is deterministic and a failed assertion in an exercise run means
# the path broke rather than the data moved.
ORDERS: dict[str, dict[str, Any]] = {
    "ORD-12345": {"status": "in transit", "items": ["laptop"], "eta": "2026-11-09"},
    "ORD-11111": {"status": "delivered", "items": ["headphones"], "eta": "2026-11-02"},
}

TOOLS = [
    {
        "name": "get_time",
        "description": "The current UTC time, as an ISO 8601 string.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "describe_cluster",
        "description": "The name of the EKS cluster this MCP server runs on.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "lookup_order",
        "description": (
            "Look up an order by its id and return status, items and estimated delivery. "
            "Returns an error field when the order does not exist."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"order_id": {"type": "string", "description": "e.g. ORD-12345"}},
            "required": ["order_id"],
            "additionalProperties": False,
        },
    },
]


PERSON_TOOLS = [
    {
        "name": "my_account",
        "description": (
            "The signed-in person's own account: its id and balance. Answers only for the person this "
            "request is for, as their identity provider attests it."
        ),
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "get_account",
        "description": (
            "An account by id. Returns it only when it belongs to the person this request is for, "
            "and refuses anyone else's."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"account_id": {"type": "string", "description": "e.g. ACCT-1A2B3C4D5E"}},
            "required": ["account_id"],
            "additionalProperties": False,
        },
    },
]


def account_for(subject: str) -> str:
    """A person's account id, derived from their subject so the example needs no database."""
    return "ACCT-" + hashlib.sha256(subject.encode()).hexdigest()[:10].upper()


def _person_tool(name: str, args: dict[str, Any], token: str, caller: str = "", delegated: str = "") -> dict[str, Any]:
    """Answer for the verified person, or refuse. A refusal is a result, not an exception, so the
    model can tell the person why.

    Two identities decide, as in any delegation: the PERSON the call is for and the AGENT making it.
    With a delegated token (PERSON_DELEGATED_AUDIENCE set) both come from that one token. Otherwise
    the person is the x-person-token, verified here, and the agent is the caller this server
    verified, when it verifies one. Every call is logged with both, allowed or refused, so the
    record says which agent acted for whom.
    """
    if PERSON_DELEGATED_AUDIENCE:
        # The gateway removes x-person-token when it exchanges it, so its presence here means the
        # person's own token reached the tool. Logged, never used.
        if token and delegated:
            log.info("person tool %s: a person's own token arrived beside the delegated one (x-person-token); ignored", name)
        elif token:
            log.info("person tool %s: a person's own token arrived with no delegated token (x-person-token); refused", name)
        try:
            person, actor = verify_delegated_token(
                delegated, issuer=PERSON_TOKEN_ISSUER, audience=PERSON_DELEGATED_AUDIENCE, actor_issuer=PERSON_ACTOR_ISSUER,
                actor_clients=PERSON_ACTOR_CLIENTS or None)
        except AuthError as exc:
            log.info("person tool %s: agent %s, person none: refused (%s)", name, caller or "unverified", exc)
            return {"error": "refused: this tool acts only for a signed-in person through an agent, and no verifiable delegated token came with the request"}
        # The verified caller and the token's actor must be the same agent where both are known: a
        # token delegated to one agent doesn't let another agent act with it.
        if REQUIRE_TOKEN and caller and caller != actor:
            log.info("person tool %s: agent %s, person %s: refused (the token was delegated to %s)", name, caller, person.subject, actor)
            return {"error": "refused: the delegated token was issued to a different agent than the one calling"}
        caller = actor
        if caller not in PERSON_ACCESS_AGENTS:
            log.info("person tool %s: agent %s, person %s: refused (agent not allowed to act for a person)", name, caller, person.subject)
            return {"error": f"refused: agent {caller!r} is not allowed to act for a person with this tool"}
        log.info("person tool %s: one delegated token (aud %s), agent from act.sub, person from sub", name, PERSON_DELEGATED_AUDIENCE)
        return _answer_for(name, args, person, caller)
    try:
        person = verify_person_token(token, issuer=PERSON_TOKEN_ISSUER, client_ids=PERSON_TOKEN_CLIENT_IDS)
    except AuthError as exc:
        log.info("person tool %s: agent %s, person none: refused (%s)", name, caller or "unverified", exc)
        return {"error": "refused: this tool acts only for a signed-in person, and no verifiable person token came with the request"}
    if REQUIRE_TOKEN and caller not in PERSON_ACCESS_AGENTS:
        log.info("person tool %s: agent %s, person %s: refused (agent not allowed to act for a person)", name, caller, person.subject)
        return {"error": f"refused: agent {caller!r} is not allowed to act for a person with this tool"}
    return _answer_for(name, args, person, caller)


def _answer_for(name: str, args: dict[str, Any], person, caller: str) -> dict[str, Any]:
    """The tool's answer for a verified person, through a verified (or gateway-vouched) agent."""
    own = account_for(person.subject)
    if name == "my_account":
        log.info("person tool %s: agent %s, person %s: allowed", name, caller or "unverified", person.subject)
        return {"account_id": own, "balance": int(own[-4:], 16) / 100}
    wanted = str(args.get("account_id", "")).strip().upper()
    if wanted != own:
        log.info("person tool %s: agent %s, person %s: refused (account %s is not theirs)", name, caller or "unverified", person.subject, wanted)
        return {"error": f"refused: account {wanted!r} does not belong to the person this request is for"}
    log.info("person tool %s: agent %s, person %s: allowed", name, caller or "unverified", person.subject)
    return {"account_id": own, "balance": int(own[-4:], 16) / 100}


def _call_tool(name: str, args: dict[str, Any]) -> dict[str, Any]:
    if name == "get_time":
        return {"utc": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    if name == "describe_cluster":
        return {"cluster": CLUSTER_NAME}
    if name == "lookup_order":
        order_id = str(args.get("order_id", "")).strip()
        if order_id in ORDERS:
            return {"order_id": order_id, **ORDERS[order_id]}
        # A tool that returns an error rather than raising is what lets the model recover. An
        # exception here would surface to the agent as a transport failure instead.
        return {"error": f"no order {order_id!r}", "known": sorted(ORDERS)}
    raise KeyError(name)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Liveness and readiness. No authentication, no input, no tool data."""
    return {"status": "ok"}


def _verify(request: Request) -> str:
    if not REQUIRE_TOKEN:
        # Not "trust anybody": trust that the only thing that can reach this port is the gateway,
        # which is what the AuthorizationPolicy and the network policy next to this server enforce.
        # Logged on every call so a cluster where this is off cannot look like one where it is on.
        log.info("inbound token check is OFF (MCP_REQUIRE_TOKEN); the gateway is the boundary")
        return "gateway"
    try:
        caller = verify_cluster_token(
            bearer_token(dict(request.headers)),
            audience=INBOUND_AUDIENCE,
            issuer=OIDC_ISSUER,
            allowed_namespaces=ALLOWED_CALLER_NAMESPACES,
        )
    except AuthError as exc:
        log.info("refused an MCP request: %s", exc)
        raise HTTPException(status_code=401, detail="unauthenticated") from exc
    return caller.subject


@app.post("/mcp")
async def mcp(request: Request) -> Any:
    """MCP over streamable HTTP, as JSON-RPC 2.0.

    Three methods, which is what an aggregating gateway and an agent actually call: initialize,
    tools/list and tools/call. A notification (no id) gets 202 and no body, per the transport.
    """
    subject = _verify(request)

    try:
        req = await request.json()
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(status_code=400, detail="body must be JSON-RPC") from exc

    method = req.get("method", "")
    req_id = req.get("id")
    params = req.get("params") or {}

    def ok(result: Any) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": req_id, "result": result}

    def err(code: int, message: str) -> dict[str, Any]:
        return {"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}}

    if req_id is None:
        # A notification. Nothing here keeps per-session state, so there is nothing to do.
        return {}

    if method == "initialize":
        return ok({
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "eks-agents-reference-mcp", "version": "1.0.0"},
        })

    if method == "tools/list":
        log.info("tools/list for %s", subject)
        return ok({"tools": TOOLS + (PERSON_TOOLS if PERSON_TOKEN_ISSUER else [])})

    if method == "tools/call":
        name = params.get("name", "")
        args = params.get("arguments") or {}
        log.info("tools/call %s for %s", name, subject)
        try:
            if PERSON_TOKEN_ISSUER and name in {t["name"] for t in PERSON_TOOLS}:
                headers = dict(request.headers)
                # The open source gateway sends the delegated token in Authorization; an agent that
                # makes the exchange itself sends it beside its own token, in x-delegated-token.
                delegated = ""
                if PERSON_DELEGATED_AUDIENCE:
                    delegated = delegated_token(headers) if PERSON_ACTOR_CLIENTS else bearer_token(headers)
                payload = _person_tool(name, args, person_token(headers), caller=subject if REQUIRE_TOKEN else "",
                                       delegated=delegated)
            else:
                payload = _call_tool(name, args)
        except KeyError:
            return err(-32602, f"unknown tool: {name}")
        # MCP returns tool output as content blocks. JSON goes in a text block, which is what every
        # client renders and what a model reads.
        return ok({
            "content": [{"type": "text", "text": json.dumps(payload)}],
            "isError": "error" in payload,
        })

    return err(-32601, f"method not found: {method}")


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    if not OIDC_ISSUER:
        sys.exit(
            "Refusing to serve: CLUSTER_OIDC_ISSUER is required to verify a caller's token. The "
            "manifest in gitops/examples/mcp-server sets it from the rendered Terraform values."
        )
    log.info("serving MCP on %s:%s, inbound audience %r", HOST, PORT, INBOUND_AUDIENCE)
    uvicorn.run(app, host=HOST, port=PORT, log_level=os.environ.get("LOG_LEVEL", "info").lower())


if __name__ == "__main__":
    main()
