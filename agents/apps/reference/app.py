"""A minimal agent on the Strands Agents SDK, wired to this stack's contracts.

This is the reference the Agent resource's defaults assume. It is deliberately small: the point is
not to show what an agent can do, it is to show the four places an agent on this stack has to agree
with the platform, and what happens at each if it does not.

  1. The model is reached through the gateway, not through the Bedrock SDK. The one exception is the
     separate reasoning-direct image (MODEL_ROUTE=bedrock-direct at build time), for a platform
     with no gateway: see build_direct_model below for what that gives up.
  2. Session state lives outside the pod: the conversation is saved after every turn and reloaded
     when the same caller continues the same session, from any replica or after a restart.
  3. Checkpoints go to the agent's own S3 prefix, which its IAM role scopes it to.
  4. Telemetry is OpenTelemetry with the GenAI semantic conventions.
  5. Optionally, consolidated memory across sessions (rung 3 on the open source path): Mem0 as a
     library, on the platform's pgvector tier, with its model calls through the same gateway.

Everything it needs arrives as environment variables that the Agent resource sets. Nothing here
reads a Kubernetes API, holds a long-lived secret, or chooses its own destination -- each of those
would be refused by a layer of the stack anyway, and the comments say which.

Run it locally against a gateway with:

    AGENT_NAME=research \\
    AGENT_GATEWAY_URL=http://localhost:8080/llm/research \\
    CHECKPOINT_BUCKET=... CHECKPOINT_PREFIX=agents/research/ \\
    python app.py
"""

import logging
import os
import pathlib
import sys
import uuid

# The shared modules, copied into the image next to this file; see the Dockerfile.
sys.path.insert(0, str(pathlib.Path(__file__).parent))

from person_access import person_tools, token_use  # noqa: E402
from cluster_auth import DELEGATED_TOKEN_HEADER, PERSON_TOKEN_HEADER  # noqa: E402
import httpx  # noqa: E402 -- a dependency of strands and the MCP client
from strands import Agent  # noqa: E402
from strands.models.openai import OpenAIModel  # noqa: E402


class _TextAsString(OpenAIModel):
    """Sends a message whose content is only text as one string, not a list of text parts.

    THE GATEWAY'S GUARDRAIL SCORES WHAT ITS JSONPATH MATCHES. For chat completions that is
    `content`, and a list of parts there is scored as its serialized JSON, which the prompt-attack
    classifier reads as an attack often enough to refuse ordinary turns: a benign prompt sent as
    parts can be refused where the same prompt as a string is not. Both shapes are valid chat
    completions, so the string is sent whenever it carries the same text. A message with an image
    or any other kind of part keeps the list.
    """

    @classmethod
    def format_request_messages(cls, messages, system_prompt=None, **kwargs):  # type: ignore[override]
        out = super().format_request_messages(messages, system_prompt, **kwargs)
        for message in out:
            parts = message.get("content")
            if isinstance(parts, list) and parts and all(
                isinstance(p, dict) and p.get("type") == "text" and isinstance(p.get("text"), str) for p in parts
            ):
                message["content"] = "\n".join(p["text"] for p in parts)
        return out
from strands.telemetry import StrandsTelemetry  # noqa: E402

log = logging.getLogger("agent")


# The model endpoint, under this stack's name and the OpenAI SDK's.
#
# AGENT_GATEWAY_URL is what the Agent resource sets; OPENAI_BASE_URL is what an agent written against
# the OpenAI SDK already reads, and the resource sets it to the same value. Both name an
# OpenAI-compatible endpoint that holds the model credential so the agent does not.
GATEWAY_URL_VARS = ("AGENT_GATEWAY_URL", "OPENAI_BASE_URL")
GATEWAY_KEY_VARS = ("OPENAI_API_KEY",)

# WHICH IMAGE THIS IS, baked at build time by the Dockerfile's MODEL_ROUTE argument and not set by
# the Agent resource. `gateway` (agents/reasoning, the default) reaches a model only through the
# gateway and refuses to start without one. `bedrock-direct` (agents/reasoning-direct) uses the
# gateway when the platform hands it one, and otherwise calls Amazon Bedrock itself on the agent's
# own Pod Identity role. Two images rather than a runtime switch, so that the default image has no
# code path to Bedrock at all: an agent on it cannot be configured into bypassing the gateway.
IMAGE_MODEL_ROUTE = os.environ.get("AGENT_IMAGE_MODEL_ROUTE", "gateway")


def read_gateway_token(token_path: str) -> str:
    """Read the pod's projected service account token.

    This is the agent's only outbound credential, and it is what both gateways authenticate: the
    gateway reads the identity off it, assumes this agent's IAM role, and signs the call.

    Read it when a model is built rather than caching it at startup. The kubelet rewrites this file
    in place when it refreshes the token, so a value captured once is valid until the first refresh
    and rejected afterwards -- which looks like an agent that worked and then stopped, on a timer
    nobody is watching.
    """
    try:
        token = pathlib.Path(token_path).read_text().strip()
    except OSError as exc:
        sys.exit(
            f"cannot read the gateway token at {token_path}: {exc}. The Agent resource projects it; "
            f"a pod without it holds no credential any gateway on this stack accepts."
        )
    if not token:
        sys.exit(f"the gateway token at {token_path} is empty")
    return token


