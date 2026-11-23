"""The evaluation runner grades what it ran, publishes only real grades, and fails closed.

    python apps/tests/test_evals_runner.py

No cluster, no model and no Langfuse: the agent call, the trace backend, the judge and the score
client are fakes. What is real is the runner's own logic and Strands Evals' Experiment, which is the
part that decides what a failed case becomes -- the reason these tests exist. Strands Evals records
a task that raised as score 0 / test_pass false; publishing that would put a zero on a session
nobody graded, so the runner must count it as an execution failure instead.
"""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

AGENTS_DIR = Path(__file__).resolve().parents[1]

RESULTS: list[tuple[bool, str]] = []


def check(name, got, want):
    ok = got == want
    RESULTS.append((ok, f"{name}: got {got!r}, want {want!r}"))
    colour = "\033[32mPASS\033[0m" if ok else "\033[31mFAIL\033[0m"
    print(f"  {colour} {name} -> {got!r}")


def load_runner():
    spec = importlib.util.spec_from_file_location("evals_runner", AGENTS_DIR / "evals" / "runner.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["evals_runner"] = mod
    spec.loader.exec_module(mod)
    return mod


class FakeScores:
    """Stands in for the Langfuse client: records scores, and lists sessions for online mode."""

    def __init__(self, sessions=()):
        self.scores = []
        self.flushed = False
        self._sessions = list(sessions)
        outer = self

        class _Sessions:
            def list(self, page, limit, from_timestamp, to_timestamp):
                outer.window = (from_timestamp, to_timestamp)

                class R:
                    data = [type("S", (), {"id": s})() for s in outer._sessions]
                    meta = type("M", (), {"total_pages": 1})()
                return R()

        self.api = type("A", (), {"sessions": _Sessions()})()

    def create_score(self, **kw):
        self.scores.append(kw)

    def flush(self):
        self.flushed = True


def main() -> int:
    try:
        import strands_evals  # noqa: F401, PLC0415
    except ImportError:
        print("  \033[33mSKIP\033[0m strands-agents-evals is not installed; runner not exercised")
        return 0

    from strands_evals.evaluators import Evaluator  # noqa: PLC0415
    from strands_evals.providers import SessionNotFoundError  # noqa: PLC0415
    from strands_evals.types.evaluation import NOT_APPLICABLE, EvaluationOutput  # noqa: PLC0415
    from strands_evals.types.trace import Session  # noqa: PLC0415

    r = load_runner()

    class Passes(Evaluator):
        """Passes when the output contains the expected text; no model call."""

        def evaluate(self, case):
            want = case.expected_output or ""
            ok = want.lower() in (case.actual_output or "").lower()
            return [EvaluationOutput(score=1.0 if ok else 0.0, test_pass=ok, reason="contains" if ok else "missing")]

        async def evaluate_async(self, case):
            return self.evaluate(case)

    class NothingToJudge(Evaluator):
        def evaluate(self, case):
            return [EvaluationOutput(score=0.0, test_pass=False, reason="no tool call", label=NOT_APPLICABLE)]

        async def evaluate_async(self, case):
            return self.evaluate(case)

    class NoOutputs(Evaluator):
        """What a ToolCall evaluator returns for a turn that called no tool."""

        def evaluate(self, case):
            return []

        async def evaluate_async(self, case):
            return []

    class Provider:
        def __init__(self, known, listed=()):
            self.known = set(known)
            self.listed = list(listed)

        def quiet_sessions(self, from_ts, to_ts):
            self.window = (from_ts, to_ts)
            return self.listed

        def get_evaluation_data(self, sid):
            if sid not in self.known:
                raise SessionNotFoundError(sid)
            return {"output": "from-trace", "trajectory": Session(session_id=sid, traces=[])}

    print("\nsampling")
    ids = [f"s-{i}" for i in range(5000)]
    picked = [s for s in ids if r.sampled(s, 10)]
    check("sampling is deterministic", picked == [s for s in ids if r.sampled(s, 10)], True)
    check("10% sampling picks roughly 10%", 400 < len(picked) < 600, True)
    check("0% samples nothing", any(r.sampled(s, 0) for s in ids), False)
    check("100% samples everything", all(r.sampled(s, 100) for s in ids), True)

    print("\nthe agent's stream")
    check("deltas are reassembled",
          r.parse_sse('data: {"delta": "hel"}\n\ndata: {"delta": "lo"}\n\ndata: [DONE]\n\n'), "hello")
    try:
        r.parse_sse('data: {"error": "model refused"}\n\ndata: [DONE]\n\n')
        check("an error event is a failed turn", "returned", "raised")
    except RuntimeError:
        check("an error event is a failed turn", "raised", "raised")

    cfg = {
        "backend": "langfuse",
        "judge": {"baseUrl": "http://gateway/judge/x"},
        "evaluators": [],
        "experiment": {
            "name": "release",
            "traceWaitSeconds": 0,
            "agents": {
                "research": {
                    "url": "http://research/chat",
                    "tokenFile": "/unused",
                    "cases": [
                        {"name": "capital", "input": "capital of France?", "expectedOutput": "Paris"},
                        {"name": "wrong", "input": "capital of Spain?", "expectedOutput": "Madrid"},
                        {"name": "unreachable", "input": "boom", "expectedOutput": "x"},
                        {"name": "untraced", "input": "lost", "expectedOutput": "x"},
                    ],
                },
            },
        },
    }

    sent = {}

    def fake_call(url, token_file, prompt, session_id, timeout):
        sent[prompt] = session_id
        if prompt == "boom":
            raise RuntimeError("HTTP 401")
        return {"capital of France?": "It is Paris.", "capital of Spain?": "Barcelona."}.get(prompt, "ok")

    class TracingProvider(Provider):
        """Knows every session the runner sent, except the one whose spans were lost."""

        def get_evaluation_data(self, sid):
            if sid == sent.get("lost") or sid not in sent.values():
                raise SessionNotFoundError(sid)
            return {"output": "from-trace", "trajectory": Session(session_id=sid, traces=[])}

    print("\nexperiment mode")
    scores = FakeScores()
    res = r.experiment(cfg, provider=TracingProvider(()), client=scores,
                       evaluators=[Passes(), NothingToJudge(), NoOutputs()], agent_call=fake_call)
    published = {(s["metadata"]["case"], s["name"]) for s in scores.scores}
    check("graded cases are published", ("research/capital", "strands.Passes") in published, True)
    check("a failing grade is still a grade", ("research/wrong", "strands.Passes") in published, True)
    check("an unreachable agent publishes no score",
          any(c == "research/unreachable" for c, _ in published), False)
    check("a session whose trace never arrived publishes no score",
          any(c == "research/untraced" for c, _ in published), False)
    check("both are execution failures",
          sorted(res.execution_failures), ["research/unreachable", "research/untraced"])
    check("a not-applicable result is not published",
          any(n == "strands.NothingToJudge" for _, n in published), False)
    check("each score is on the session the runner sent the agent",
          {s["session_id"] for s in scores.scores if s["metadata"]["case"] == "research/capital"},
          {sent["capital of France?"]})
    check("an evaluator with no outputs (a tool evaluator, no tool call) is not published",
          any(n == "strands.NoOutputs" for _, n in published), False)
    check("experiment sessions carry the prefix online grading skips",
          all(s.startswith(r.EXPERIMENT_SESSION_PREFIX) for s in sent.values()), True)
    check("scores are flushed", scores.flushed, True)
    check("pass rate is over real grades only", res.pass_rate, 0.5)
    check("execution failures exit 2", r.summarize("experiment", res, 0.4), r.EXIT_EXECUTION_FAILED)

    clean = r.RunResult(grades=res.grades)
    check("a pass rate below the threshold exits 1", r.summarize("experiment", clean, 0.8), r.EXIT_BELOW_THRESHOLD)
    check("a pass rate at the threshold exits 0", r.summarize("experiment", clean, 0.5), r.EXIT_OK)
    check("a gate with nothing graded does not pass",
          r.summarize("experiment", r.RunResult(), 0.5), r.EXIT_EXECUTION_FAILED)

    print("\nonline mode")
    sessions = [f"sess-{i}" for i in range(40)] + [r.EXPERIMENT_SESSION_PREFIX + "gate-1"]
    scores = FakeScores(sessions)
    known = sessions[:-2]  # sess-39 is not returned by the backend; the gate's session is skipped
    prov = Provider(known, listed=sessions)
    res = r.online({**cfg, "online": {"samplingPercentage": 100, "windowMinutes": 15, "quietMinutes": 10}},
                   provider=prov, client=scores, evaluators=[Passes()])
    frm, to = prov.window
    check("the window ends quietMinutes ago and spans windowMinutes", round((to - frm).total_seconds()), 900)
    check("every returned session is graded once", len(scores.scores), len(known))
    check("a session the backend cannot return is a failure, not a zero",
          list(res.execution_failures), [sessions[-2]])
    check("online grading skips the release gate's own sessions",
          any(s["session_id"].startswith(r.EXPERIMENT_SESSION_PREFIX) for s in scores.scores), False)
    check("online scores are session scores", all(s["session_id"] in known for s in scores.scores), True)
    try:
        r.online({**cfg, "backend": "agentcore"}, provider=Provider(()), client=scores, evaluators=[Passes()])
        check("online mode is refused on the agentcore backend", "ran", "refused")
    except r.ConfigError:
        check("online mode is refused on the agentcore backend", "refused", "refused")

    print("\nthe Langfuse v4 provider")
    import json as _json  # noqa: PLC0415

    import httpx  # noqa: PLC0415

    now = "2026-11-11T19:23:39.000Z"
    rows = [
        {"id": "a", "traceId": "t1", "parentObservationId": None, "type": "AGENT", "name": "invoke_agent research",
         "sessionId": "s1", "startTime": now, "endTime": now,
         "input": _json.dumps([{"role": "user", "content": [{"text": "Capital of France?"}]}]),
         "output": _json.dumps({"message": {"role": "assistant", "content": [{"text": "Paris."}]}, "finish_reason": "end_turn"}),
         "metadata": {}},
    ]
    seen = []

    def handler(req):
        seen.append(dict(req.url.params))
        if "cursor" not in req.url.params:
            return httpx.Response(200, json={"data": rows, "meta": {"cursor": "next"}})
        return httpx.Response(200, json={"data": [], "meta": {}})

    import os as _os  # noqa: PLC0415
    _os.environ.update({"LANGFUSE_PUBLIC_KEY": "pk-lf-test", "LANGFUSE_SECRET_KEY": "sk-lf-test",
                        "LANGFUSE_HOST": "http://127.0.0.1:9"})
    v4 = r.langfuse_v4_provider(http=httpx.Client(base_url="http://lf", transport=httpx.MockTransport(handler)))
    traces = v4._fetch_traces_for_session("s1")
    check("v4: reads /api/public/v2/observations by sessionId", seen[0].get("sessionId"), "s1")
    check("v4: follows the cursor past the first page", len(seen), 2)
    check("v4: groups rows by trace", [t.id for t in traces], ["t1"])
    obs = v4._fetch_observations("t1")
    check("v4: raw-string io is parsed", isinstance(obs[0].input, list), True)
    # The conversion itself is Strands Evals' code and is exercised against real Langfuse 4 rows
    # on a cluster; here, only that an adapted row never raises out of the provider.
    check("v4: adapted rows pass through the provider's converter without raising",
          isinstance(v4._convert_observations(obs, "s1"), list), True)
    from datetime import datetime as _dt, timedelta as _td, timezone as _tz  # noqa: PLC0415

    def roots(req):
        groups = set(req.url.params.get("fields", "").split(","))
        if "basic" not in groups:  # as the real API does: sessionId is a basic-group field
            return httpx.Response(200, json={"data": [{"startTime": "2026-11-11T10:05:00Z"}], "meta": {}})
        return httpx.Response(200, json={"data": [
            {"sessionId": "quiet", "startTime": "2026-11-11T10:05:00Z"},
            {"sessionId": "busy", "startTime": "2026-11-11T10:05:00Z"},
            {"sessionId": "busy", "startTime": "2026-11-11T10:20:00Z"},
            {"sessionId": None, "startTime": "2026-11-11T10:06:00Z"},
        ], "meta": {}})
    v4b = r.langfuse_v4_provider(http=httpx.Client(base_url="http://lf", transport=httpx.MockTransport(roots)))
    frm = _dt(2026, 11, 11, 10, 0, tzinfo=_tz.utc)
    check("v4: a session still active after the window is left for a later run",
          v4b.quiet_sessions(frm, frm + _td(minutes=15)), ["quiet"])

    print("\nthe runner's own spans stay out of Langfuse")
    try:
        import langfuse  # noqa: F401, PLC0415
    except ImportError:
        print("  \033[33mSKIP\033[0m langfuse is not installed")
    else:
        import os  # noqa: PLC0415

        from opentelemetry import trace as otel_trace  # noqa: PLC0415

        os.environ.update({"LANGFUSE_PUBLIC_KEY": "pk-lf-test", "LANGFUSE_SECRET_KEY": "sk-lf-test",
                           "LANGFUSE_HOST": "http://127.0.0.1:9"})
        r.isolate_tracing()
        r.langfuse_client()
        from strands_evals.providers import LangfuseProvider  # noqa: PLC0415
        LangfuseProvider()
        procs = otel_trace.get_tracer_provider()._active_span_processor._span_processors
        check("the global tracer provider carries no Langfuse exporter",
              [type(p).__name__ for p in procs if "Langfuse" in type(p).__name__], [])

    print("\nthe Langfuse keys")
    import os as _o  # noqa: PLC0415
    kd = Path(_o.environ.get("TMPDIR", "/tmp")) / "evals-keys"
    kd.mkdir(exist_ok=True)
    (kd / "public-key").write_text("pk-lf-from-file\n")
    (kd / "secret-key").write_text("sk-lf-from-file\n")
    _o.environ["LANGFUSE_KEYS_DIR"] = str(kd)
    check("keys are read from the mounted files when LANGFUSE_KEYS_DIR is set",
          r.langfuse_keys(), ("pk-lf-from-file", "sk-lf-from-file"))
    (kd / "secret-key").unlink()
    try:
        r.langfuse_keys()
        check("a missing key file is a config error, not an empty key", "read", "refused")
    except r.ConfigError:
        check("a missing key file is a config error, not an empty key", "refused", "refused")
    (kd / "public-key").unlink(); kd.rmdir()
    del _o.environ["LANGFUSE_KEYS_DIR"]

    print("\nconfiguration")
    for bad, why in [({"backend": "x"}, "an unknown backend"),
                     ({"backend": "langfuse", "judge": {}}, "no judge endpoint"),
                     ({"backend": "langfuse", "judge": {"baseUrl": "u"}}, "nothing to grade with")]:
        p = Path(os.environ.get("TMPDIR", "/tmp")) / "evals-bad.yaml"
        import yaml  # noqa: PLC0415
        p.write_text(yaml.safe_dump(bad))
        try:
            r.load_config(str(p))
            check(f"{why} is refused", "loaded", "refused")
        except r.ConfigError:
            check(f"{why} is refused", "refused", "refused")
        p.unlink()
    try:
        r.build_evaluators(["NoSuchThing"], {}, None)
        check("an unknown evaluator is refused", "built", "refused")
    except r.ConfigError:
        check("an unknown evaluator is refused", "refused", "refused")
    built = r.build_evaluators(["Helpfulness", "ToolParameterAccuracyEvaluator"],
                               {"groundedness": {"rubric": "Score 1 if grounded."}}, None)
    check("built-ins resolve with or without the suffix, rubrics become OutputEvaluators",
          [e.get_name() for e in built], ["HelpfulnessEvaluator", "ToolParameterAccuracyEvaluator", "groundedness"])

    failed = [m for ok, m in RESULTS if not ok]
    print()
    if failed:
        for m in failed:
            print(f"\033[31m  {m}\033[0m")
        print(f"\033[31m{len(failed)} of {len(RESULTS)} runner checks failed\033[0m")
        return 1
    print(f"\033[32mall {len(RESULTS)} runner checks behave correctly\033[0m")
    return 0


if __name__ == "__main__":
    import os  # noqa: E402,F401

    sys.exit(main())
