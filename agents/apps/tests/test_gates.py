"""The credential checks fail closed, and verify rather than detect.

    python -m pytest apps/tests/test_gates.py        # or: python apps/tests/test_gates.py

These are the tests worth having on this repository, because the failure they cover is silent. A
gate that admits any request carrying a header looks identical to a working one from the outside:
the pod is Ready, the route is Accepted, requests return 200. The only way to know the difference is
to present a credential that should be refused and check that it is.

Six properties, each one a way the gate could be wrong:

  1. No credential is refused.
  2. A syntactically valid but unsigned credential is refused -- this is the "detects rather than
     verifies" failure, and the one most likely to be written by accident.
  3. A token signed by the wrong key is refused.
  4. A token for the wrong audience is refused, so a token minted for the egress gateway cannot be
     replayed against an agent.
  5. An expired token is refused.
  6. A correctly signed token for the right audience IS accepted -- without this the others pass
     trivially on a gate that refuses everything.

The positive path needs a signing key and an issuer, so the test mints an RSA keypair and serves the
discovery document and JWKS from a local HTTP server bound to loopback. Nothing here reaches the
network and nothing needs a cluster.
"""

from __future__ import annotations

import http.server
import json
import sys
import threading
import time
from pathlib import Path

import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa

AGENTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS_DIR / "common"))
sys.path.insert(0, str(AGENTS_DIR / "mcp-server"))

import cluster_auth  # noqa: E402
from cluster_auth import AuthError, bearer_token, verify_alb_oidc, verify_cluster_token  # noqa: E402

AUDIENCE = "mcp-server"
SUBJECT = "system:serviceaccount:agents:research"


# ---------------------------------------------------------------------------
# A local issuer: an RSA key, a discovery document and a JWKS, on loopback.
# ---------------------------------------------------------------------------

def _make_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _jwk(public_key, kid: str) -> dict:
    nums = public_key.public_numbers()

    def b64(n: int) -> str:
        import base64
        raw = n.to_bytes((n.bit_length() + 7) // 8, "big")
        return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()

    return {"kty": "RSA", "use": "sig", "alg": "RS256", "kid": kid,
            "n": b64(nums.n), "e": b64(nums.e)}


class _Issuer:
    """Serves /.well-known/openid-configuration and /keys on 127.0.0.1."""

    def __init__(self, key, kid="test-key-1"):
        self.key = key
        self.kid = kid
        jwks = {"keys": [_jwk(key.public_key(), kid)]}

        issuer_holder = {}

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # noqa: N802
                if self.path.startswith("/.well-known/openid-configuration"):
                    body = json.dumps({
                        "issuer": issuer_holder["url"],
                        "jwks_uri": issuer_holder["url"] + "/keys",
                    }).encode()
                elif self.path.startswith("/keys"):
                    body = json.dumps(jwks).encode()
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):  # keep the test output readable
                pass

        # Loopback only: this is a test fixture, and nothing outside this process should reach it.
        self._srv = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self._srv.server_port}"
        issuer_holder["url"] = self.url
        self._thread = threading.Thread(target=self._srv.serve_forever, daemon=True)
        self._thread.start()

    def sign(self, *, audience=AUDIENCE, subject=SUBJECT, exp_delta=600, iat_delta=0, key=None) -> str:
        now = int(time.time())
        return jwt.encode(
            {"iss": self.url, "sub": subject, "aud": audience,
             "iat": now + iat_delta, "exp": now + exp_delta},
            (key or self.key).private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.PKCS8,
                encryption_algorithm=serialization.NoEncryption(),
            ),
            algorithm="RS256",
            headers={"kid": self.kid},
        )

    def stop(self):
        self._srv.shutdown()


# ---------------------------------------------------------------------------

RESULTS = []


def check(name: str, fn):
    try:
        fn()
        RESULTS.append((True, name))
        print(f"  \033[32mPASS\033[0m {name}")
    except AssertionError as exc:
        RESULTS.append((False, f"{name}: {exc}"))
        print(f"  \033[31mFAIL\033[0m {name}: {exc}")
    except Exception as exc:  # noqa: BLE001
        RESULTS.append((False, f"{name}: unexpected {type(exc).__name__}: {exc}"))
        print(f"  \033[31mFAIL\033[0m {name}: unexpected {type(exc).__name__}: {exc}")


