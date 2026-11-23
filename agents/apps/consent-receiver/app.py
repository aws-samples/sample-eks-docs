"""OAuth consent receiver: one person approves once, the egress gateway holds the token.

The open source egress gateway (AgentGateway) attaches a third-party credential from a Kubernetes
Secret, and does not run an OAuth consent flow itself -- the authorization-URL-on-first-call flow,
with a token per end user, is an enterprise gateway feature. This fills the gap for services that
only issue tokens through a person's consent (GitHub, Slack, Google, Atlassian):

    GET /connect/<client>          redirect the operator's browser to the provider's consent page
    GET /callback/<client>         exchange the code, write the token to the destination's
                                   Secrets Manager secret, and restart the secrets syncer so the
                                   gateway's Kubernetes Secret picks it up
    GET /complete/<client>         AgentCore Gateway only (mode "agentcore"): the return URL its
                                   3LO flow redirects to after consent; completes the session
                                   binding for the agent the client names (see below)
    GET /healthz

AGENTCORE MODE (AWS services path). AgentCore Gateway runs the consent itself and keeps the token in
AgentCore Identity's vault, but it binds each consent to the identity that started it: after the
person approves, AgentCore redirects to a return URL that must call CompleteResourceTokenAuth with
the session and the EXACT token that started the flow -- a different token for the same subject is
refused with "Invalid or expired session". No browser holds the agent's token,
so this starts the flow itself:

    GET /connect/<client>    mint a token for the agent the client names (TokenRequest, the
                             gateway's audience, 10 minutes), call the client's tool on the gateway
                             with it, keep that token in memory, and redirect the browser to the
                             authorization URL the gateway returned (MCP URL elicitation)
    GET /complete/<client>   AgentCore's return: complete the binding with the kept token

The vault then holds the GitHub token for the agent's identity, and the agent's own calls use it.

GITHUB: USE A GITHUB APP, NOT AN OAUTH APP. A GitHub App's user token reaches only the repositories
the app is installed on, intersected with the approving user's own access, and expires after 8 hours.
That expiry is why this also refreshes: the refresh token (single-use, 6 months) is kept in a secret
only this receiver reads, and a new access/refresh pair is written well before the access token
expires. A provider that issues no refresh token gets no refresh loop. PKCE (S256) is always sent.

What this is NOT: per-user. The token belongs to whoever approved, and the gateway attaches it for
the one agent the destination names (third_party_credentials.<key>.caller). A service where each end
user's own authority must reach the API needs a gateway with a token store keyed on the user.

REACHED ONLY THROUGH `kubectl port-forward`. It binds 127.0.0.1 in its pod, has no Service, and a
deny-all NetworkPolicy sits in front of it, so the gate is the cluster's own authentication and
`pods/portforward` RBAC. The browser's redirect target is the operator's own forwarded localhost
port, which is what the provider's registered callback URL names.

Configuration, from the consent-receiver chart (rendered by Terraform's oauth_consent):
    CONSENT_CLIENTS        JSON: {client: {authorizeUrl, tokenUrl, clientId, clientSecretArn,
                           scopes, secretId, refreshSecretId}}
    PUBLIC_BASE_URL        what the provider redirects to, e.g. http://localhost:8765
    SYNCER_NAMESPACE       where the platform-secrets syncer runs (the gateway's namespace)
    SYNCER_DEPLOYMENT      its name, platform-secrets-syncer
    AWS_REGION
"""
import base64
import datetime
import hashlib
import html
import http.server
import json
import logging
import os
import secrets
import ssl
import threading
import time
import urllib.parse
import urllib.request

import boto3

log = logging.getLogger("consent")
CLIENTS = json.loads(os.environ.get("CONSENT_CLIENTS", "{}"))
BASE = os.environ.get("PUBLIC_BASE_URL", "http://localhost:8765").rstrip("/")
SYNC_NS = os.environ.get("SYNCER_NAMESPACE", "agentgateway-system")
SYNC_DEPLOY = os.environ.get("SYNCER_DEPLOYMENT", "platform-secrets-syncer")
REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION")
BIND = os.environ.get("BIND_ADDRESS", "127.0.0.1")   # loopback: reached by port-forward only
PORT = int(os.environ.get("PORT", "8765"))
STATE_TTL = 600
REFRESH_MARGIN = 3600   # refresh this long before the access token expires

