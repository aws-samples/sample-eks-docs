"""Acting with a person's own authority: the person is whoever the identity provider signed for.

    python apps/tests/test_person_access.py

What would make this feature decorative rather than real, one check each:

  1. A tool that answers for "the person" must verify the person's token, not read it: an unsigned
     token, one signed by another key, one for another client of the pool, an expired one and a
     refresh-style token are each refused. A valid access token and a valid ID token are accepted,
     so the refusals cannot pass on a check that refuses everything.
  2. The per-person tools answer for the verified person only: my_account returns that person's
     account, get_account refuses another person's, and no token refuses both.
  3. The chat UI forwards a person's access token only when its subject is the signed-in person's,
     so one person's claims never travel with another's token.
  4. The agent registers its AWS tools for an ID token only: STS refuses an access token, so
     offering the tools for one would put a tool in front of the model that can only fail.
  5. The header the token travels in is shape-checked: anything that is not a JWT is dropped.
  6. With one delegated token (person_access_delegated_token), the tool reads the person from sub
     and the agent from act, both signed by the pool, and refuses a token that names no agent,
     names another cluster's, is for another audience, or names an agent without person access --
     even behind the gateway, where the tool cannot see its caller. The agent sends that endpoint
     an access token only.
  7. Through the gateway (person_access_via_gateway), the agent's S3 calls carry its own token and
     the person's, and no signature of its own.

The issuer is the loopback fixture from test_gates.py, so nothing here reaches the network.
"""

from __future__ import annotations

import importlib.util
import os
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import jwt
from cryptography.hazmat.primitives import serialization

AGENTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS_DIR / "common"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from test_gates import _Issuer, _make_key  # noqa: E402

import cluster_auth  # noqa: E402
from cluster_auth import AuthError, person_token, verify_delegated_token, verify_person_token  # noqa: E402

API_CLIENT = "apiclient123"
BROWSER_CLIENT = "browserclient456"
CLIENTS = frozenset({API_CLIENT, BROWSER_CLIENT})
ALICE = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
BOB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

RESULTS: list[tuple[str, bool]] = []


def check(name: str, ok: bool) -> None:
    RESULTS.append((name, ok))
    print(("  PASS " if ok else "  FAIL ") + name)


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def mint(issuer: _Issuer, *, sub: str = ALICE, use: str = "access", client: str = BROWSER_CLIENT,
         exp_delta: int = 600, key=None, iss: str | None = None) -> str:
    now = int(time.time())
    claims = {"iss": iss or issuer.url, "sub": sub, "token_use": use, "iat": now, "exp": now + exp_delta}
    claims["client_id" if use == "access" else "aud"] = client
    return jwt.encode(
        claims,
        (key or issuer.key).private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        ),
        algorithm="RS256",
        headers={"kid": issuer.kid},
    )


def refused(token: str, issuer_url: str) -> bool:
    try:
        verify_person_token(token, issuer=issuer_url, client_ids=CLIENTS)
    except AuthError:
        return True
    return False