def gateway_key_provider(token_path: str):
    """The OpenAI client's api_key as a callable, so the token file is read on EVERY request.

    The gateway token lives ten minutes and the kubelet rewrites the file at 80% of that, so the
    copy a turn starts with can have two minutes left. A turn of several model and tool calls
    outlives that, and its later calls are refused 403 insufficient_scope -- the gateway's answer
    to an expired token: a cached token is refused 5 s after its exp, and the same file re-read is
    accepted. The OpenAI SDK calls this before each request, retries
    included, and Strands builds a client per request, so nothing here is cached.
    """
    async def provide() -> str:
        try:
            token = pathlib.Path(token_path).read_text().strip()
        except OSError as exc:
            raise RuntimeError(f"cannot read the gateway token at {token_path}: {exc}") from exc
        if not token:
            raise RuntimeError(f"the gateway token at {token_path} is empty")
        return token
    return provide


class TokenFileAuth(httpx.Auth):
    """The same for the MCP client: the Authorization header from the token file, per request."""

    def __init__(self, token_path: str):
        self.token_path = token_path

    def auth_flow(self, request):
        request.headers["Authorization"] = "Bearer " + pathlib.Path(self.token_path).read_text().strip()
        yield request


def _first_set(*names: str) -> str:
    for n in names:
        v = os.environ.get(n, "").strip()
        if v:
            return v
    return ""


def _required(name: str) -> str:
    """Fail at startup on missing configuration rather than at the first request.

    An agent that starts without its gateway URL looks healthy and fails on its first turn, by
    which point it is serving traffic. The readiness probe would pass and the deployment would roll.
    """
    value = os.environ.get(name, "").strip()
    if not value:
        sys.exit(
            f"{name} is not set. The Agent resource sets it; if you are running this outside the "
            f"cluster, set it yourself. Refusing to start without it rather than failing on the "
            f"first turn."
        )
    return value


def setup_telemetry() -> None:
    """Turn on OpenTelemetry, which does not happen by itself.

    Setting OTEL_* environment variables is necessary and not sufficient: nothing reads them until a
    provider is created and an exporter attached. Without this call the agent completes model calls
    and emits no spans and no metrics, the dashboard stays empty, and every component reports
    healthy -- a successful model call then produces no gen_ai_* series at the collector.
    """
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "").strip()
    if not endpoint:
        # Say so rather than exporting to localhost:4318, which is nothing in a pod and drops
        # everything without a word.
        log.warning(
            "OTEL_EXPORTER_OTLP_ENDPOINT is not set, so no telemetry will be exported. The Agent "
            "resource sets it when the platform has a collector (enable_observability); see "
            "the agents-observability page of the EKS User Guide."
        )
        return

    telemetry = StrandsTelemetry()
    telemetry.setup_otlp_exporter()
    # The meter is what carries the GenAI metrics the dashboards read -- token usage and operation
    # duration. Traces alone leave every panel empty.
    telemetry.setup_meter(enable_otlp_exporter=True)
    log.info("telemetry exporting to %s", endpoint)


def trace_attributes(session_id: str) -> dict[str, str]:
    """The attributes every span of one turn carries, so a backend can group a conversation.

    `session.id` is the key both evaluation backends read. Langfuse groups traces into a session on
    it, and Strands Evals' Langfuse and CloudWatch providers fetch a conversation by it. AgentCore
    Evaluations' online config groups sessions on it too. AWS's guide for agents hosted outside
    AgentCore Runtime names it as required. Without it, every turn is its own trace with nothing
    joining them, and a session-level evaluator has nothing to grade.

    Set as a span attribute through Strands rather than only as OpenTelemetry baggage. Baggage
    propagates on outbound calls but is not written onto a span unless a baggage span processor is
    installed, and the reference agent installs none, so baggage alone reaches no backend.
    """
    return {"session.id": session_id}


POLICY_SESSION_HEADER = "x-amzn-bedrock-agentcore-policy-session-id"


def _policy_session_headers(session_id: str) -> dict:
    """The policy-session header a TEMPORAL policy needs on every gateway request, when it is on.

    AgentCore Gateway does not generate a policy session: once any temporal (Dogwood) policy is
    attached, a request without this header fails validation, and the session is what the policy's
    history is kept against. The agent's own conversation session is the natural one, so a rule like
    "an approval before a transfer" holds within one conversation. AGENT_POLICY_SESSIONS is set by
    the Agent resource when the platform enables temporal policies (gateway.policySessions); off, no
    header is sent. A turn with no session id (the startup probe) sends none either.
    """
    if not session_id or os.environ.get("AGENT_POLICY_SESSIONS", "").lower() not in ("1", "true", "yes", "on"):
        return {}
    return {"default_headers": {POLICY_SESSION_HEADER: session_id}}


