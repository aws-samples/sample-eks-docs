"""Acting with a person's own authority.

Three ways an agent can act, and this module is the third:

  1. As itself. Its own IAM role and its own token decide everything, whoever asked.
  2. For a person, with the person as context. The caller names the person (user_id), and the
     agent keeps their sessions and memories apart -- but every call it makes is still its own.
  3. With the person's authority. The person's own token goes with the request, and what the agent
     can reach is decided by what THAT PERSON may reach -- by a tool that verifies the token, or by
     AWS after the token is exchanged for credentials. A request for someone else's data is refused
     whatever the model was asked to do.

The person's token arrives in the x-person-token header (cluster_auth.PERSON_TOKEN_HEADER), from
the chat UI (an access token the load balancer forwarded) or from an application that signed the
person in itself (an ID token). The agent does not authorize on it. It does two things with it:

  - forwards it to tools, which verify it with the identity provider and answer for that person
    (agents/mcp-server: my_account, get_account). Either token type works.
  - for an ID token only, exchanges it with STS AssumeRoleWithWebIdentity for the person role
    (terraform/modules/person-access), and registers two tools that use those credentials on the
    person's own prefix of the person-data bucket. STS refuses an access token ("Missing a required
    claim: aud"), so a person signed in at the chat UI gets the first and not the second.

The exchange is unsigned: STS validates the person's token, not the agent's credentials, so the
agent's own role grants nothing here and needs no permission for it.

The role is THIS AGENT'S person role (person_access_agents): its permissions are the intersection of
the person's prefix and this agent's part of it, people/<sub>/<agent>/, and its trust admits only a
session named "<agent>-...", so the session name below puts the agent and the person on CloudTrail's
record of the exchange. AssumeRoleWithWebIdentity has no SourceIdentity parameter.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import re
import time
from typing import Any

log = logging.getLogger("person_access")

ROLE_ARN = os.environ.get("AGENT_PERSON_ROLE_ARN", "").strip()
BUCKET = os.environ.get("AGENT_PERSON_BUCKET", "").strip()
REGION = os.environ.get("AWS_REGION", "") or os.environ.get("AWS_DEFAULT_REGION", "")
AGENT = os.environ.get("AGENT_NAME", "").strip()
NOTES_KEY = "notes.txt"
# Through the gateway (person_access_via_gateway): the agent's /aws/<agent>/s3 route. Set, the S3
# calls below go there UNSIGNED with the agent's own token and the person's, and the gateway signs
# them as this agent's person role tagged with the person it verified; the agent holds no AWS
# credential for the person at all.
S3_VIA_GATEWAY = os.environ.get("AGENT_PERSON_S3_URL", "").strip()
GATEWAY_TOKEN_FILE = os.environ.get("AGENT_IDENTITY_TOKEN_FILE", "/var/run/secrets/eks-agents/gateway/token")


def _claims(token: str) -> dict:
    try:
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        return json.loads(base64.urlsafe_b64decode(part))
    except Exception:  # noqa: BLE001 - an unreadable token is simply not one to exchange
        return {}


def token_use(token: str) -> str:
    """The token's token_use claim, read WITHOUT verifying it.

    Only to choose what to try. Nothing is granted on it: a tool verifies the token itself, and STS
    verifies it before issuing anything.
    """
    return str(_claims(token).get("token_use", ""))


def session_name(agent: str, token: str, now: int | None = None) -> str:
    """The role session name: "<agent>-<first 8 of the person's sub>-<epoch>".

    The person role's trust requires the "<agent>-" prefix, so the agent is on the record. The sub is
    read unverified, for the record only; STS verifies the token, and CloudTrail also carries the
    verified sub as the caller's userName. 2-64 characters of [\w+=,.@-].
    """
    sub = re.sub(r"[^\w+=,.@-]", "", str(_claims(token).get("sub", "")))[:8] or "unknown"
    name = f"{agent}-{sub}-{int(time.time()) if now is None else now}"
    return re.sub(r"[^\w+=,.@-]", "-", name)[:64]


def exchange(token: str) -> tuple[Any, str]:
    """The person's AWS session and subject, from their ID token. Raises on any refusal."""
    import boto3
    from botocore import UNSIGNED
    from botocore.config import Config

    sts = boto3.client("sts", region_name=REGION, config=Config(signature_version=UNSIGNED))
    resp = sts.assume_role_with_web_identity(
        RoleArn=ROLE_ARN,
        RoleSessionName=session_name(AGENT, token),
        WebIdentityToken=token,
        DurationSeconds=900,
    )
    c = resp["Credentials"]
    session = boto3.session.Session(
        aws_access_key_id=c["AccessKeyId"],
        aws_secret_access_key=c["SecretAccessKey"],
        aws_session_token=c["SessionToken"],
        region_name=REGION,
    )
    return session, resp["SubjectFromWebIdentityToken"]


AWS_VIA_GATEWAY = os.environ.get("AGENT_PERSON_AWS_URL", "").strip()


