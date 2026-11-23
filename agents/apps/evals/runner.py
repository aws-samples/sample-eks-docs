"""The evaluation runner: Strands Evals, with the judge reached through this stack's gateway.

    python runner.py online        grade a sample of recent sessions from the trace backend
    python runner.py experiment    run the declared test cases against deployed agents, then grade

Both modes grade with the same evaluators, declared once in the config file the chart renders, so
what "good" means is one reviewable list rather than one definition per backend.

WHERE THE GRADES GO, by backend:

  langfuse   Scores on the Langfuse session, named strands.<Evaluator>, with the judge's reason as
             the comment. The runner takes the place of Langfuse-native evaluators: those call the
             judge from inside Langfuse, over an LLM connection that holds one static key, and this
             stack's gateway accepts only a short-lived projected service account token, so it
             refuses every call they make. This runner is a
             pod with its own token, which the gateway can verify.
  agentcore  CloudWatch Logs, in AgentCore Evaluations' own result format, through Strands Evals'
             built-in writer: /aws/bedrock-agentcore/evaluations/results/<name>. The results then
             appear in the CloudWatch GenAI Observability dashboard beside the managed online
             evaluation's. Online mode is refused on this backend, because AgentCore Evaluations'
             online config already grades live traffic there.

WHAT FAILS THE RUN. A case that could not be run -- the agent refused or was unreachable, or its
trace never reached the backend -- is an EXECUTION failure, not a grade. Strands Evals records a
task error as score 0 with test_pass false, which would publish a zero against a session nobody
graded and let a broken agent look like a merely bad one. So those cases are counted separately,
never published as scores, and exit the run with status 2. A completed run whose pass rate is below
experiment.minPassRate exits 1, which is what makes it usable as a release gate.

The judge holds no model credential. Its token is a projected service account token for the
gateway's audience, read from a file at each run because the kubelet rewrites that file in place.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import pathlib
import sys
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

import httpx
import yaml

log = logging.getLogger("agent-evals")

CONFIG_PATH = os.environ.get("EVALS_CONFIG", "/etc/agent-evals/config.yaml")

# Scores this runner writes are named with this prefix, so they are distinguishable from human
# annotations and from any other evaluator writing to the same project.
SCORE_PREFIX = "strands."

# Labels an evaluator returns when there was nothing to judge -- a tool-level evaluator on a turn
# that called no tool. Publishing a number for those would average a non-event into the metric.
NOT_APPLICABLE = {"NOT_APPLICABLE", "N/A", "NA"}

# Experiment sessions carry this prefix, so online grading -- which reads every quiet session in the
# project -- does not grade the release gate's own turns a second time.
EXPERIMENT_SESSION_PREFIX = "evals-"

EXIT_OK = 0
EXIT_BELOW_THRESHOLD = 1
EXIT_EXECUTION_FAILED = 2
EXIT_CONFIG = 3


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------


class ConfigError(Exception):
    pass


def load_config(path: str = CONFIG_PATH) -> dict[str, Any]:
    try:
        cfg = yaml.safe_load(pathlib.Path(path).read_text()) or {}
    except OSError as exc:
        raise ConfigError(f"cannot read the evaluation config at {path}: {exc}") from exc
    backend = cfg.get("backend")
    if backend not in ("langfuse", "agentcore"):
        raise ConfigError(f"backend must be langfuse or agentcore, got {backend!r}")
    if not (cfg.get("judge") or {}).get("baseUrl"):
        raise ConfigError(
            "judge.baseUrl is empty. It is the gateway's OpenAI-compatible endpoint for the judge; "
            "without it there is nothing to grade with."
        )
    if not cfg.get("evaluators") and not cfg.get("rubrics"):
        raise ConfigError("no evaluators and no rubrics are declared, so a run would grade nothing")
    return cfg


def read_token(token_file: str) -> str:
    """Read a projected service account token. Read per use: the kubelet rewrites it in place."""
    try:
        token = pathlib.Path(token_file).read_text().strip()
    except OSError as exc:
        raise ConfigError(f"cannot read the token at {token_file}: {exc}") from exc
    if not token:
        raise ConfigError(f"the token at {token_file} is empty")
    return token


# ---------------------------------------------------------------------------
# The judge and the evaluators
# ---------------------------------------------------------------------------


def build_judge(judge_cfg: dict[str, Any]):
    """An OpenAI-compatible model on the gateway's judge route, signed with this pod's token.

    A temperature is sent only when the judge config sets one. Zero is what a grader wants -- one
    that is not reproducible cannot tell a team whether a release regressed or the judge changed its
    mind -- but Claude Sonnet 5.5 on Amazon Bedrock refuses any temperature, so the default judge
    sends none and relies on the rubric and a numerical scale for consistency.
    """
    from strands.models.openai import OpenAIModel  # noqa: PLC0415

    # A TEMPORAL POLICY ON THE GATEWAY rejects every request without a policy session ("sessionId is
    # required when temporal policies are enabled"), including the judge's. One
    # session per runner process: the judge's calls have no history a policy should relate.
    headers = {}
    if judge_cfg.get("policySessions"):
        import uuid  # noqa: PLC0415

        headers = {"default_headers": {"x-amzn-bedrock-agentcore-policy-session-id": f"judge-{uuid.uuid4().hex[:16]}"}}
    return OpenAIModel(
        client_args={
            "base_url": judge_cfg["baseUrl"],
            "api_key": read_token(judge_cfg.get("tokenFile", "/var/run/secrets/eks-agents/gateway/token")),
            **headers,
        },
        model_id=judge_cfg.get("model") or "judge",
        params=({"temperature": float(judge_cfg["temperature"])} if judge_cfg.get("temperature") is not None else {}),
    )


def build_evaluators(names: list[str], rubrics: dict[str, Any], judge) -> list:
    """Built-in evaluators by class name, plus OutputEvaluator rubrics a team writes itself.

    Each built-in runs at its own grain -- Session, Trace or ToolCall -- which Strands Evals
    declares on the class. That replaces the old chart's `level` field, which was an abstraction
    this repository invented over Langfuse rule filters and not a property of any evaluator.
    """
    import strands_evals.evaluators as ev  # noqa: PLC0415

    evaluators = []
    for name in names or []:
        cls_name = name if name.endswith("Evaluator") else f"{name}Evaluator"
        cls = getattr(ev, cls_name, None)
        if cls is None or not isinstance(cls, type) or not issubclass(cls, ev.Evaluator):
            raise ConfigError(f"unknown evaluator {name!r}; expected a class in strands_evals.evaluators")
        evaluators.append(cls(model=judge))
    for name, spec in (rubrics or {}).items():
        rubric = (spec or {}).get("rubric", "").strip()
        if not rubric:
            raise ConfigError(f"rubric {name!r} has no rubric text")
        evaluators.append(ev.OutputEvaluator(rubric=rubric, model=judge, name=name))
    return evaluators


# ---------------------------------------------------------------------------
# Trace backends
# ---------------------------------------------------------------------------


def isolate_tracing() -> None:
    """Keep the runner's own spans out of the trace backend it is grading.

    Strands Evals opens spans around every case and every judge call, and each evaluator runs a
    Strands Agent that opens more. The Langfuse SDK attaches its exporter to whatever global tracer
    provider exists, so left alone every judge call would land in Langfuse as a trace of its own,
    beside the agent traffic it is grading.

    So the global provider is an SDK provider with no exporter -- Strands Evals still gets real
    trace ids, nothing leaves the process -- and the Langfuse client is built first with a PRIVATE
    provider. The SDK keeps one resource manager per public key, so the client Strands Evals'
    LangfuseProvider builds later reuses that private provider rather than the global one.
    """
    from opentelemetry import trace as otel_trace  # noqa: PLC0415
    from opentelemetry.sdk.trace import TracerProvider  # noqa: PLC0415

    if not isinstance(otel_trace.get_tracer_provider(), TracerProvider):
        otel_trace.set_tracer_provider(TracerProvider())


def langfuse_keys() -> tuple[str, str]:
    """The Langfuse project keys, from files when the chart mounts them, else the environment.

    Files are what the chart does: a Secret mounted read-only at LANGFUSE_KEYS_DIR, rather than
    environment variables, which any process in the pod can read from /proc and which a crash dump
    or a debug print carries. The environment is kept for running outside the cluster.
    """
    keys_dir = os.environ.get("LANGFUSE_KEYS_DIR", "").strip()
    if keys_dir:
        d = pathlib.Path(keys_dir)
        try:
            return ((d / "public-key").read_text().strip(), (d / "secret-key").read_text().strip())
        except OSError as exc:
            raise ConfigError(f"cannot read the Langfuse keys from {keys_dir}: {exc}") from exc
    return os.environ.get("LANGFUSE_PUBLIC_KEY", ""), os.environ.get("LANGFUSE_SECRET_KEY", "")


def langfuse_client():
    from langfuse import Langfuse  # noqa: PLC0415
    from opentelemetry.sdk.trace import TracerProvider  # noqa: PLC0415

    return Langfuse(
        public_key=langfuse_keys()[0],
        secret_key=langfuse_keys()[1],
        host=os.environ.get("LANGFUSE_HOST"),
        tracer_provider=TracerProvider(),
    )


def _parse_io(value):
    """v2 returns input and output as raw strings; the converter expects what the v3 SDK returned."""
    if isinstance(value, str):
        try:
            return json.loads(value)
        except ValueError:
            return value
    return value


def _parse_time(value):
    if isinstance(value, str) and value:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    return value


def langfuse_v4_provider(lookback_days: float = 7.0, http=None):
    """Strands Evals' LangfuseProvider, reading through Langfuse v4's Observations API v2.

    WHY THIS EXISTS. The Langfuse chart this stack pins (2.2.3) runs Langfuse server 4.x in its
    default `events_only` mode, where the v3 read endpoints are gone: GET /api/public/traces and
    /api/public/sessions answer 404 "This endpoint is not available on deployments running in
    Langfuse v4 events_only mode". Strands Evals 1.9.0's LangfuseProvider reads through exactly
    those (its [langfuse] extra pins the SDK below 4), so against this Langfuse it fetches nothing.
    Langfuse 4.75.0 behaves this way.

    So this keeps everything of LangfuseProvider except the two fetches: observations come from
    GET /api/public/v2/observations filtered by sessionId, grouped by traceId, and adapted to the
    attribute names the provider's own span converter reads. The conversion -- which observation is
    an agent invocation, an inference or a tool call -- stays Strands Evals' code. This is the
    extension point Strands Evals documents for a backend it does not cover (subclass and implement
    the fetch), not a fork of its mapping.
    """
    from types import SimpleNamespace  # noqa: PLC0415

    from strands_evals.providers import LangfuseProvider  # noqa: PLC0415

    host = os.environ.get("LANGFUSE_HOST", "").rstrip("/")
    auth = langfuse_keys()
    client = http or httpx.Client(base_url=host, auth=auth, timeout=60.0)

    def observations(**params) -> list[dict]:
        now = datetime.now(timezone.utc)
        params.setdefault("fromStartTime", (now - timedelta(days=lookback_days)).isoformat())
        params.setdefault("toStartTime", (now + timedelta(minutes=5)).isoformat())
        params.setdefault("limit", 1000)
        rows, cursor = [], None
        while True:
            q = dict(params, **({"cursor": cursor} if cursor else {}))
            r = client.get("/api/public/v2/observations", params=q)
            r.raise_for_status()
            body = r.json()
            rows += body.get("data") or []
            cursor = (body.get("meta") or {}).get("cursor")
            # An empty page does not mean the end on this API; only an absent cursor does.
            if not cursor:
                return rows

    class LangfuseV4Provider(LangfuseProvider):
        def __init__(self):
            # NOT super().__init__(): that builds a Langfuse SDK client, and the SDK keeps one
            # resource manager per public key, attached to whatever tracer provider is global at
            # the time. Built before the runner's own score client, it would put the SDK's
            # exporter on the global provider and send every judge call to Langfuse as a trace.
            # Reads here go through `client` above, so the SDK client is not needed at all.
            self._client = None
            self._request_options = {}
            self._rows_by_trace: dict[str, list] = {}

        def _fetch_traces_for_session(self, session_id: str) -> list:
            self._rows_by_trace = {}
            for row in observations(sessionId=session_id, fields="core,basic,io,metadata"):
                self._rows_by_trace.setdefault(row.get("traceId"), []).append(row)
            return [SimpleNamespace(id=tid) for tid in self._rows_by_trace]

        def _fetch_observations(self, trace_id: str) -> list:
            return [SimpleNamespace(
                id=r.get("id"),
                trace_id=r.get("traceId"),
                parent_observation_id=r.get("parentObservationId"),
                type=r.get("type"),
                name=r.get("name"),
                input=_parse_io(r.get("input")),
                output=_parse_io(r.get("output")),
                metadata=r.get("metadata") or {},
                start_time=_parse_time(r.get("startTime")),
                end_time=_parse_time(r.get("endTime")),
            ) for r in self._rows_by_trace.get(trace_id, [])]

        def quiet_sessions(self, from_ts: datetime, to_ts: datetime) -> list[str]:
            """Sessions whose LAST root observation started in [from_ts, to_ts).

            v4 has no session listing, so this reads root observations from from_ts to now and
            keeps a session only if nothing in it started after to_ts -- so a session still in
            progress is left for a later run, and each session is graded once, when it goes quiet.
            """
            last: dict[str, datetime] = {}
            # "basic", not just "core": sessionId is in the basic field group, and a row fetched
            # with core alone has no sessionId -- every session then looks absent.
            for row in observations(isRootObservation="true", fields="core,basic",
                                    fromStartTime=from_ts.isoformat(),
                                    toStartTime=datetime.now(timezone.utc).isoformat()):
                sid, ts = row.get("sessionId"), _parse_time(row.get("startTime"))
                if sid and ts and (sid not in last or ts > last[sid]):
                    last[sid] = ts
            return sorted(sid for sid, ts in last.items() if from_ts <= ts < to_ts)

    return LangfuseV4Provider()


def aws_spans_provider(region: str | None):
    """A Strands Evals trace provider over CloudWatch's aws/spans, for agents that run on EKS.

    WHY NOT CloudWatchProvider. It reads AgentCore RUNTIME-style event LOG records -- prompts and
    responses as OTLP log bodies keyed by attributes.session.id -- from the agent's log group, and
    uses aws/spans only for parent links. An agent on EKS exporting through ADOT puts its GenAI
    content on the SPANS as span events (gen_ai.user.message, gen_ai.choice), and its log group
    holds no record with a session id at all. A turn's spans are in aws/spans about 30 s after the
    call while none of the log group's records has session.id, so a provider reading the log group
    fails every case with "never reached the trace backend". Passing aws/spans
    to CloudWatchProvider instead fails in its parser, which drops events embedded on a span.

    So this reads the spans themselves and hands them to Strands' own in-memory mapper, which
    consumes span events, in the shape of the OpenTelemetry ReadableSpan it expects.
    """
    from types import SimpleNamespace as NS  # noqa: PLC0415

    from strands_evals.mappers.strands_in_memory_session_mapper import StrandsInMemorySessionMapper  # noqa: PLC0415
    from strands_evals.providers import CloudWatchProvider  # noqa: PLC0415
    from strands_evals.providers.exceptions import SessionNotFoundError  # noqa: PLC0415
    from strands_evals.types.evaluation import TaskOutput  # noqa: PLC0415

    legacy_events = {"gen_ai.user.message", "gen_ai.system.message", "gen_ai.assistant.message", "gen_ai.choice", "gen_ai.tool.message"}

    def as_span(d: dict) -> Any:
        attrs = dict(d.get("attributes") or {})
        # MIXED CONVENTIONS. The exported spans carry gen_ai.provider.name, which makes the mapper
        # read them as the latest GenAI conventions and look for operation-details events -- while
        # their events are the legacy gen_ai.user.message / gen_ai.choice. The prompt and response
        # then map to empty strings and a correctness grade fails on a right answer. With legacy
        # events present, drop the marker so the mapper reads what is actually there.
        if any((e.get("name") or "") in legacy_events for e in d.get("events") or []):
            attrs.pop("gen_ai.provider.name", None)
        return NS(
            name=d.get("name", ""),
            attributes=attrs,
            events=[NS(name=e.get("name", ""), attributes=e.get("attributes") or {}, timestamp=int(e.get("timeUnixNano", 0)))
                    for e in d.get("events") or []],
            context=NS(trace_id=int(d["traceId"], 16), span_id=int(d["spanId"], 16)),
            parent=NS(span_id=int(d["parentSpanId"], 16)) if d.get("parentSpanId") else None,
            start_time=int(d.get("startTimeUnixNano", 0)),
            end_time=int(d.get("endTimeUnixNano", 0)),
        )

    class AwsSpansProvider(CloudWatchProvider):
        def get_evaluation_data(self, session_id: str):
            records = self._run_logs_insights_query(
                f"fields @message | filter attributes.session.id = '{session_id}' | sort @timestamp asc | limit 10000"
            )
            spans = sorted((as_span(r) for r in records if r.get("spanId") and r.get("traceId")), key=lambda x: x.start_time)
            if not spans:
                raise SessionNotFoundError(f"aws/spans: no spans for session_id='{session_id}'")
            session = StrandsInMemorySessionMapper().map_to_session(spans, session_id)
            if not session.traces:
                raise SessionNotFoundError(f"aws/spans: spans for '{session_id}' held no agent invocation")
            return TaskOutput(output=self._extract_output(session), trajectory=session)

    return AwsSpansProvider(log_group="aws/spans", region=region)


def trace_provider(cfg: dict[str, Any]):
    if cfg["backend"] == "langfuse":
        return langfuse_v4_provider(float((cfg.get("langfuse") or {}).get("lookbackDays", 7)))
    ac = cfg.get("agentcore") or {}
    return aws_spans_provider(ac.get("region") or None)


def fetch_session(provider, session_id: str, wait_seconds: float, poll_seconds: float = 10.0):
    """The trajectory for one session, waiting for it to reach the backend.

    Spans are batched by the agent's exporter and again by the collector, then ingested
    asynchronously, so a session that finished a second ago is not yet in either backend. Returns
    None if it never arrives -- an execution failure, not a grade.
    """
    from strands_evals.providers import SessionNotFoundError  # noqa: PLC0415

    deadline = time.monotonic() + wait_seconds
    while True:
        try:
            data = provider.get_evaluation_data(session_id)
            if data.get("trajectory") is not None:
                return data
        except SessionNotFoundError:
            pass
        if time.monotonic() >= deadline:
            return None
        time.sleep(poll_seconds)


# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------


def _not_applicable(output) -> bool:
    if hasattr(output, "not_applicable"):
        return bool(output.not_applicable)
    return str(getattr(output, "label", "") or "").upper() in NOT_APPLICABLE


@dataclass
class Grade:
    session_id: str
    case: str
    evaluator: str
    score: float
    passed: bool
    reason: str
    agent: str = ""


@dataclass
class RunResult:
    grades: list[Grade] = field(default_factory=list)
    execution_failures: dict[str, str] = field(default_factory=dict)

    @property
    def pass_rate(self) -> float:
        return sum(g.passed for g in self.grades) / len(self.grades) if self.grades else 0.0


def collect_grades(report, failed: dict[str, str], sessions: dict[str, tuple[str, str]]) -> list[Grade]:
    """Flatten a Strands Evals report into one Grade per (case, evaluator) that was really graded.

    Skips cases whose task failed (in `failed`) and results that were not applicable, for the
    reasons in the module docstring.
    """
    grades = []
    for row, score, passed, reason, details in zip(
        report.cases, report.scores, report.test_passes, report.reasons, report.detailed_results or [[]] * len(report.cases)
    ):
        case_name = row.get("name") or ""
        if case_name in failed:
            continue
        # Nothing judged: every output not-applicable, or NO outputs at all. The second is what a
        # ToolCall evaluator returns for a turn that called no tool -- Strands Evals then reports
        # score 0 / "No evaluation outputs produced", which published as a grade reads as a tool
        # failure on a turn that had no tools: a typical run produces several such zeros.
        if not details or all(_not_applicable(d) for d in details):
            continue
        session_id, agent = sessions.get(case_name, (row.get("session_id", ""), ""))
        grades.append(Grade(
            session_id=session_id,
            case=case_name,
            evaluator=row.get("evaluator", ""),
            score=float(score or 0),
            passed=bool(passed),
            reason=reason or "",
            agent=agent,
        ))
    return grades


def publish_langfuse(client, grades: list[Grade], mode: str, run_name: str) -> None:
    for g in grades:
        client.create_score(
            name=f"{SCORE_PREFIX}{g.evaluator}",
            value=g.score,
            session_id=g.session_id,
            data_type="NUMERIC",
            comment=g.reason[:2000],
            metadata={"mode": mode, "run": run_name, "case": g.case, "passed": g.passed, "agent": g.agent},
        )
    client.flush()


def sampled(session_id: str, percentage: float) -> bool:
    """Deterministic sampling: the same session is in or out on every run, on every replica."""
    bucket = int(hashlib.sha256(session_id.encode()).hexdigest()[:8], 16) % 10000
    return bucket < percentage * 100


# ---------------------------------------------------------------------------
# Running the cases
# ---------------------------------------------------------------------------


def run_experiment_cases(cases, evaluators, task, max_workers: int):
    from strands_evals import Experiment  # noqa: PLC0415

    failed: dict[str, str] = {}

    async def guarded(case):
        try:
            return await task(case)
        except Exception as exc:  # noqa: BLE001
            failed[case.name] = f"{type(exc).__name__}: {exc}"
            raise

    experiment = Experiment(cases=cases, evaluators=evaluators)
    report = asyncio.run(experiment.run_evaluations_async(guarded, max_workers=max_workers))
    return report, failed


def online(cfg: dict[str, Any], *, provider=None, client=None, now: datetime | None = None,
           evaluators=None) -> RunResult:
    """Grade a deterministic sample of the sessions that went quiet in the last window."""
    from strands_evals import Case  # noqa: PLC0415

    if cfg["backend"] != "langfuse":
        raise ConfigError(
            "online mode runs on the langfuse backend only. On AWS, AgentCore Evaluations' online "
            "config already grades live traffic; use experiment mode there."
        )
    on = cfg.get("online") or {}
    window = timedelta(minutes=float(on.get("windowMinutes", 15)))
    quiet = timedelta(minutes=float(on.get("quietMinutes", 10)))
    pct = float(on.get("samplingPercentage", 10))
    cap = int(on.get("maxSessions", 50))

    now = now or datetime.now(timezone.utc)
    to_ts = now - quiet
    from_ts = to_ts - window

    # The client before the provider, always: see isolate_tracing for why the order matters.
    client = client or langfuse_client()
    provider = provider or trace_provider(cfg)

    session_ids = provider.quiet_sessions(from_ts, to_ts)

    chosen = [s for s in session_ids
              if not s.startswith(EXPERIMENT_SESSION_PREFIX) and sampled(s, pct)][:cap]
    log.info("online: %d sessions went quiet %s..%s, %d sampled at %.1f%%",
             len(session_ids), from_ts.isoformat(), to_ts.isoformat(), len(chosen), pct)
    result = RunResult()
    if not chosen:
        return result

    # Fetch before grading, so a session the backend cannot return is an execution failure here
    # rather than a zero score Strands Evals would otherwise record for it.
    fetched = {}
    for sid in chosen:
        data = fetch_session(provider, sid, wait_seconds=0)
        if data is None:
            result.execution_failures[sid] = "session not returned by the trace backend"
        else:
            fetched[sid] = data
    if not fetched:
        return result

    if evaluators is None:
        evaluators = build_evaluators(cfg.get("evaluators", []), cfg.get("rubrics", {}), build_judge(cfg["judge"]))
    cases = [Case(name=sid, input=sid, session_id=sid) for sid in fetched]

    async def task(case):
        return fetched[case.input]

    report, failed = run_experiment_cases(cases, evaluators, task, int(on.get("maxWorkers", 4)))
    result.execution_failures.update(failed)
    result.grades = collect_grades(report, failed, {sid: (sid, "") for sid in fetched})
    publish_langfuse(client, result.grades, "online", f"online-{now:%Y%m%dT%H%M}")
    return result


def parse_sse(body: str) -> str:
    """The agent's streamed reply, reassembled. An error event in the stream is a failed turn."""
    out = []
    for line in body.splitlines():
        if not line.startswith("data: "):
            continue
        payload = line[len("data: "):].strip()
        if payload == "[DONE]":
            break
        event = json.loads(payload)
        if "error" in event:
            raise RuntimeError(f"the agent reported an error mid-turn: {event['error']}")
        out.append(event.get("delta", ""))
    return "".join(out)