def build_agent(session_id: str = "", user_id: str = "", person_token: str = "") -> tuple[Agent, str]:
    agent_name = _required("AGENT_NAME")

    gateway_url = _first_set(*GATEWAY_URL_VARS)
    if not gateway_url and IMAGE_MODEL_ROUTE == "bedrock-direct":
        model, route = build_direct_model()
        memory = agentcore_memory(agent_name, user_id, session_id) if session_id else None
        return _agent(agent_name, model, session_id, memory=memory, user_id=user_id, person_token=person_token), route
    if not gateway_url:
        sys.exit(
            "No model endpoint is set. Set one of "
            + ", ".join(GATEWAY_URL_VARS)
            + ". The Agent resource sets both to the same value when the platform has a gateway; "
            "outside the cluster, set one yourself. This image reaches models only through a "
            "gateway. On a platform with no gateway, deploy the agents/reasoning-direct image "
            "instead. Refusing to start rather than failing on the first turn."
        )

    # The model is addressed through the gateway, which is the whole of this agent's model
    # configuration. Note what is absent: no AWS region for Bedrock, no model ID, and no
    # credentials. The gateway selects the model, signs the call with the agent's own IAM role, and
    # applies the token budget and the content checks.
    #
    # That is why this uses an OpenAI-compatible client against the gateway rather than Strands'
    # Bedrock model provider. Calling Bedrock directly would work -- the agent's role permits it --
    # and would bypass the budget, the tool policy, the audit point and the content checks. The
    # network policy is what makes the bypass fail rather than succeed quietly: Bedrock is not a
    # reachable destination from an agent namespace, only the gateway is.
    #
    # How this agent authenticates to the gateway, which is the contract most easily got wrong and
    # which reports healthy when it is.
    #
    # Both gateways on this stack authenticate the caller on a JWT in Strict mode, and the token
    # travels in the Authorization header -- which is the header an OpenAI-compatible client builds
    # from api_key. AgentCore Gateway's own documentation shows exactly this: the gateway's auth
    # token passed as api_key.
    #
    # So the projected service account token IS the credential, not a placeholder. An agent that
    # sends a made-up api_key is refused for an unverifiable identity, and the symptom is a healthy
    # deployment whose every model call fails.
    #
    # It goes in api_key rather than through an httpx auth hook. Neither hook shape works: a sync
    # httpx.Client is rejected by the SDK at construction, and an httpx.AsyncClient is bound to the
    # event loop that created it and closed when that loop ends, so the turn after the first fails
    # with "the client has been closed". Both failures are visible only by making a call. Rotation
    # is handled by the api_key itself: a callable the SDK calls before every request (below).
    token_file = os.environ.get("AGENT_IDENTITY_TOKEN_FILE", "")
    static_key = _first_set(*GATEWAY_KEY_VARS)

    if token_file:
        api_key = read_gateway_token(token_file)
    elif static_key:
        # For running outside the cluster against a proxy that takes a static key. Both gateways on
        # this stack refuse one in Strict mode, which is why the token file wins when both are set.
        api_key = static_key
    else:
        sys.exit(
            "No gateway credential. Set AGENT_IDENTITY_TOKEN_FILE, which the Agent resource points "
            "at the projected token, or an API key for a proxy that takes one. Both gateways here "
            "authenticate in Strict mode, so starting without a credential means every model call "
            "is refused for an unverifiable identity."
        )

    model = _TextAsString(
        client_args={"base_url": gateway_url,
                     # The string is read once above so a missing token stops the agent at startup;
                     # each request then reads the file again.
                     "api_key": gateway_key_provider(token_file) if token_file else api_key,
                     **_policy_session_headers(session_id)},
        # The model name the gateway routes on. The gateway may override it, which is how model
        # selection and failover become gateway-side changes this code never sees.
        model_id=_first_set("AGENT_MODEL") or "bedrock-claude-sonnet",
        # NO SAMPLING PARAMETERS. Claude Sonnet 5.5 on Amazon Bedrock refuses temperature and top_p
        # alike ("`temperature` is deprecated for this model"), so a value set
        # here fails every call. The model's own default applies.
    )
    # Built only for a turn (a session id), never for the startup check in server.py: the store
    # connects to Postgres, and a memory tier that is down must not stop the agent serving.
    memory = (consolidation_memory(agent_name, gateway_url, api_key, user_id)
              or agentcore_memory(agent_name, user_id, session_id)) if session_id else None
    return _agent(agent_name, model, session_id, token_file=token_file, api_key=api_key, memory=memory, user_id=user_id, person_token=person_token), gateway_url


def build_direct_model():
    """Amazon Bedrock, called by this agent itself: the reasoning-direct image, with no gateway.

    WHAT THIS GIVES UP, which is why it is a separate image and not the default. The agent holds the
    credential it spends -- its own IAM role, delivered by Pod Identity -- and no point in the path
    sees the request: no per-agent token budget, no model failover, no tool policy, no single audit
    point beyond CloudTrail's record of the role's calls. What still holds is the boundary: the
    network policy permits bedrock-runtime in this Region and nothing else, and the role is scoped to
    the models the Agent lists in modelArns.

    AGENT_MODEL is a Bedrock model or inference profile id here, not a gateway route name. The Agent
    resource sets it from model.directModelId when the platform has no gateway.
    """
    from strands.models.bedrock import BedrockModel  # imported here: the gateway path never needs it

    region = _first_set("AWS_BEDROCK_REGION", "AWS_REGION", "AWS_DEFAULT_REGION")
    if not region:
        sys.exit("AWS_BEDROCK_REGION is not set. The Agent resource sets it when the platform has no gateway.")
    model_id = _required("AGENT_MODEL")
    log.warning(
        "no gateway endpoint: calling Amazon Bedrock directly in %s on this agent's own role "
        "(reasoning-direct image). No token budget, model failover or tool policy applies.",
        region,
    )
    # No temperature: Claude Sonnet 5.5 refuses it. See the gateway model above.
    return BedrockModel(model_id=model_id, region_name=region), f"bedrock-runtime.{region} (direct)"