_states: dict[str, tuple[str, float, str]] = {}
_pending: dict[str, tuple[str, float]] = {}   # agentcore mode: client -> (the token that started it, when)
_lock = threading.Lock()
_sm = boto3.client("secretsmanager", region_name=REGION)


def _new_state(client: str) -> tuple[str, str]:
    """A state and the PKCE challenge for it; the verifier stays here."""
    s = secrets.token_urlsafe(32)
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    with _lock:
        now = time.time()
        for k in [k for k, (_, t, _) in _states.items() if now - t > STATE_TTL]:
            del _states[k]
        _states[s] = (client, now, verifier)
    return s, challenge


def _take_state(s: str, client: str) -> str:
    """One use only, bound to the client it was issued for, and short-lived. Returns the verifier."""
    with _lock:
        got = _states.pop(s, None)
    if got and got[0] == client and time.time() - got[1] <= STATE_TTL:
        return got[2]
    return ""


def _https(url: str) -> str:
    """A configured endpoint, refused unless it is https: these carry a client secret or a token,
    and urlopen would also open file: and custom schemes."""
    if urllib.parse.urlsplit(url).scheme != "https":
        raise RuntimeError(f"refusing a non-https endpoint: {url[:80]!r}")
    return url


def _token_request(cfg: dict, params: dict) -> dict:
    client_secret = _sm.get_secret_value(SecretId=cfg["clientSecretArn"])["SecretString"].strip()
    body = urllib.parse.urlencode({"client_id": cfg["clientId"], "client_secret": client_secret,
                                   **params}).encode()
    req = urllib.request.Request(_https(cfg["tokenUrl"]), data=body, method="POST",
                                 headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        doc = json.load(r)
    if "access_token" not in doc:
        # The provider's error code, never the body: an error document can echo the code back.
        raise RuntimeError(f"token request refused: {doc.get('error', 'no access_token')}")
    return doc


def _store(client: str, cfg: dict, doc: dict) -> None:
    """The access token where the gateway reads it; the refresh token where only this reads it."""
    _sm.put_secret_value(SecretId=cfg["secretId"], SecretString=json.dumps({"token": doc["access_token"]}))
    if doc.get("refresh_token") and cfg.get("refreshSecretId"):
        expires_at = time.time() + int(doc.get("expires_in", 28800))
        _sm.put_secret_value(SecretId=cfg["refreshSecretId"], SecretString=json.dumps({
            "refresh_token": doc["refresh_token"], "access_expires_at": expires_at}))
    _restart_syncer()


def _refresh_loop() -> None:
    """Swap in a new access/refresh pair before the access token expires. A refresh token is single-use,
    so a failed write after a successful refresh would strand the credential: write before anything else."""
    while True:
        for client, cfg in CLIENTS.items():
            if not cfg.get("refreshSecretId"):
                continue
            try:
                doc = json.loads(_sm.get_secret_value(SecretId=cfg["refreshSecretId"])["SecretString"])
            except Exception:  # noqa: BLE001 -- no consent yet, or no value: nothing to refresh
                continue
            if not doc.get("refresh_token") or time.time() < doc.get("access_expires_at", 0) - REFRESH_MARGIN:
                continue
            try:
                new = _token_request(cfg, {"grant_type": "refresh_token", "refresh_token": doc["refresh_token"]})
                _store(client, cfg, new)
                log.info("refreshed %s", client)
            except Exception as exc:  # noqa: BLE001
                log.error("refresh for %s failed: %s; consent again at /connect/%s", client, type(exc).__name__, client)
        time.sleep(300)


def _restart_syncer() -> None:
    """New pod, new CSI mount: the driver writes the Kubernetes Secret at mount time."""
    sa = "/var/run/secrets/kubernetes.io/serviceaccount"
    token = open(f"{sa}/token").read().strip()
    ctx = ssl.create_default_context(cafile=f"{sa}/ca.crt")
    stamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    patch = json.dumps({"spec": {"template": {"metadata": {"annotations": {
        "eks-agents/consent-written-at": stamp}}}}}).encode()
    url = (f"https://kubernetes.default.svc/apis/apps/v1/namespaces/{SYNC_NS}"
           f"/deployments/{SYNC_DEPLOY}")
    req = urllib.request.Request(url, data=patch, method="PATCH", headers={
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/strategic-merge-patch+json"})
    urllib.request.urlopen(req, timeout=15, context=ctx).close()


def _elicit(cfg: dict, token: str) -> str:
    """Call the client's tool on the gateway as the agent; return the URL its 3LO consent elicits, or
    '' when the call succeeds (already consented). MCP 2025-11-25 with the URL elicitation capability,
    and the MCP-Protocol-Version header on every request: without it the gateway treats the call as
    2025-03-26 and refuses to start the flow."""
    h = {"Authorization": f"Bearer {token}", "Content-Type": "application/json",
         "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-11-25"}

    def rpc(i: int, method: str, params: dict) -> dict:
        req = urllib.request.Request(_https(cfg["mcpUrl"]), method="POST", headers=h, data=json.dumps(
            {"jsonrpc": "2.0", "id": i, "method": method, "params": params}).encode())
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read().decode()
        if "data:" in body:
            body = [ln[5:].strip() for ln in body.splitlines() if ln.startswith("data:")][-1]
        return json.loads(body)

    rpc(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {"elicitation": {"url": {}}},
                          "clientInfo": {"name": "consent-receiver", "version": "1"}})
    out = rpc(2, "tools/call", {"name": cfg["tool"], "arguments": cfg.get("toolArguments", {})})
    elicits = ((out.get("error") or {}).get("data") or {}).get("elicitations") or []
    for e in elicits:
        if e.get("mode") == "url" and e.get("url"):
            return e["url"]
    if "result" in out and not out["result"].get("isError"):
        return ""
    raise RuntimeError(f"the tool call returned neither a result nor a URL elicitation: {json.dumps(out)[:200]}")


def _mint_agent_token(namespace: str, agent: str, audience: str) -> str:
    """The agent's own identity, as the gateway sees it: a projected-style token for its service
    account, minted through TokenRequest. RBAC limits this receiver to the named agents' accounts."""
    sa = "/var/run/secrets/kubernetes.io/serviceaccount"
    own = open(f"{sa}/token").read().strip()
    ctx = ssl.create_default_context(cafile=f"{sa}/ca.crt")
    body = json.dumps({"apiVersion": "authentication.k8s.io/v1", "kind": "TokenRequest",
                       "spec": {"audiences": [audience], "expirationSeconds": 600}}).encode()
    req = urllib.request.Request(
        f"https://kubernetes.default.svc/api/v1/namespaces/{namespace}/serviceaccounts/{agent}/token",
        data=body, method="POST",
        headers={"Authorization": f"Bearer {own}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15, context=ctx) as r:
        return json.load(r)["status"]["token"]


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code: int, text: str, location: str = "") -> None:
        body = f"<!doctype html><title>Consent</title><p>{html.escape(text)}</p>".encode()
        self.send_response(code)
        if location:
            self.send_header("Location", location)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        u = urllib.parse.urlsplit(self.path)
        parts = [p for p in u.path.split("/") if p]
        if u.path == "/healthz":
            return self._send(200, "ok")
        if len(parts) != 2 or parts[0] not in ("connect", "callback", "complete") or parts[1] not in CLIENTS:
            return self._send(404, "not found")
        client, cfg = parts[1], CLIENTS[parts[1]]
        agentcore = cfg.get("mode") == "agentcore"
        if agentcore and parts[0] == "connect":
            return self._start(client, cfg)
        if parts[0] == "complete" or agentcore:
            if not (parts[0] == "complete" and agentcore):
                return self._send(404, "not found")
            return self._complete(client, cfg, dict(urllib.parse.parse_qsl(u.query)))
        if parts[0] == "connect":
            state, challenge = _new_state(client)
            q = urllib.parse.urlencode({
                "client_id": cfg["clientId"], "redirect_uri": f"{BASE}/callback/{client}",
                "scope": cfg.get("scopes", ""), "state": state, "response_type": "code",
                "code_challenge": challenge, "code_challenge_method": "S256"})
            return self._send(302, "Redirecting to the provider.", f"{cfg['authorizeUrl']}?{q}")
        q = dict(urllib.parse.parse_qsl(u.query))
        verifier = _take_state(q.get("state", ""), client)
        if not verifier:
            log.warning("refused a callback for %s: unknown, reused or expired state", client)
            return self._send(400, "This consent link is expired or was already used. Start again.")
        if "code" not in q:
            return self._send(400, f"The provider returned no code ({q.get('error', 'unknown')}).")
        try:
            doc = _token_request(cfg, {"grant_type": "authorization_code", "code": q["code"],
                                       "redirect_uri": f"{BASE}/callback/{client}",
                                       "code_verifier": verifier})
            _store(client, cfg, doc)
        except Exception as exc:  # noqa: BLE001
            log.error("consent for %s failed: %s", client, type(exc).__name__)
            return self._send(502, "Could not store the credential. See the receiver's log.")
        log.info("consent for %s stored in %s; syncer restarted", client, cfg["secretId"])
        return self._send(200, f"Connected {client}. The gateway will use it within a minute; close this tab.")

    def _start(self, client: str, cfg: dict) -> None:
        try:
            token = _mint_agent_token(cfg["agentNamespace"], cfg["agent"], cfg["audience"])
            url = _elicit(cfg, token)
        except Exception as exc:  # noqa: BLE001
            log.error("starting consent for %s failed: %s: %s", client, type(exc).__name__, str(exc)[:300])
            return self._send(502, "Could not start the authorization. See the receiver's log.")
        if not url:
            return self._send(200, f"{client} is already connected for agent {cfg['agent']}: the tool call succeeded.")
        with _lock:
            _pending[client] = (token, time.time())
        log.info("consent for %s started for agent %s", client, cfg["agent"])
        return self._send(302, "Redirecting to the authorization page.", url)

    def _complete(self, client: str, cfg: dict, q: dict) -> None:
        # The parameter NAMES, never their values, so a mismatch with what AgentCore sends is visible.
        log.info("return for %s with parameters %s", client, sorted(q))
        session = q.get("session_id", "")
        if not session:
            return self._send(400, "No session_id: start from the authorization URL the agent's tool call returned.")
        try:
            # The exact token /connect started the flow with: AgentCore refuses any other.
            with _lock:
                kept = _pending.pop(client, None)
            if not kept or time.time() - kept[1] > STATE_TTL:
                return self._send(400, f"No consent in progress for {client}: start at /connect/{client}.")
            ident = {"userToken": kept[0]}
            boto3.client("bedrock-agentcore", region_name=REGION).complete_resource_token_auth(
                userIdentifier=ident, sessionUri=session)
        except Exception as exc:  # noqa: BLE001
            # The service's message (e.g. "Invalid or expired session"), which carries no secret, and is
            # the difference between a wrong session and a refused grant -- both are AccessDenied.
            log.error("session binding for %s failed: %s: %s", client, type(exc).__name__, str(exc)[:300])
            return self._send(502, "Could not complete the authorization. See the receiver's log.")
        log.info("session binding for %s completed for agent %s", client, cfg["agent"])
        return self._send(200, f"Connected {client} for agent {cfg['agent']}. The agent's next call uses it; close this tab.")

    def log_message(self, fmt, *args):  # the query string carries the code: never log a request line
        pass


if __name__ == "__main__":
    logging.basicConfig(level="INFO", format="%(asctime)s %(levelname)s %(message)s")
    if not CLIENTS:
        raise SystemExit("CONSENT_CLIENTS is empty: nothing to connect")
    log.info("consent receiver on %s:%d for %s; redirect base %s", BIND, PORT, ", ".join(CLIENTS), BASE)
    if any(c.get("mode") != "agentcore" for c in CLIENTS.values()):
        threading.Thread(target=_refresh_loop, daemon=True).start()
    http.server.ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