def call_agent(url: str, token_file: str, prompt: str, session_id: str, timeout: float) -> str:
    """One turn against a deployed agent, as its own caller, in a session this runner chose.

    The token is minted for the AGENT's audience, not the gateway's: the agent refuses a token
    naming any other relying party, and the gateway's would be a replayable credential if it did
    not.
    """
    resp = httpx.post(
        url,
        headers={"Authorization": f"Bearer {read_token(token_file)}", "Accept": "text/event-stream"},
        json={"prompt": prompt, "session_id": session_id},
        timeout=timeout,
    )
    if resp.status_code != 200:
        raise RuntimeError(f"{url} answered HTTP {resp.status_code}: {resp.text[:200]}")
    if resp.headers.get("x-session-id") not in (None, session_id):
        raise RuntimeError(
            f"{url} ran the turn in session {resp.headers.get('x-session-id')!r}, not {session_id!r}; "
            "its trace cannot be found under the id this runner sent"
        )
    return parse_sse(resp.text)


def experiment(cfg: dict[str, Any], *, provider=None, client=None, evaluators=None, agent_call=call_agent) -> RunResult:
    """Run every declared case against its agent, fetch the trajectory, grade it."""
    from strands_evals import Case  # noqa: PLC0415

    ex = cfg.get("experiment") or {}
    targets = ex.get("agents") or {}
    if not targets:
        raise ConfigError("experiment.agents is empty, so there is nothing to run")
    run_name = ex.get("name") or "experiment"
    wait = float(ex.get("traceWaitSeconds", 180))
    turn_timeout = float(ex.get("turnTimeoutSeconds", 300))

    # The client before the provider, always: see isolate_tracing for why the order matters.
    if cfg["backend"] == "langfuse":
        client = client or langfuse_client()
    provider = provider or trace_provider(cfg)
    if evaluators is None:
        names = list(cfg.get("evaluators", [])) + list(ex.get("extraEvaluators", []))
        evaluators = build_evaluators(names, {**cfg.get("rubrics", {}), **ex.get("rubrics", {})}, build_judge(cfg["judge"]))

    result = RunResult()
    for agent, target in targets.items():
        cases, sessions = [], {}
        for c in target.get("cases") or []:
            case = Case(
                name=f"{agent}/{c['name']}",
                session_id=f"{EXPERIMENT_SESSION_PREFIX}{uuid.uuid4()}",
                input=c["input"],
                expected_output=c.get("expectedOutput"),
                metadata={"agent": agent},
            )
            cases.append(case)
            sessions[case.name] = (case.session_id, agent)
        if not cases:
            continue

        def task(case, _t=target):
            async def run():
                output = await asyncio.to_thread(
                    agent_call, _t["url"], _t["tokenFile"], case.input, case.session_id, turn_timeout)
                data = await asyncio.to_thread(fetch_session, provider, case.session_id, wait)
                if data is None:
                    raise RuntimeError(
                        f"session {case.session_id} never reached the trace backend within {wait:.0f}s. "
                        "The turn ran; its spans did not arrive. Check the collector's trace exporter."
                    )
                return {"output": output, "trajectory": data["trajectory"]}
            return run()

        if cfg["backend"] == "agentcore":
            # Strands Evals' CloudWatch writer reads these at send time. service.name is what the
            # GenAI Observability dashboard groups results under, so it names the AGENT graded,
            # not this runner -- that is what puts the results beside that agent's traces.
            os.environ["AGENT_OBSERVABILITY_ENABLED"] = "true"
            os.environ["EVALUATION_RESULTS_LOG_GROUP"] = (cfg.get("agentcore") or {}).get("resultsName") or run_name
            os.environ["OTEL_RESOURCE_ATTRIBUTES"] = f"service.name={target.get('serviceName') or agent}"

        report, failed = run_experiment_cases(cases, evaluators, task, int(ex.get("maxWorkers", 2)))
        result.execution_failures.update(failed)
        result.grades += collect_grades(report, failed, sessions)

    if cfg["backend"] == "langfuse":
        publish_langfuse(client, result.grades, "experiment", run_name)
    return result


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def summarize(mode: str, result: RunResult, min_pass_rate: float | None) -> int:
    by_eval: dict[str, list[Grade]] = {}
    for g in result.grades:
        by_eval.setdefault(g.evaluator, []).append(g)
    summary = {
        "mode": mode,
        "graded": len(result.grades),
        "passRate": round(result.pass_rate, 3),
        "byEvaluator": {
            k: {"n": len(v), "passRate": round(sum(x.passed for x in v) / len(v), 3),
                "meanScore": round(sum(x.score for x in v) / len(v), 3)}
            for k, v in sorted(by_eval.items())
        },
        "executionFailures": result.execution_failures,
    }
    print(json.dumps(summary, indent=2))

    if result.execution_failures:
        log.error("%d case(s) could not be run or fetched; they are not graded", len(result.execution_failures))
        return EXIT_EXECUTION_FAILED
    if min_pass_rate is not None and result.grades and result.pass_rate < min_pass_rate:
        log.error("pass rate %.3f is below experiment.minPassRate %.3f", result.pass_rate, min_pass_rate)
        return EXIT_BELOW_THRESHOLD
    if min_pass_rate is not None and not result.grades:
        log.error("nothing was graded, so the gate cannot pass")
        return EXIT_EXECUTION_FAILED
    return EXIT_OK


def main(argv: list[str]) -> int:
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    mode = argv[1] if len(argv) > 1 else ""
    if mode not in ("online", "experiment"):
        print(__doc__)
        return EXIT_CONFIG
    try:
        cfg = load_config()
        isolate_tracing()
        if mode == "online":
            return summarize(mode, online(cfg), None)
        ex = cfg.get("experiment") or {}
        return summarize(mode, experiment(cfg), float(ex.get("minPassRate", 0.8)))
    except ConfigError as exc:
        log.error("%s", exc)
        return EXIT_CONFIG


if __name__ == "__main__":
    sys.exit(main(sys.argv))