# Rung 3 on the open source path, consolidation: Mem0 as a library, through mem0-strands.
#
# WHY A LIBRARY AND NOT THE MEM0 SERVER. The published server image is stale (one `latest` tag, behind
# the CVE fixes in its own source; see gitops/platform/open-source/alternatives/mem0-server), and as a
# library the extraction and embedding calls are this agent's own: the same projected token, the
# same gateway route and budget, the same audit line, the same role signing at Bedrock. There is no
# second service to expose, patch or authorize.
#
# WHAT EACH PIECE IS:
#   vector store  the pgvector tier (61-semantic-recall.yaml), one table per agent, mem0_<agent>.
#   login         `agent_memory`, read from Secrets Manager with this agent's own role. A pod in a
#                 Nitro sandbox takes no CSI volume, so nothing mounts it.
#   LLM           the gateway's /llm/<agent> route, for fact extraction and update decisions.
#   embedder      /llm/<agent>/embeddings, a second gateway backend serving the embedding model.
#   scope         agent_id = this agent; user_id = the verified caller, and beneath it the user that
#                 caller names (server.py), so one person's memories are not recalled for another and
#                 no caller reaches another's by naming the same user.
#
# THE TOKEN ROTATES; THE STORE IS KEPT. Building Mem0 opens a connection pool and may create the
# table, so it is built once per process and its two OpenAI clients are handed each turn's token,
# which is the attribute they read on every request.
_MEM0 = {"memory": None}
# MemoryManager runs extraction as a fire-and-forget task after a turn (the fact lands about 3 s
# after the reply). The agent, and with it the manager and the coordinator that holds that task,
# is built per turn and dropped when the turn ends, and asyncio holds only weak references to tasks
# -- so a manager is kept here until its extraction has finished.
_LIVE_MEMORY_MANAGERS: set = set()


def _extraction_pending(manager) -> bool:
    coordinator = getattr(manager, "_coordinator", None)
    if coordinator is None:
        return False
    return bool(getattr(coordinator, "_background", True))


def _memory_login(secret_arn: str) -> dict:
    import json

    import boto3

    region = secret_arn.split(":")[3]
    value = boto3.client("secretsmanager", region_name=region).get_secret_value(SecretId=secret_arn)
    login = json.loads(value["SecretString"])
    return {"user": login["username"], "password": login["password"]}


def _table_name(agent_name: str) -> str:
    return "mem0_" + "".join(c if c.isalnum() else "_" for c in agent_name.lower())


def mem0_config(agent_name: str, gateway_url: str, api_key: str, login: dict) -> dict:
    """The Mem0 OSS configuration for this agent: pgvector, and the gateway for both model calls."""
    dims = int(os.environ.get("AGENT_CONSOLIDATION_EMBEDDING_DIMS", "1024"))
    return {
        "vector_store": {
            "provider": "pgvector",
            "config": {
                "host": _required("AGENT_CONSOLIDATION_DB_HOST"),
                "port": 5432,
                "dbname": os.environ.get("AGENT_CONSOLIDATION_DB_NAME", "agentmemory"),
                "user": login["user"],
                "password": login["password"],
                "collection_name": _table_name(agent_name),
                "embedding_model_dims": dims,
            },
        },
        "llm": {
            "provider": "openai",
            "config": {
                "model": _first_set("AGENT_MODEL") or "bedrock-claude-sonnet",
                "openai_base_url": gateway_url,
                "api_key": api_key,
            },
        },
        "embedder": {
            "provider": "openai",
            "config": {
                # The gateway's embeddings backend names the model; this is what the request carries.
                "model": os.environ.get("AGENT_CONSOLIDATION_EMBEDDING_MODEL", "amazon.titan-embed-text-v2:0"),
                "openai_base_url": gateway_url,
                "api_key": api_key,
                "embedding_dims": dims,
            },
        },
        "history_db_path": os.path.join(os.environ.get("MEM0_DIR", "/tmp/mem0"), "history.db"),
    }


def adapt_for_gateway(memory) -> None:
    """Fit Mem0's two OpenAI-compatible calls to what the gateway's Bedrock translation accepts.

    Each fails as a 400 that Mem0 logs and the agent survives, so consolidation looks configured
    and stores nothing:

      EMBEDDINGS. Mem0 always sends `input` as a list. AgentGateway translates an OpenAI embeddings
      request to Titan, and Titan takes one string:
        failed to parse Embeddings request: Titan requires a single string input
      So a list is sent one string per request and the results re-assembled in order.

      JSON MODE. Mem0 asks for `response_format: json_object`. The gateway turns that into a Bedrock
      output schema of an open object, which Claude on Bedrock refuses:
        output_config.format.schema: For 'object' type, 'additionalProperties: true' is not supported
      So json_object is dropped. Mem0's prompts already ask for JSON, and it strips code fences and
      extracts the JSON itself before parsing, so nothing downstream depends on the flag.

      SAMPLING. Mem0 sends temperature AND top_p on every call (0.1 each by default). Claude
      Sonnet 4.5 took one or the other, and Claude Sonnet 5.5 takes neither:
        `temperature` is deprecated for this model.
      So both are dropped, and the model's default applies.
    """
    embeddings = memory.embedding_model.client.embeddings
    create_embedding = embeddings.create

    def one_string_per_request(**kwargs):
        texts = kwargs.get("input")
        if not isinstance(texts, list):
            return create_embedding(**kwargs)
        responses = [create_embedding(**{**kwargs, "input": text}) for text in texts]
        merged = responses[0]
        merged.data = [r.data[0] for r in responses]
        for index, item in enumerate(merged.data):
            item.index = index
        return merged

    embeddings.create = one_string_per_request

    completions = memory.llm.client.chat.completions
    create_completion = completions.create

    def as_bedrock_accepts(**kwargs):
        response_format = kwargs.get("response_format")
        if isinstance(response_format, dict) and response_format.get("type") == "json_object":
            kwargs.pop("response_format")
        kwargs.pop("temperature", None)
        kwargs.pop("top_p", None)
        return create_completion(**kwargs)

    completions.create = as_bedrock_accepts


