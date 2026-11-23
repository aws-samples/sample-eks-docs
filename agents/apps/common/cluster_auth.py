"""Verify a caller's credential, using the mechanisms this cluster already issues.

Three services in this repository accept requests -- the agent's HTTP server, the MCP server and
the chat UI -- and each needs to know who is calling before it answers. This module is the one
implementation of that check, so there is a single place to review it.

Two credential types, because the callers are different:

  verify_cluster_token()  A workload calling from inside the cluster. It presents a projected
                          service account token whose audience names the thing it is calling. It
                          is verified against the cluster's own OIDC issuer -- the same issuer and
                          the same token the egress gateway validates, so a caller needs no second
                          credential and this module invents none.

  verify_alb_oidc()       A person at a browser, arriving through the ALB ingress. The load
                          balancer runs the OIDC flow and signs the resulting claims into an
                          x-amzn-oidc-data header. That signature is verified against the
                          regional ALB public key endpoint.

WHY THIS VERIFIES RATHER THAN DETECTS. A middleware that admits any request carrying a header is
decorative: anything that can reach the pod can set a header. Both functions below check a
signature against a key they fetch from the issuer, and reject on any failure. There is no code
path that accepts an unverified credential.

FAIL CLOSED. Every error -- a missing header, an unreachable issuer, an unknown key id, a bad
signature, a wrong audience, an expired token -- raises AuthError, and the callers in this
repository turn that into a 401. A service that cannot reach its issuer refuses every request
rather than admitting them unchecked.

The one bypass is AUTH_TEST_BYPASS, which has to be set to the exact string "i-understand-this-is-
insecure" and logs a warning on every request. It is for a developer running the service on a
laptop with no cluster. It defaults to off, it is named for what it does, and nothing ambient like
an environment name enables it.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any

import jwt
from jwt import PyJWKClient

log = logging.getLogger("cluster_auth")

# CLOCK SKEW BETWEEN THE ISSUER AND THIS POD. A pod's clock can run slightly behind the API
# server's, and with PyJWT's default leeway of zero a token created and used at once can fail with
# "The token is not yet valid (iat)". 60 s matches the leeway the Kubernetes API server itself
# applies to service account tokens.
_CLOCK_SKEW_SECONDS = 60

_BYPASS_VALUE = "i-understand-this-is-insecure"

# The ALB signs with ES256 and publishes one key per region. Pinning the algorithm matters: without
# it, a token presented as "alg": "none" would be accepted by a permissive decoder.
_ALB_ALGORITHMS = ["ES256"]
_CLUSTER_ALGORITHMS = ["RS256"]


class AuthError(Exception):
    """A caller could not be verified. Callers translate this into 401, never 500."""


@dataclass
class Caller:
    """Who is calling, after verification. Never constructed from unverified input."""

    kind: str  # "workload" or "person"
    subject: str
    claims: dict[str, Any] = field(default_factory=dict)

    @property
    def namespace(self) -> str:
        """For a workload token, the namespace it came from.

        A Kubernetes service account subject is system:serviceaccount:<namespace>:<name>, so the
        namespace is a claim rather than something the caller asserts separately.
        """
        parts = self.subject.split(":")
        return parts[2] if len(parts) >= 4 and parts[0] == "system" else ""

    @property
    def service_account(self) -> str:
        parts = self.subject.split(":")
        return parts[3] if len(parts) >= 4 and parts[0] == "system" else ""


def _bypass_enabled() -> bool:
    if os.environ.get("AUTH_TEST_BYPASS", "") == _BYPASS_VALUE:
        log.warning(
            "AUTH_TEST_BYPASS is set: this request was NOT authenticated. "
            "Never set this outside a developer machine."
        )
        return True
    return False


class _JWKSCache:
    """One PyJWKClient per issuer, so keys are fetched once and cached rather than per request."""

    def __init__(self) -> None:
        self._clients: dict[str, PyJWKClient] = {}

    def get(self, jwks_uri: str) -> PyJWKClient:
        if jwks_uri not in self._clients:
            # lifespan is the cache TTL. Short enough that a rotated signing key is picked up
            # without a restart; long enough that a request does not fetch keys.
            self._clients[jwks_uri] = PyJWKClient(jwks_uri, cache_keys=True, lifespan=300)
        return self._clients[jwks_uri]


_jwks = _JWKSCache()


def _discover_jwks_uri(issuer: str) -> str:
    """Read jwks_uri from the issuer's discovery document.

    Do not assemble this by hand. An EKS cluster's public OIDC endpoint serves its keys at
    {issuer}/keys, while the in-cluster API server path is {issuer}/openid/v1/jwks -- and guessing
    the second against the first returns 403, which reads like an authorization problem rather than
    a wrong URL. The discovery document is authoritative for both.
    """
    url = issuer.rstrip("/") + "/.well-known/openid-configuration"
    # urlopen also opens file: and custom schemes; an issuer is only ever an http(s) URL.
    if urllib.parse.urlsplit(url).scheme not in ("https", "http"):
        raise AuthError(f"the OIDC issuer must be an http(s) URL, not {issuer!r}")
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            doc = json.load(resp)
    except Exception as exc:  # noqa: BLE001 - any failure here must fail closed
        raise AuthError(f"cannot read OIDC discovery at {url}: {exc}") from exc

    uri = doc.get("jwks_uri")
    if not uri:
        raise AuthError(f"no jwks_uri in the discovery document at {url}")
    return uri


def allowed_namespaces_from_env(name: str) -> frozenset[str]:
    """A comma-separated namespace list from the environment; empty means no namespace check."""
    return frozenset(n.strip() for n in os.environ.get(name, "").split(",") if n.strip())


def verify_cluster_token(
    token: str, *, audience: str, issuer: str, allowed_namespaces: frozenset[str] = frozenset()
) -> Caller:
    """Verify a projected service account token from a workload in this cluster.

    audience is what this service is called as. It is not optional: a token is minted for a specific
    audience, and accepting any audience would let a token minted for the egress gateway be replayed
    against this service.

    THE AUDIENCE NAMES THE CALLEE, NOT THE CALLER. Any service account in the cluster can ask the
    API server for a token with any audience, so a verified audience says only that the token was
    meant for this service. allowed_namespaces is who may call it: when non-empty, the verified
    subject's namespace has to be in it.
    """
    if _bypass_enabled():
        return Caller(kind="workload", subject="system:serviceaccount:dev:bypass")

    if not token:
        raise AuthError("no bearer token on the request")
    if not audience:
        raise AuthError("this service has no configured audience, so no token can be verified")
    if not issuer:
        raise AuthError("this service has no configured OIDC issuer, so no token can be verified")

    jwks_uri = _discover_jwks_uri(issuer)

    try:
        signing_key = _jwks.get(jwks_uri).get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=_CLUSTER_ALGORITHMS,
            audience=audience,
            issuer=issuer,
            options={"require": ["exp", "iat", "sub", "aud", "iss"]},
            leeway=_CLOCK_SKEW_SECONDS,
        )
    except Exception as exc:  # noqa: BLE001 - every verification failure is a 401, not a 500
        raise AuthError(f"token verification failed: {exc}") from exc

    subject = claims.get("sub", "")
    if not subject:
        raise AuthError("verified token carries no subject")

    caller = Caller(kind="workload", subject=subject, claims=claims)
    if allowed_namespaces and caller.namespace not in allowed_namespaces:
        raise AuthError(f"caller {subject} is not in a namespace allowed to call this service")
    return caller


def _alb_public_key(region: str, kid: str) -> str:
    url = f"https://public-keys.auth.elb.{region}.amazonaws.com/{kid}"
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            return resp.read().decode()
    except Exception as exc:  # noqa: BLE001
        raise AuthError(f"cannot fetch the ALB signing key at {url}: {exc}") from exc


def verify_alb_oidc(
    headers: dict[str, str], *, region: str, account_id: str = "", client_id: str = ""
) -> Caller:
    """Verify the claims the ALB signed after running the OIDC flow.

    The load balancer puts three headers on the request. Only x-amzn-oidc-data is signed, so it is
    the only one worth reading -- x-amzn-oidc-identity and x-amzn-oidc-accesstoken are not
    independently verifiable here and anything that can reach the pod can set them.

    This is why the pod must not be reachable except through the load balancer. The Service is
    ClusterIP and the route is the only way in; see the network policy in gitops/base.

    A VALID SIGNATURE SAYS AN ALB SIGNED IT, NOT THAT OURS DID. Every load balancer in a Region signs
    with the same regional keys, so a header minted by someone else's ALB, in front of their own
    identity provider, verifies too. The signed JWT header names the signer and the client, so they
    are checked: account_id pins the signing load balancer to this account and region, and
    client_id pins the identity-provider client. Each is checked when set. exp is always required.
    """
    if _bypass_enabled():
        return Caller(kind="person", subject="dev-bypass@example.invalid")

    lowered = {k.lower(): v for k, v in headers.items()}
    data = lowered.get("x-amzn-oidc-data", "")
    if not data:
        raise AuthError(
            "no x-amzn-oidc-data header. This service must sit behind an ALB listener rule that "
            "runs the browser sign-in (authenticate-cognito); see gitops/base/templates/60-chat-ui.yaml."
        )

    # The key id names which regional ALB key signed it, and the key endpoint is per region.
    try:
        kid = jwt.get_unverified_header(data)["kid"]
    except Exception as exc:  # noqa: BLE001
        raise AuthError(f"cannot read the key id from x-amzn-oidc-data: {exc}") from exc

    if not region:
        raise AuthError("no region configured, so the ALB signing key cannot be fetched")

    pub_key = _alb_public_key(region, kid)

    try:
        claims = jwt.decode(data, pub_key, algorithms=_ALB_ALGORITHMS, leeway=_CLOCK_SKEW_SECONDS)
        # Covered by the signature just verified, so these header fields are the ALB's.
        header = jwt.get_unverified_header(data)
    except Exception as exc:  # noqa: BLE001
        raise AuthError(f"ALB claim verification failed: {exc}") from exc

    signer = str(header.get("signer", ""))
    if account_id:
        prefix = re.compile(
            rf"^arn:aws[a-z-]*:elasticloadbalancing:{re.escape(region)}:{re.escape(account_id)}:loadbalancer/app/"
        )
        if not prefix.match(signer):
            raise AuthError(f"the ALB claims were signed by {signer or 'no signer'}, not a load balancer in this account")
    if client_id and header.get("client") != client_id:
        raise AuthError("the ALB claims were issued for another identity-provider client")

    # The ALB puts exp in the JWT header; the IdP's claims may carry their own. One is required, and
    # every one present must be in the future.
    exps = [e for e in (header.get("exp"), claims.get("exp")) if e not in (None, "")]
    if not exps:
        raise AuthError("the ALB claims carry no expiry")
    try:
        if any(time.time() > float(e) for e in exps):
            raise AuthError("the ALB claims have expired")
    except (TypeError, ValueError) as exc:
        raise AuthError(f"the ALB claims carry an unreadable expiry: {exc}") from exc

    subject = claims.get("email") or claims.get("sub") or ""
    if not subject:
        raise AuthError("verified ALB claims carry no subject or email")

    return Caller(kind="person", subject=subject, claims=claims)


# The header a person's own token travels in, from the chat UI or an application to the agent and
# from the agent to a tool. Never the Authorization header: that carries the CALLER's credential
# (the chat UI's or the agent's workload token), which says who is calling, not who it is for.
PERSON_TOKEN_HEADER = "x-person-token"

# Cognito signs with RS256. Pinned for the same reason as the cluster's algorithms.
_PERSON_ALGORITHMS = ["RS256"]


def person_token(headers: dict[str, str]) -> str:
    """The person's token from PERSON_TOKEN_HEADER, or an empty string. Not verified here."""
    lowered = {k.lower(): v for k, v in headers.items()}
    value = lowered.get(PERSON_TOKEN_HEADER, "").strip()
    # A JWT is three base64url parts. Anything else is not a token this module could verify, and a
    # bounded length keeps a header from becoming a way to push a large value through every hop.
    if not value or len(value) > 8192 or not re.fullmatch(r"[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+", value):
        return ""
    return value