def gateway_client(service: str, token: str, **client_kwargs: Any) -> Any:
    """A boto3 client for any AWS service the platform routes through the gateway for a person
    (person_access_gateway_services), at <AGENT_PERSON_AWS_URL>/<service>.

    Unsigned, with the agent's own token, the person's ID token and the body's SHA-256 on every
    request: the gateway verifies both tokens and signs as this agent's person role tagged with the
    person. What the call may reach is the platform's IAM statements for that service, keyed on the
    person tag. Raises if this agent has no person routes.
    """
    if not AWS_VIA_GATEWAY:
        raise RuntimeError("no person routes through the gateway for this agent (AGENT_PERSON_AWS_URL)")
    import boto3
    from botocore import UNSIGNED
    from botocore.config import Config

    config = Config(signature_version=UNSIGNED, s3={"addressing_style": "path"}) if service == "s3" \
        else Config(signature_version=UNSIGNED)
    client = boto3.client(service, region_name=REGION, endpoint_url=f"{AWS_VIA_GATEWAY}/{service}",
                          config=config, **client_kwargs)
    client.meta.events.register(f"before-send.{client.meta.service_model.endpoint_prefix}", _tokens_hook(token))
    return client


def _tokens_hook(token: str):
    def add_tokens(request, **_):
        with open(GATEWAY_TOKEN_FILE, encoding="utf-8") as fh:
            request.headers["Authorization"] = "Bearer " + fh.read().strip()
        request.headers["x-person-token"] = token
        # S3 refuses a request without x-amz-content-sha256, and AgentGateway's signer hashes the
        # body without adding the header; harmless for the services that do not need it.
        body = request.body or b""
        if hasattr(body, "read"):
            pos = body.tell() if hasattr(body, "tell") else None
            data = body.read()
            if pos is not None:
                body.seek(pos)
            body = data
        if isinstance(body, str):
            body = body.encode()
        request.headers["x-amz-content-sha256"] = hashlib.sha256(body).hexdigest()
    return add_tokens


def gateway_s3(token: str) -> tuple[Any, str]:
    """An S3 client for the person, through the gateway, and the person's subject.

    Unsigned: the gateway signs. Path style, because the route carries the bucket in the path. The
    subject is read unverified, to build the key only: the gateway verifies the token, and IAM
    refuses any key outside the subject the gateway tagged the session with.
    """
    import boto3
    from botocore import UNSIGNED
    from botocore.config import Config

    client = boto3.client("s3", region_name=REGION, endpoint_url=S3_VIA_GATEWAY,
                          config=Config(signature_version=UNSIGNED, s3={"addressing_style": "path"}))

    def add_tokens(request, **_):
        with open(GATEWAY_TOKEN_FILE, encoding="utf-8") as fh:
            request.headers["Authorization"] = "Bearer " + fh.read().strip()
        request.headers["x-person-token"] = token
        # S3 REFUSES A REQUEST WITHOUT x-amz-content-sha256 ("Missing required header"), and
        # AgentGateway's signer hashes the body into the signature without adding the header.
        # The agent sends the body's SHA-256, the value the
        # gateway's signature covers; it is a hash, not a credential.
        body = request.body or b""
        if hasattr(body, "read"):
            pos = body.tell() if hasattr(body, "tell") else None
            data = body.read()
            if pos is not None:
                body.seek(pos)
            body = data
        if isinstance(body, str):
            body = body.encode()
        request.headers["x-amz-content-sha256"] = hashlib.sha256(body).hexdigest()

    client.meta.events.register("before-send.s3", add_tokens)
    return client, str(_claims(token).get("sub", ""))


def person_tools(token: str) -> list:
    """Tools that act with the person's own AWS permissions, or none.

    None unless the platform gave this agent a person role (person_access_agents) and the token is an
    ID token. The prefix is the subject STS returned from the verified token and this agent's name,
    so the model never chooses it -- and IAM refuses any other prefix whatever the code here did.
    """
    if not (BUCKET and AGENT and token and token_use(token) == "id"):
        return []
    if not (ROLE_ARN or S3_VIA_GATEWAY):
        return []
    try:
        from strands import tool
    except ImportError:  # pragma: no cover - the SDK is present in the image
        return []

    state: dict[str, Any] = {}

    def _s3():
        if "s3" not in state:
            if S3_VIA_GATEWAY:
                state["s3"], subject = gateway_s3(token)
            else:
                session, subject = exchange(token)
                state["s3"] = session.client("s3")
            state["prefix"] = f"people/{subject}/{AGENT}/"
        return state["s3"], state["prefix"]

    def save_my_note(text: str) -> str:
        """Save a note for the person this request is for, replacing their previous one."""
        try:
            s3, prefix = _s3()
            s3.put_object(Bucket=BUCKET, Key=prefix + NOTES_KEY, Body=text.encode()[:4096])
        except Exception as exc:  # noqa: BLE001 - say why to the model rather than fail the turn
            log.info("save_my_note refused: %s", exc)
            return f"could not save the note with the person's own permissions: {type(exc).__name__}"
        return "saved"

    def read_my_note() -> str:
        """Read the note saved for the person this request is for."""
        try:
            s3, prefix = _s3()
            return s3.get_object(Bucket=BUCKET, Key=prefix + NOTES_KEY)["Body"].read().decode()
        except Exception as exc:  # noqa: BLE001
            name = getattr(exc, "response", {}).get("Error", {}).get("Code", type(exc).__name__)
            if name == "NoSuchKey":
                return "this person has no saved note"
            log.info("read_my_note refused: %s", exc)
            return f"could not read the note with the person's own permissions: {name}"

    return [
        tool(name="save_my_note", description=save_my_note.__doc__)(save_my_note),
        tool(name="read_my_note", description=read_my_note.__doc__)(read_my_note),
    ]