# What the agent tells the person about long-term memory when consolidation is on (see _agent).
MEMORY_NOTE = (
    "What the person tells you is saved to long-term memory for them after each turn, and you can "
    "recall it in later conversations with your memory search tool. Don't say that you can't remember "
    "things between conversations. If they ask you to forget something, say that you can't delete "
    "memories yourself."
)


def consolidation_memory(agent_name: str, gateway_url: str, api_key: str, user_id: str = ""):
    """A MemoryManager over Mem0 for this turn, or None when consolidation is off or unavailable."""
    secret_arn = os.environ.get("AGENT_CONSOLIDATION_DB_SECRET_ARN", "").strip()
    if not secret_arn:
        return None
    try:
        from mem0 import Memory
        from mem0_strands import Mem0MemoryStore
        from mem0_strands.client import Mem0ServiceClient
        from strands.memory import InvocationTrigger, MemoryManager

        memory = _MEM0["memory"]
        if memory is None:
            os.makedirs(os.environ.get("MEM0_DIR", "/tmp/mem0"), exist_ok=True)
            memory = Memory.from_config(mem0_config(agent_name, gateway_url, api_key, _memory_login(secret_arn)))
            adapt_for_gateway(memory)
            _MEM0["memory"] = memory
            log.info("consolidation on: Mem0 on %s, table %s", os.environ.get("AGENT_CONSOLIDATION_DB_HOST"), _table_name(agent_name))
        for part in (memory.llm, memory.embedding_model):
            part.client.api_key = api_key

        store = Mem0MemoryStore(
            agent_id=agent_name,
            user_id=user_id or None,
            writable=True,
            # After every turn: this agent is rebuilt per turn, so the default (every five turns of
            # one agent object) would never fire.
            extraction={"trigger": [InvocationTrigger()]},
            client=Mem0ServiceClient(client=memory),
        )
        manager = MemoryManager(stores=[store])
    except Exception as exc:  # noqa: BLE001 -- serve without memory rather than refuse the turn
        log.warning("consolidation unavailable (%s: %s); serving this turn without it", type(exc).__name__, exc)
        return None

    for kept in list(_LIVE_MEMORY_MANAGERS):
        if not _extraction_pending(kept):
            _LIVE_MEMORY_MANAGERS.discard(kept)
    _LIVE_MEMORY_MANAGERS.add(manager)
    return manager


# CONSOLIDATION ON THE AWS SERVICES PATH: AgentCore memory. The platform creates one memory with
# its strategies (consolidation_strategies) and hands the agent AGENT_MEMORY_ID and the strategies'
# namespace templates in AGENT_MEMORY_NAMESPACES. Without this store the reference agent never
# calls it: the memory phase passes only because exercise.sh writes its own event, and a person's
# fact told through the chat UI is not recalled in the next conversation.
#
#   write   each turn's user and assistant text as one conversational event (CreateEvent); the
#           memory's strategies extract records from it on the service side, about a minute later.
#   read    RetrieveMemoryRecords with namespacePath -- every record under the person's own part of
#           each template, so a record a strategy wrote under /agents/{actorId}/{sessionId} is found
#           from any later session. An exact namespace would find only the current session's.
#   actor   a digest of the verified user_id (server.py: the caller's subject, and beneath it the
#           user it names), which fits AgentCore's actorId and namespace patterns and keeps the
#           person's identity out of the namespace.
def _agentcore_actor(user_id: str) -> str:
    import hashlib

    return "u" + hashlib.sha256((user_id or "anonymous").encode()).hexdigest()[:40]


def _agentcore_session(session_id: str) -> str:
    import re

    cleaned = re.sub(r"[^a-zA-Z0-9_-]", "-", session_id).strip("-_")
    return cleaned[:100] or "session"


class AgentCoreMemoryStore:
    """A Strands memory store over AgentCore memory: server-side extraction, per-person retrieval."""

    name = "agentcore"
    description = "Long-term memory of what this person has told the agent in earlier conversations."
    max_search_results = 5
    writable = True

    def __init__(self, memory_id: str, actor_id: str, session_id: str, namespace_paths: list[str], region: str):
        import boto3
        from strands.memory import InvocationTrigger

        self.memory_id, self.actor_id, self.session_id = memory_id, actor_id, session_id
        self.namespace_paths = namespace_paths
        self.extraction = {"trigger": [InvocationTrigger()]}
        self._client = boto3.client("bedrock-agentcore", region_name=region)

    async def add_messages(self, messages, context=None):
        import asyncio
        from datetime import datetime, timezone

        payload = []
        for m in messages:
            text = " ".join(b.get("text", "") for b in m.get("content", []) if isinstance(b, dict) and b.get("text")).strip()
            if text and m.get("role") in ("user", "assistant"):
                payload.append({"conversational": {"role": m["role"].upper(), "content": {"text": text[:9000]}}})
        if not payload:
            return None
        return await asyncio.to_thread(
            self._client.create_event, memoryId=self.memory_id, actorId=self.actor_id,
            sessionId=self.session_id, eventTimestamp=datetime.now(timezone.utc), payload=payload,
        )

    async def search(self, query, options=None):
        import asyncio
        from strands.memory.types import MemoryEntry

        top_k = int((options or {}).get("max_search_results") or self.max_search_results)
        entries = []
        for path in self.namespace_paths:
            resp = await asyncio.to_thread(
                self._client.retrieve_memory_records, memoryId=self.memory_id, namespacePath=path,
                searchCriteria={"searchQuery": query or "what do I know about this person", "topK": top_k},
            )
            for r in resp.get("memoryRecordSummaries", []):
                text = (r.get("content") or {}).get("text", "")
                if text:
                    entries.append(MemoryEntry(content=text, metadata={"namespaces": r.get("namespaces"), "score": r.get("score")}))
        return entries[:top_k]