def verify_person_token(token: str, *, issuer: str, client_ids: frozenset[str]) -> Caller:
    """Verify a token a person's identity provider issued to them, and return the person.

    This is how a tool acts for a person rather than for whoever called it: the token is signed by
    the identity provider, so the agent passing it on can present it but cannot make one for anyone
    else. Two token types, because a person can arrive with either:

      access token  what the load balancer forwards after the browser sign-in
                    (x-amzn-oidc-accesstoken). token_use "access", the client in `client_id`,
                    no `aud`.
      ID token      what an application receives when it signs the person in itself. token_use
                    "id", the client in `aud`. Also what STS exchanges for AWS credentials.

    client_ids is which clients of the pool may have issued it. A token for some other client of
    the same pool is refused: the pool's other applications are not this deployment's.
    """
    if _bypass_enabled():
        return Caller(kind="person", subject="dev-bypass-person")
    if not token:
        raise AuthError("no person token on the request")
    if not issuer:
        raise AuthError("no person-token issuer is configured, so no person can be verified")
    if not client_ids:
        raise AuthError("no person-token clients are configured, so no person can be verified")

    jwks_uri = _discover_jwks_uri(issuer)
    try:
        signing_key = _jwks.get(jwks_uri).get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=_PERSON_ALGORITHMS,
            issuer=issuer,
            # The audience is checked below, per token type: an access token has none.
            options={"require": ["exp", "iat", "sub", "iss"], "verify_aud": False},
            leeway=_CLOCK_SKEW_SECONDS,
        )
    except Exception as exc:  # noqa: BLE001 - every verification failure is a refusal
        raise AuthError(f"person token verification failed: {exc}") from exc

    use = claims.get("token_use", "")
    if use == "access":
        client = claims.get("client_id", "")
    elif use == "id":
        client = claims.get("aud", "")
    else:
        raise AuthError(f"person token has token_use {use!r}; expected access or id")
    if client not in client_ids:
        raise AuthError("person token was issued for a client this deployment does not accept")

    subject = claims.get("sub", "")
    if not subject:
        raise AuthError("verified person token carries no subject")
    return Caller(kind="person", subject=subject, claims=claims)