def main() -> int:
    issuer = _Issuer(_make_key())
    try:
        print("1. the person's token is verified, not read")
        unsigned = jwt.encode({"iss": issuer.url, "sub": ALICE, "token_use": "access", "client_id": BROWSER_CLIENT,
                               "iat": int(time.time()), "exp": int(time.time()) + 600}, key=None, algorithm="none")
        check("an unsigned token is refused", refused(unsigned, issuer.url))
        check("a token signed by another key is refused", refused(mint(issuer, key=_make_key()), issuer.url))
        check("a token for another client of the pool is refused", refused(mint(issuer, client="someoneelse"), issuer.url))
        check("an expired token is refused", refused(mint(issuer, exp_delta=-3600), issuer.url))
        check("a token from another issuer is refused", refused(mint(issuer, iss="https://elsewhere.example"), issuer.url))
        check("a token that is neither access nor id is refused", refused(mint(issuer, use="refresh"), issuer.url))
        check("no token is refused", refused("", issuer.url))
        a = verify_person_token(mint(issuer), issuer=issuer.url, client_ids=CLIENTS)
        check("a valid access token is accepted, as the person", a.kind == "person" and a.subject == ALICE)
        i = verify_person_token(mint(issuer, use="id", client=API_CLIENT), issuer=issuer.url, client_ids=CLIENTS)
        check("a valid ID token is accepted, as the person", i.subject == ALICE)

        print("2. the per-person tools answer for the verified person only")
        os.environ["CLUSTER_OIDC_ISSUER"] = issuer.url
        os.environ["PERSON_TOKEN_ISSUER"] = issuer.url
        os.environ["PERSON_TOKEN_CLIENT_IDS"] = ",".join(sorted(CLIENTS))
        AGENT = "system:serviceaccount:agents:research"
        os.environ["PERSON_ACCESS_AGENTS"] = AGENT
        mcp = load("mcp_person", AGENTS_DIR / "mcp-server" / "app.py")
        tok_a, tok_b = mint(issuer, sub=ALICE), mint(issuer, sub=BOB)
        own = mcp._person_tool("my_account", {}, tok_a, caller=AGENT)
        check("my_account returns the verified person's account", own.get("account_id") == mcp.account_for(ALICE))
        theirs = mcp._person_tool("get_account", {"account_id": mcp.account_for(ALICE)}, tok_b, caller=AGENT)
        check("get_account refuses another person's account", str(theirs.get("error", "")).startswith("refused"))
        mine = mcp._person_tool("get_account", {"account_id": mcp.account_for(BOB)}, tok_b, caller=AGENT)
        check("get_account returns the person's own account", mine.get("account_id") == mcp.account_for(BOB))
        anon = mcp._person_tool("my_account", {}, "", caller=AGENT)
        check("no person token refuses my_account", str(anon.get("error", "")).startswith("refused"))
        forged = mcp._person_tool("my_account", {}, mint(issuer, sub=ALICE, key=_make_key()), caller=AGENT)
        check("a forged person token refuses my_account", str(forged.get("error", "")).startswith("refused"))
        other = mcp._person_tool("my_account", {}, tok_a, caller="system:serviceaccount:agents:lister")
        check("an agent not in PERSON_ACCESS_AGENTS is refused, with the person's valid token",
              "not allowed to act for a person" in str(other.get("error", "")))
        mcp.PERSON_ACCESS_AGENTS = frozenset()
        none = mcp._person_tool("my_account", {}, tok_a, caller=AGENT)
        check("with no agent allowed, a verified caller is refused (fails closed)",
              "not allowed to act for a person" in str(none.get("error", "")))
        mcp.PERSON_ACCESS_AGENTS = frozenset({AGENT})
        mcp.REQUIRE_TOKEN = False
        gw = mcp._person_tool("my_account", {}, tok_a, caller="")
        check("behind a gateway (no caller token), the gateway decides and the person's token still scopes",
              gw.get("account_id") == mcp.account_for(ALICE))
        mcp.REQUIRE_TOKEN = True
        listed = {t["name"] for t in mcp.TOOLS + (mcp.PERSON_TOOLS if mcp.PERSON_TOKEN_ISSUER else [])}
        check("the per-person tools are listed when an issuer is configured", {"my_account", "get_account"} <= listed)

        print("3. the chat UI forwards a token only for the signed-in person")
        os.environ["CHAT_UI_FORWARD_PERSON_TOKEN"] = "true"
        ui = load("chat_ui_person", AGENTS_DIR / "chat-ui" / "app.py")
        req = SimpleNamespace(headers={"x-amzn-oidc-accesstoken": tok_a})
        check("forwarded when the token's subject is the signed-in person's",
              ui.forwarded_person_token(req, SimpleNamespace(claims={"sub": ALICE})) == tok_a)
        check("dropped when it is someone else's",
              ui.forwarded_person_token(req, SimpleNamespace(claims={"sub": BOB})) == "")
        ui.FORWARD_PERSON_TOKEN = False
        check("dropped when forwarding is off",
              ui.forwarded_person_token(req, SimpleNamespace(claims={"sub": ALICE})) == "")

        print("4. the agent's AWS tools are offered for an ID token only")
        os.environ["AGENT_PERSON_ROLE_ARN"] = "arn:aws:iam::111122223333:role/eks-agents/x-research-person-data"
        os.environ["AGENT_PERSON_BUCKET"] = "x-person-data-111122223333"
        os.environ["AGENT_NAME"] = "research"
        pa = load("person_access_t", AGENTS_DIR / "common" / "person_access.py")
        idt = mint(issuer, use="id", client=API_CLIENT)
        name = pa.session_name("research", idt, now=1794800000)
        check("the session name starts with the agent's name, which the role's trust requires",
              name.startswith("research-") and name.endswith("-1794800000"))
        check("the session name carries the person's sub prefix and fits STS's limits",
              len(name) <= 64 and pa._claims(idt).get("sub", "")[:8] in name)
        check("token_use is read from an access token", pa.token_use(tok_a) == "access")
        check("no AWS tools for an access token (STS refuses one)", pa.person_tools(tok_a) == [])
        names = {getattr(t, "tool_name", "") for t in pa.person_tools(mint(issuer, use="id", client=API_CLIENT))}
        check("save_my_note and read_my_note for an ID token", {"save_my_note", "read_my_note"} <= names)
        pa.ROLE_ARN = ""
        check("no AWS tools without the person role (an agent not in person_access_agents)",
              pa.person_tools(mint(issuer, use="id", client=API_CLIENT)) == [])

        print("5. the header is shape-checked")
        check("a JWT is read from x-person-token", person_token({"X-Person-Token": tok_a}) == tok_a)
        check("a non-JWT value is dropped", person_token({"x-person-token": "not a token"}) == "")
        check("an oversized value is dropped", person_token({"x-person-token": "a." + "b" * 9000 + ".c"}) == "")
        check("the Authorization header is never read as the person's", person_token({"Authorization": "Bearer " + tok_a}) == "")

        print("6. one delegated token names the person and the agent")
        CLUSTER = "https://oidc.eks.us-west-2.amazonaws.com/id/EXAMPLE"
        def delegated(*, sub=ALICE, agent=AGENT, aud="mcp-server", act_iss=CLUSTER, act=True, key=None):
            now = int(time.time())
            claims = {"iss": issuer.url, "sub": sub, "aud": aud, "token_use": "access", "client_id": "exchanger",
                      "iat": now, "exp": now + 600}
            if act:
                claims["act"] = {"sub": agent, "iss": act_iss, "token_type": "urn:ietf:params:oauth:token-type:id_token"}
            return jwt.encode(claims, (key or issuer.key).private_bytes(
                encoding=serialization.Encoding.PEM, format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption()), algorithm="RS256", headers={"kid": issuer.kid})
        person, actor = verify_delegated_token(delegated(), issuer=issuer.url, audience="mcp-server", actor_issuer=CLUSTER)
        check("a delegated token gives the person from sub and the agent from act",
              person.subject == ALICE and actor == AGENT)
        def dref(tok):
            try:
                verify_delegated_token(tok, issuer=issuer.url, audience="mcp-server", actor_issuer=CLUSTER)
            except AuthError:
                return True
            return False
        check("the person's own access token (no act) is refused as a delegated one", dref(mint(issuer)))
        check("a delegated token for another audience is refused", dref(delegated(aud="other-tools")))
        check("an actor from another cluster's issuer is refused", dref(delegated(act_iss="https://oidc.eks.us-east-1.amazonaws.com/id/OTHER")))
        check("a delegated token signed by another key is refused", dref(delegated(key=_make_key())))
        check("a token whose actor is its own subject is refused", dref(delegated(sub=AGENT)))
        mcp.PERSON_DELEGATED_AUDIENCE, mcp.PERSON_ACTOR_ISSUER = "mcp-server", CLUSTER
        mcp.REQUIRE_TOKEN = False  # behind the gateway: the tool cannot see its caller
        ok = mcp._person_tool("my_account", {}, "", delegated=delegated())
        check("behind the gateway, my_account answers for the delegated person",
              ok.get("account_id") == mcp.account_for(ALICE))
        unlisted = mcp._person_tool("my_account", {}, "", delegated=delegated(agent="system:serviceaccount:agents:orchestrator"))
        check("behind the gateway, an agent without person access is refused from the token's act claim",
              "not allowed to act for a person" in str(unlisted.get("error", "")))
        bare = mcp._person_tool("my_account", {}, tok_a, delegated="")
        check("with delegated tokens on, a bare x-person-token is refused (it names no agent)",
              str(bare.get("error", "")).startswith("refused"))
        theirs = mcp._person_tool("get_account", {"account_id": mcp.account_for(ALICE)}, "", delegated=delegated(sub=BOB))
        check("a delegated token for one person is refused another person's account",
              str(theirs.get("error", "")).startswith("refused"))
        mcp.PERSON_DELEGATED_AUDIENCE = mcp.PERSON_ACTOR_ISSUER = ""
        mcp.REQUIRE_TOKEN = True

        print("6b. AWS services: the actor is the agent's own Cognito client, from AgentCore Identity")
        clients = {"researchclient": AGENT}
        def obo(*, client="researchclient", aud="mcp-server", act_iss=None, sub=ALICE):
            # The shape AgentCore's on-behalf-of exchange returns from the pool: act names the agent's
            # client, issued by the pool itself.
            now = int(time.time())
            claims = {"iss": issuer.url, "sub": sub, "aud": aud, "token_use": "access", "client_id": client,
                      "iat": now, "exp": now + 600,
                      "act": {"sub": client, "client_id": client, "iss": act_iss or issuer.url,
                              "token_type": "urn:ietf:params:oauth:token-type:access_token"}}
            return jwt.encode(claims, issuer.key.private_bytes(
                encoding=serialization.Encoding.PEM, format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption()), algorithm="RS256", headers={"kid": issuer.kid})
        person, actor = verify_delegated_token(obo(), issuer=issuer.url, audience="mcp-server", actor_issuer=issuer.url, actor_clients=clients)
        check("the actor's client id maps to the agent", person.subject == ALICE and actor == AGENT)
        def oref(tok):
            try:
                verify_delegated_token(tok, issuer=issuer.url, audience="mcp-server", actor_issuer=issuer.url, actor_clients=clients)
            except AuthError:
                return True
            return False
        check("a token whose actor is no agent's client is refused", oref(obo(client="someoneelse")))
        check("a token with no audience for the tools is refused", oref(obo(aud="other-tools")))
        check("the person's own access token is refused (no act)", oref(mint(issuer)))
        mcp.PERSON_DELEGATED_AUDIENCE, mcp.PERSON_ACTOR_ISSUER, mcp.PERSON_ACTOR_CLIENTS = "mcp-server", issuer.url, clients
        mcp.REQUIRE_TOKEN = True  # called directly: the tool verifies its caller
        ok = mcp._person_tool("my_account", {}, "", caller=AGENT, delegated=obo())
        check("called directly, my_account answers for the delegated person", ok.get("account_id") == mcp.account_for(ALICE))
        other = mcp._person_tool("my_account", {}, "", caller="system:serviceaccount:agents:orchestrator", delegated=obo())
        check("a token delegated to one agent is refused when another agent presents it",
              "different agent" in str(other.get("error", "")))
        raw = mcp._person_tool("my_account", {}, tok_a, caller=AGENT, delegated="")
        check("the person's raw token alone is refused", str(raw.get("error", "")).startswith("refused"))
        mcp.PERSON_DELEGATED_AUDIENCE = mcp.PERSON_ACTOR_ISSUER = ""
        mcp.PERSON_ACTOR_CLIENTS = {}
        os.environ["AGENT_MCP_PERSON_TOKEN"] = "access"
        sys.modules["person_access"] = pa
        src = (AGENTS_DIR / "reference" / "app.py").read_text()
        start = src.index("def _mcp_person_token")
        ns = {"os": os, "token_use": pa.token_use}
        exec(src[start:src.index("\ndef ", start + 1)], ns)  # noqa: S102 - the function alone, without the agent's imports
        check("the agent sends the MCP endpoint an access token", ns["_mcp_person_token"](tok_a) == tok_a)
        check("the agent does not send it an ID token, which the exchange would refuse",
              ns["_mcp_person_token"](mint(issuer, use="id", client=API_CLIENT)) == "")
        os.environ["AGENT_MCP_PERSON_TOKEN"] = "any"
        check("without delegated tokens the agent sends either", ns["_mcp_person_token"](mint(issuer, use="id", client=API_CLIENT)) != "")

        print("7. through the gateway, the agent sends both tokens and signs nothing")
        tf = Path(os.environ.get("TMPDIR", "/tmp")) / "pa-test-gateway-token"
        tf.write_text("agent-workload-token")
        os.environ["AGENT_PERSON_S3_URL"] = "http://egress.example:8080/aws/research/s3"
        os.environ["AGENT_IDENTITY_TOKEN_FILE"] = str(tf)
        os.environ["AGENT_PERSON_ROLE_ARN"] = ""
        pg = load("person_access_gw", AGENTS_DIR / "common" / "person_access.py")
        idt = mint(issuer, use="id", client=API_CLIENT)
        names = {getattr(t, "tool_name", "") for t in pg.person_tools(idt)}
        check("the AWS tools are offered through the gateway with no person role in the pod",
              {"save_my_note", "read_my_note"} <= names)
        client, sub = pg.gateway_s3(idt)
        check("the person's prefix comes from the token's sub", sub == ALICE)
        seen = {}
        client.meta.events.register("before-send.s3", lambda request, **_: seen.update(dict(request.headers)) or __import__("botocore.awsrequest", fromlist=["AWSResponse"]).AWSResponse(request.url, 200, {}, None))
        try:
            client.head_bucket(Bucket="b")
        except Exception:  # noqa: BLE001 - the stub response is not a real S3 answer
            pass
        hdr = {k.lower(): (v.decode() if isinstance(v, bytes) else v) for k, v in seen.items()}
        check("each request carries the agent's own token in Authorization", hdr.get("authorization") == "Bearer agent-workload-token")
        check("each request carries the person's ID token in x-person-token", hdr.get("x-person-token") == idt)
        check("the request is not SigV4-signed by the agent", "x-amz-security-token" not in hdr and "AWS4" not in str(hdr.get("authorization")))
        os.environ["AGENT_PERSON_AWS_URL"] = "http://egress.example:8080/aws/research"
        pg2 = load("person_access_gw2", AGENTS_DIR / "common" / "person_access.py")
        ddb = pg2.gateway_client("dynamodb", idt)
        check("a client for another service points at that service's route",
              ddb.meta.endpoint_url == "http://egress.example:8080/aws/research/dynamodb")
        seen2 = {}
        ddb.meta.events.register("before-send.dynamodb", lambda request, **_: seen2.update(dict(request.headers)) or __import__("botocore.awsrequest", fromlist=["AWSResponse"]).AWSResponse(request.url, 200, {}, None))
        try:
            ddb.get_item(TableName="t", Key={"person": {"S": ALICE}})
        except Exception:  # noqa: BLE001
            pass
        h2 = {k.lower(): (v.decode() if isinstance(v, bytes) else v) for k, v in seen2.items()}
        check("that client carries both tokens and the body hash, unsigned",
              h2.get("x-person-token") == idt and h2.get("authorization") == "Bearer agent-workload-token"
              and len(h2.get("x-amz-content-sha256", "")) == 64)
        tf.unlink()
    finally:
        issuer.stop()

    failed = [n for n, ok in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