def agentcore_namespace_paths(templates: str, actor_id: str) -> list[str]:
    """Each strategy template's part up to the first placeholder after {actorId}, with the actor filled
    in: /agents/{actorId}/{sessionId} -> /agents/u1a2b.../. A template that names no {actorId} pools
    every person's records, so it is not searched for one person."""
    paths = []
    for t in (x.strip() for x in templates.split(",")):
        if "{actorId}" not in t:
            if t:
                log.warning("memory namespace %s names no {actorId}; not searched per person", t)
            continue
        head = t.replace("{actorId}", actor_id).split("{", 1)[0]
        paths.append(head if head.endswith("/") else head.rsplit("/", 1)[0] + "/")
    return list(dict.fromkeys(paths))


def agentcore_memory(agent_name: str, user_id: str, session_id: str):
    """A MemoryManager over AgentCore memory for this turn, or None when it is not configured."""
    memory_id = os.environ.get("AGENT_MEMORY_ID", "").strip()
    if not memory_id:
        return None
    try:
        from strands.memory import MemoryManager

        actor = _agentcore_actor(user_id)
        paths = agentcore_namespace_paths(os.environ.get("AGENT_MEMORY_NAMESPACES", ""), actor)
        region = _first_set("AWS_REGION", "AWS_DEFAULT_REGION") or None
        store = AgentCoreMemoryStore(memory_id, actor, _agentcore_session(session_id), paths, region)
        manager = MemoryManager(stores=[store])
    except Exception as exc:  # noqa: BLE001 -- serve without memory rather than refuse the turn
        log.warning("AgentCore memory unavailable (%s: %s); serving this turn without it", type(exc).__name__, exc)
        return None
    for kept in list(_LIVE_MEMORY_MANAGERS):
        if not _extraction_pending(kept):
            _LIVE_MEMORY_MANAGERS.discard(kept)
    _LIVE_MEMORY_MANAGERS.add(manager)
    return manager


# THE CONVERSATION, SAVED BETWEEN TURNS. This agent is rebuilt for every turn, so without a session
# manager a second message in the same session starts from nothing. Strands' session managers save
# the agent's messages and state after each turn and load them when an agent is built with the same
# session id.
#
#   CHECKPOINT_BUCKET set (enable_checkpoints)   S3SessionManager, under this agent's own prefix,
#                                                which its IAM role is scoped to. Any replica of a
#                                                Deployment, or a restarted pod, continues it.
#   AGENT_WORKSPACE_PERSISTENT=true              FileSessionManager on /workspace: a Sandbox with
#                                                a workspace volume keeps its sessions across
#                                                suspend and resume, with no AWS call.
#   neither                                      no saved conversation; each turn stands alone.
#
# WHOSE SESSION. The key is a digest of the VERIFIED caller (server.py passes it as user_id) and the
# session id the request names, never the session id alone: a session id is the caller's to choose,
# so keyed on it alone, one caller could load another's conversation by guessing it.
def session_key(user_id: str, session_id: str) -> str:
    import hashlib

    return hashlib.sha256(f"{user_id}\0{session_id}".encode()).hexdigest()[:40]


def session_manager(user_id: str, session_id: str):
    if not session_id:
        return None
    key = session_key(user_id, session_id)
    bucket = os.environ.get("CHECKPOINT_BUCKET", "").strip()
    if bucket:
        from strands.session import S3SessionManager

        prefix = os.environ.get("CHECKPOINT_PREFIX", "").strip().rstrip("/") + "/sessions"
        region = _first_set("AWS_REGION", "AWS_DEFAULT_REGION") or None
        return S3SessionManager(session_id=key, bucket=bucket, prefix=prefix, region_name=region)
    if os.environ.get("AGENT_WORKSPACE_PERSISTENT", "").lower() == "true":
        from strands.session import FileSessionManager

        return FileSessionManager(session_id=key, storage_dir=os.environ.get("AGENT_SESSION_DIR", "/workspace/.sessions"))
    return None


def _mcp_person_token(token: str) -> str:
    """The person's token to send the MCP endpoint, or an empty string.

    With AGENT_MCP_PERSON_TOKEN=access (person_access_delegated_token), only an access token: the
    gateway exchanges it with this agent's own token for one delegated token, and the exchange takes
    an access token as its subject, so an ID token there would fail every MCP call of the turn.
    token_use is read without verifying: a routing choice, not a trust decision -- the gateway and
    the tool verify whatever is sent.
    """
    if not token or os.environ.get("AGENT_MCP_PERSON_TOKEN", "any").strip().lower() != "access":
        return token
    return token if token_use(token) == "access" else ""