def verify_delegated_token(token: str, *, issuer: str, audience: str, actor_issuer: str,
                           actor_clients: dict[str, str] | None = None) -> tuple[Caller, str]:
    """Verify ONE token that names a person and the agent acting for them, and return both.

    The gateway exchanges the person's access token (subject) and the calling agent's own projected
    service account token (actor) at the person's user pool (RFC 8693 delegation,
    person_access_delegated_token). The pool signs the result:

      sub    the person
      aud    `audience`, this deployment's tools -- a token for anything else is refused
      act    {sub: system:serviceaccount:<namespace>:<agent>, iss: the cluster's OIDC issuer}

    Returns (person, agent subject). The agent is read from a claim the pool signed, after the pool
    verified the actor token against `actor_issuer`, so neither the agent nor the gateway can name a
    different one. Which agents may act is the caller's decision (PERSON_ACCESS_AGENTS): the pool
    does not restrict it.

    With `actor_clients` (the AWS services path), the actor is an agent's own Cognito client, from
    AgentCore Identity's on-behalf-of exchange: act.sub is a client id, act.iss is the pool, and
    `actor_clients` maps each client id to the agent's workload subject. A client id it doesn't
    name is refused.
    """
    if _bypass_enabled():
        return Caller(kind="person", subject="dev-bypass-person"), "dev-bypass-agent"
    if not token:
        raise AuthError("no delegated token on the request")
    if not (issuer and audience and actor_issuer):
        raise AuthError("delegated tokens are not configured (issuer, audience and actor issuer are all required)")
    jwks_uri = _discover_jwks_uri(issuer)
    try:
        signing_key = _jwks.get(jwks_uri).get_signing_key_from_jwt(token)
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=_PERSON_ALGORITHMS,
            issuer=issuer,
            audience=audience,
            options={"require": ["exp", "iat", "sub", "iss", "aud"]},
            leeway=_CLOCK_SKEW_SECONDS,
        )
    except Exception as exc:  # noqa: BLE001 - every verification failure is a refusal
        raise AuthError(f"delegated token verification failed: {exc}") from exc
    if claims.get("token_use") != "access":
        raise AuthError(f"delegated token has token_use {claims.get('token_use')!r}; expected access")
    act = claims.get("act")
    if not isinstance(act, dict) or not act.get("sub"):
        raise AuthError("token names no actor (act): it is the person's own token, not one delegated to an agent")
    if act.get("iss") != actor_issuer:
        raise AuthError("the token's actor was not issued by the expected issuer")
    subject = claims.get("sub", "")
    if not subject or subject == act.get("sub"):
        raise AuthError("delegated token names no person distinct from its actor")
    if actor_clients is not None:
        agent = actor_clients.get(str(act["sub"]))
        if not agent:
            raise AuthError("the token's actor is not a client of any agent allowed to act for a person")
        return Caller(kind="person", subject=subject, claims=claims), agent
    return Caller(kind="person", subject=subject, claims=claims), str(act["sub"])


# Where an agent that is its own exchanger (the AWS services path) sends a tool the delegated token.
# Authorization still carries the agent's own token for the tool's caller check.
DELEGATED_TOKEN_HEADER = "x-delegated-token"


def delegated_token(headers: dict[str, str]) -> str:
    """The delegated token from x-delegated-token, or an empty string."""
    lowered = {k.lower(): v for k, v in headers.items()}
    return lowered.get(DELEGATED_TOKEN_HEADER, "").strip()


def bearer_token(headers: dict[str, str]) -> str:
    """Pull a bearer token out of an Authorization header, or return an empty string."""
    lowered = {k.lower(): v for k, v in headers.items()}
    value = lowered.get("authorization", "")
    scheme, _, token = value.partition(" ")
    return token.strip() if scheme.lower() == "bearer" else ""