def refuses(fn, because: str):
    """Assert that fn() raises AuthError."""
    try:
        fn()
    except AuthError:
        return
    raise AssertionError(f"accepted a credential it should have refused ({because})")


def main() -> int:
    # Reset the module's key cache between issuers, so one test's keys cannot satisfy another's.
    cluster_auth._jwks = cluster_auth._JWKSCache()

    key = _make_key()
    other_key = _make_key()
    issuer = _Issuer(key)

    print("\ncluster token verification")

    check("no token is refused", lambda: refuses(
        lambda: verify_cluster_token("", audience=AUDIENCE, issuer=issuer.url),
        "empty token"))

    # The important one. A caller can always produce a string shaped like a JWT.
    check("an unsigned, well-formed token is refused", lambda: refuses(
        lambda: verify_cluster_token(
            jwt.encode({"iss": issuer.url, "sub": SUBJECT, "aud": AUDIENCE,
                        "iat": int(time.time()), "exp": int(time.time()) + 600},
                       key="", algorithm="none"),
            audience=AUDIENCE, issuer=issuer.url),
        "alg=none"))

    check("a token signed by the wrong key is refused", lambda: refuses(
        lambda: verify_cluster_token(issuer.sign(key=other_key),
                                     audience=AUDIENCE, issuer=issuer.url),
        "wrong signing key"))

    check("a token for another audience is refused", lambda: refuses(
        lambda: verify_cluster_token(issuer.sign(audience="agentgateway"),
                                     audience=AUDIENCE, issuer=issuer.url),
        "audience mismatch -- a gateway token replayed at an agent"))

    check("an expired token is refused", lambda: refuses(
        lambda: verify_cluster_token(issuer.sign(exp_delta=-120),
                                     audience=AUDIENCE, issuer=issuer.url),
        "expired"))

    # The issuer's clock can run ahead of the pod's, and with no leeway a token used at once fails
    # "not yet valid (iat)".
    def accepts_skewed():
        verify_cluster_token(issuer.sign(iat_delta=2), audience=AUDIENCE, issuer=issuer.url)
    check("a token issued a few seconds ahead of this clock is accepted", accepts_skewed)
    check("a token issued minutes ahead of this clock is refused", lambda: refuses(
        lambda: verify_cluster_token(issuer.sign(iat_delta=300),
                                     audience=AUDIENCE, issuer=issuer.url), "not yet valid"))
    check("a service with no configured audience refuses everything", lambda: refuses(
        lambda: verify_cluster_token(issuer.sign(), audience="", issuer=issuer.url),
        "unconfigured audience must fail closed"))

    check("an unreachable issuer refuses everything", lambda: refuses(
        lambda: verify_cluster_token(issuer.sign(), audience=AUDIENCE,
                                     issuer="http://127.0.0.1:1/nope"),
        "unreachable issuer must fail closed, not open"))

    def accepts_valid():
        caller = verify_cluster_token(issuer.sign(), audience=AUDIENCE, issuer=issuer.url)
        assert caller.subject == SUBJECT, f"subject was {caller.subject!r}"
        assert caller.namespace == "agents", f"namespace was {caller.namespace!r}"
        assert caller.service_account == "research", f"sa was {caller.service_account!r}"

    check("a correctly signed token for the right audience is accepted", accepts_valid)

    # The audience names the callee, and any service account can mint any audience, so the
    # caller's namespace is checked separately when the service names one.
    check("a caller outside the allowed namespaces is refused", lambda: refuses(
        lambda: verify_cluster_token(issuer.sign(subject="system:serviceaccount:other-team:x"),
                                     audience=AUDIENCE, issuer=issuer.url,
                                     allowed_namespaces=frozenset({"agents"})),
        "right audience, wrong namespace"))

    def accepts_allowed_namespace():
        caller = verify_cluster_token(issuer.sign(), audience=AUDIENCE, issuer=issuer.url,
                                      allowed_namespaces=frozenset({"agents"}))
        assert caller.namespace == "agents", f"namespace was {caller.namespace!r}"

    check("a caller in an allowed namespace is accepted", accepts_allowed_namespace)

    print("\nALB identity verification")

    check("a missing x-amzn-oidc-data header is refused", lambda: refuses(
        lambda: verify_alb_oidc({}, region="us-west-2"), "no header"))

    # The chat UI's own failure mode: anything that can reach the pod can set a header, so presence
    # must not be enough.
    check("a forged x-amzn-oidc-data header is refused", lambda: refuses(
        lambda: verify_alb_oidc({"x-amzn-oidc-data": "forged.not.ajwt"}, region="us-west-2"),
        "forged header"))

    check("a syntactically valid but unsigned ALB claim set is refused", lambda: refuses(
        lambda: verify_alb_oidc(
            {"x-amzn-oidc-data": jwt.encode({"email": "attacker@example.invalid"},
                                            key="", algorithm="none")},
            region="us-west-2"),
        "alg=none ALB claims"))

    check("no region refuses everything", lambda: refuses(
        lambda: verify_alb_oidc({"x-amzn-oidc-data": "a.b.c"}, region=""),
        "unconfigured region must fail closed"))

    # Signed ALB claims, with a local P-256 key standing in for the regional ALB key. Every ALB in a
    # Region signs with the same keys, so the signer and client in the signed header are what tie a
    # header to THIS stack's load balancer.
    from cryptography.hazmat.primitives.asymmetric import ec
    alb_key = ec.generate_private_key(ec.SECP256R1())
    alb_pem = alb_key.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo).decode()
    real_fetch = cluster_auth._alb_public_key
    cluster_auth._alb_public_key = lambda region, kid: alb_pem
    ours = "arn:aws:elasticloadbalancing:us-west-2:111122223333:loadbalancer/app/k8s-front/abc"

    def alb(signer=ours, client="pool-client", exp_delta=600, with_exp=True):
        hdr = {"kid": "k1", "signer": signer, "client": client, "iss": "https://idp.example"}
        if with_exp:
            hdr["exp"] = int(time.time()) + exp_delta
        return {"x-amzn-oidc-data": jwt.encode({"sub": "u1", "email": "p@example.com"},
                                               alb_key, algorithm="ES256", headers=hdr)}

    bound = {"region": "us-west-2", "account_id": "111122223333", "client_id": "pool-client"}

    def accepts_our_alb():
        caller = verify_alb_oidc(alb(), **bound)
        assert caller.subject == "p@example.com", f"subject was {caller.subject!r}"

    check("claims signed by this account's ALB for this client are accepted", accepts_our_alb)
    check("claims signed by another account's ALB are refused", lambda: refuses(
        lambda: verify_alb_oidc(alb(signer=ours.replace("111122223333", "444455556666")), **bound),
        "foreign ALB, valid regional signature"))
    check("claims for another identity-provider client are refused", lambda: refuses(
        lambda: verify_alb_oidc(alb(client="someone-elses-client"), **bound), "wrong client"))
    check("ALB claims with no expiry are refused", lambda: refuses(
        lambda: verify_alb_oidc(alb(with_exp=False), **bound), "no exp"))
    check("expired ALB claims are refused", lambda: refuses(
        lambda: verify_alb_oidc(alb(exp_delta=-120), **bound), "expired"))
    cluster_auth._alb_public_key = real_fetch

    print("\nbearer token parsing")

    check("a bearer token is read from the header",
          lambda: (lambda t: (_ for _ in ()).throw(AssertionError(f"got {t!r}")) if t != "abc"
                   else None)(bearer_token({"Authorization": "Bearer abc"})))
    check("a non-bearer scheme yields nothing",
          lambda: (lambda t: (_ for _ in ()).throw(AssertionError(f"got {t!r}")) if t != ""
                   else None)(bearer_token({"Authorization": "Basic abc"})))

    print("\nthe test bypass is off unless explicitly set")

    import os
    check("an arbitrary value does not enable the bypass", lambda: (
        os.environ.__setitem__("AUTH_TEST_BYPASS", "true"),
        refuses(lambda: verify_cluster_token("", audience=AUDIENCE, issuer=issuer.url),
                "AUTH_TEST_BYPASS=true must NOT enable the bypass"),
        os.environ.pop("AUTH_TEST_BYPASS"),
    ) and None)

    issuer.stop()

    failed = [name for ok, name in RESULTS if not ok]
    print()
    if failed:
        print(f"\033[31m{len(failed)} of {len(RESULTS)} checks failed\033[0m")
        return 1
    print(f"\033[32mall {len(RESULTS)} credential checks behave correctly\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