def _delegated_person_token(token: str) -> str:
    """A delegated token for the person's tools, from AgentCore Identity, or an empty string.

    With AGENT_PERSON_DELEGATION_PROVIDER set (person_access_delegated_token on the AWS services
    path), the agent never sends a tool the person's own token. It binds the person's access token
    to its own workload identity, then asks its own credential provider for an on-behalf-of token.
    The pool signs one token with sub the person, aud the tools and act naming this agent's client.

    Cognito decides three request details: `audiences` must name the tools, or the token has no aud;
    the subject token type must be access_token, because Cognito refuses AgentCore's default (jwt);
    and the one scope AgentCore requires is blank, because Cognito refuses any scope named in an
    exchange. Any failure returns empty, so the tool refuses rather than receiving the raw token.
    """
    provider = os.environ.get("AGENT_PERSON_DELEGATION_PROVIDER", "").strip()
    workload = os.environ.get("AGENT_PERSON_WORKLOAD", "").strip()
    audience = os.environ.get("AGENT_PERSON_DELEGATED_AUDIENCE", "").strip()
    if not (token and provider and workload and audience):
        return ""
    try:
        import boto3

        identity = boto3.client("bedrock-agentcore", region_name=_first_set("AWS_REGION", "AWS_DEFAULT_REGION") or None)
        wat = identity.get_workload_access_token_for_jwt(workloadName=workload, userToken=token)["workloadAccessToken"]
        return identity.get_resource_oauth2_token(
            workloadIdentityToken=wat,
            resourceCredentialProviderName=provider,
            oauth2Flow="ON_BEHALF_OF_TOKEN_EXCHANGE",
            scopes=[" "],
            audiences=[audience],
            customParameters={"subject_token_type": "urn:ietf:params:oauth:token-type:access_token"},
        )["accessToken"]
    except Exception as exc:  # noqa: BLE001 -- no delegated token means the tool refuses, which is the safe outcome
        log.warning("no delegated token for the person's tools (%s: %s); the tools will refuse", type(exc).__name__, exc)
        return ""


def _agent(agent_name: str, model, session_id: str, token_file: str = "", api_key: str = "", memory=None, user_id: str = "", person_token: str = "") -> Agent:
    """The agent around a model. token_file and api_key are the gateway credential, which the MCP
    client below presents too; both are empty on the direct route, where there is no gateway."""
    # Empty is treated as unset, not as an empty prompt. The Agent resource sets this variable
    # unconditionally because kro cannot omit one, so an agent that declares no systemPrompt arrives
    # with AGENT_SYSTEM_PROMPT="" -- and a plain os.environ.get default would be overridden by it,
    # leaving the agent with no system prompt at all while looking configured.
    system_prompt = os.environ.get("AGENT_SYSTEM_PROMPT", "").strip() or (
        "You are a research assistant running on Amazon EKS. Answer from the tools and context you "
        "are given. If you cannot support a claim from them, say so rather than guessing."
    )

    # The gateway's tools.
    #
    # THE GATEWAY'S AGGREGATED MCP ENDPOINT IS THE TOOL CATALOGUE. It is loaded at turn time rather
    # than listed here, so the catalogue stays a reviewable object in Git (the gateway's targets and
    # Cedar policies) and adding a tool does not mean shipping the agent again. The gateway applies
    # its tool policy on every call, so a tool this agent should not reach is refused there -- and
    # with a principal-scoped Cedar policy it is not even listed.
    #
    # With no tools registered, no agent turn reaches a gateway tool: asked to look up an order, the
    # model writes "We need to use lookup_order tool" and stops, and the TOOL_CALL evaluator has
    # nothing it can grade. AGENT_GATEWAY_TOOLS=off registers none.
    #
    # The credential is the same projected token as the model call, or the MCP-audience token when
    # the Agent sets mcpAudience and reaches an in-cluster server directly.
    tools = []
    # With the person's own authority (person_access.py): tools that use the person's AWS
    # permissions, present only for an ID token with the person role configured.
    tools += person_tools(person_token)
    mcp_url = _first_set("AGENT_MCP_URL")
    if mcp_url and os.environ.get("AGENT_GATEWAY_TOOLS", "on").lower() not in ("off", "0", "false"):
        from strands.tools.mcp import MCPClient

        mcp_token_file = _first_set("AGENT_MCP_TOKEN_FILE") or token_file
        # Read once so a missing token fails here; TokenFileAuth then reads it per request, because
        # a tool call late in a long turn would otherwise present a token that has expired.
        mcp_key = read_gateway_token(mcp_token_file) if mcp_token_file else api_key
        tools.append(MCPClient(url=mcp_url, auth_provider=TokenFileAuth(mcp_token_file) if mcp_token_file else None, headers={
            **({} if mcp_token_file else {"Authorization": f"Bearer {mcp_key}"}),
            **_policy_session_headers(session_id).get("default_headers", {}),
            # The person's own token, for a tool that answers only for that person. The agent's
            # credential above still says who is calling; this says who the call is for.
            # With the AgentCore exchange (AWS services path), the delegated token instead, and the
            # person's own token not at all.
            **(({DELEGATED_TOKEN_HEADER: d} if (d := _delegated_person_token(_mcp_person_token(person_token))) else {})
               if os.environ.get("AGENT_PERSON_DELEGATION_PROVIDER", "").strip()
               else ({PERSON_TOKEN_HEADER: mcp_person} if (mcp_person := _mcp_person_token(person_token)) else {})),
        }))

    # SAY WHAT IS KEPT. With consolidation on, the platform extracts what the person says and stores it
    # for them after every turn; the model sees only a search tool, so without this it tells people
    # "I can't save that permanently" while their fact is being stored.
    # Appended to any prompt, the platform team's own included, because it is a fact about this
    # deployment rather than a choice of persona.
    if memory is not None:
        system_prompt = system_prompt + "\n\n" + MEMORY_NOTE

    try:
        saved = session_manager(user_id, session_id)
    except Exception as exc:  # noqa: BLE001 -- a store that is down must not refuse the turn
        log.warning("saved session unavailable (%s: %s); this turn starts without history", type(exc).__name__, exc)
        saved = None

    def build(with_tools: list) -> Agent:
        return Agent(
            model=model,
            system_prompt=system_prompt,
            tools=with_tools,
            # The agent's name reaches the telemetry as the service name, so a trace is attributable
            # to one agent without the platform team correlating it.
            name=agent_name,
            # Empty for the startup probe in server.py, which builds an agent it never runs.
            trace_attributes=trace_attributes(session_id) if session_id else None,
            memory_manager=memory,
            # One saved conversation per caller and session; see session_manager above. The agent id
            # is the agent's name, so one session's store can hold several agents' histories apart.
            agent_id=agent_name,
            session_manager=saved,
        )

    # A TOOL SURFACE THAT IS NOT THERE IS NOT A REASON TO REFUSE TO SERVE. The MCP client connects
    # when the agent is built, so a gateway with no MCP server behind /mcp (503) -- the open source
    # path's default until an MCP server is deployed -- would fail the startup build in server.py and
    # crash-loop every reference agent. The agent is built again without the
    # gateway's tools and says so; it is rebuilt per turn, so the tools appear once the surface does.
    try:
        return build(tools)
    except Exception as exc:  # noqa: BLE001 -- any MCP connect failure
        # AGENT_TOOLS_REQUIRED=true: an agent that is useless without its tools refuses instead.
        required = os.environ.get("AGENT_TOOLS_REQUIRED", "").lower() in ("1", "true", "yes", "on")
        if required or not any(type(t).__name__ == "MCPClient" for t in tools):
            raise
        log.warning("gateway tools unavailable at %s (%s); serving without them", mcp_url, type(exc).__name__)
        return build([t for t in tools if type(t).__name__ != "MCPClient"])


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )

    agent_name = os.environ.get("AGENT_NAME", "unknown")
    setup_telemetry()
    # One CLI run is one session. SESSION_ID lets a caller join several runs into one conversation.
    agent, gateway_url = build_agent(session_id=os.environ.get("SESSION_ID", "") or str(uuid.uuid4()))

    # Where state goes, and why neither of these is in the pod.
    #
    # Session state between turns belongs in the cache the platform runs, which is also what lets
    # this agent be load balanced -- an agent holding its session in memory needs either one replica
    # or affinity, and affinity does not work for MCP clients because they are not browsers and need
    # not carry a cookie.
    #
    # Checkpoints go to the agent's own prefix in the shared bucket. The prefix arrives as
    # configuration rather than being chosen here: the IAM role scopes this agent to exactly it, so
    # an agent that constructed its own path would get AccessDenied, and passing it in means the
    # model never sees it as something it can set.
    session_endpoint = os.environ.get("SESSION_STATE_ENDPOINT", "")
    checkpoint_bucket = os.environ.get("CHECKPOINT_BUCKET", "")
    checkpoint_prefix = os.environ.get("CHECKPOINT_PREFIX", "")

    log.info(
        "agent %s ready: gateway=%s session_state=%s checkpoints=%s",
        agent_name,
        gateway_url,
        session_endpoint or "none (in-memory, single replica only)",
        f"s3://{checkpoint_bucket}/{checkpoint_prefix}" if checkpoint_bucket else "none",
    )

    # One turn from argv, or a prompt from stdin. A real agent serves ingress or drains a
    # queue; this stops here because what is being demonstrated is the wiring above, and an HTTP
    # server would add a framework choice that has nothing to do with it.
    #
    # To serve traffic, put this behind the framework you already use and set expose: cluster or
    # expose: ingress on the Agent resource.
    prompt = " ".join(sys.argv[1:]) or sys.stdin.read().strip()
    if not prompt:
        # NO PROMPT IN A POD MEANS WAIT, NOT EXIT. An Agent with `expose: none` runs this CLI as its
        # container's process; exiting makes the pod Completed and its Sandbox restart it in a loop,
        # and `kubectl exec` then finds no container to run a turn in. Idle
        # until the kubelet stops the pod; a turn is
        #   kubectl -n <ns> exec <pod> -- python /app/app.py "<prompt>"
        # AGENT_ONE_SHOT=true exits instead, for a Job or a laptop.
        if os.environ.get("AGENT_ONE_SHOT", "").lower() in ("1", "true", "yes", "on"):
            log.info("no prompt given; exiting (AGENT_ONE_SHOT). Pass one as an argument or on stdin.")
            return
        import signal  # noqa: PLC0415
        import threading  # noqa: PLC0415

        stop = threading.Event()
        signal.signal(signal.SIGTERM, lambda *_: stop.set())
        log.info('no prompt given; idling. Run a turn with: python /app/app.py "<prompt>"')
        stop.wait()
        return

    result = agent(prompt)
    print(result)


if __name__ == "__main__":
    main()
