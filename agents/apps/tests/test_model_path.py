"""The agent attaches its projected token to the model call, and re-reads it per request.

    python apps/tests/test_model_path.py

This is the contract the whole request path rests on: the agent's only outbound credential is a
token naming itself, which the gateway validates before assuming that agent's role. If the token is
not on the request, the gateway refuses it and the symptom is a healthy deployment whose every model
call fails. Two ways to get there: the agent never reads the token file, or it attaches the hook to a
sync httpx client that the OpenAI SDK rejects at construction, so no request is ever made.

Neither was catchable at render time, and neither is catchable without making a call. So this stands
up a fake OpenAI-compatible endpoint on loopback, points the agent at it, and asserts what arrives:

  1. An Authorization header is present.
  2. It carries the exact bytes currently in the token file -- not a placeholder, not a stale copy.
  3. Rotating the file mid-run changes what the next request carries -- from the same agent, and
     from the MCP client -- because the kubelet rewrites that file in place and a token held across
     a refresh is rejected once it expires.
  4. The agent returns the model's text to its caller.
  5. With a static OPENAI_API_KEY also set, the token file still wins. Both gateways refuse a static
     key in Strict mode, so an agent that preferred the key would look configured and fail every call.

Nothing here reaches the network and nothing needs a cluster or Bedrock.
"""

from __future__ import annotations

import http.server
import importlib.util
import json
import os
import sys
import threading
from pathlib import Path

AGENTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS_DIR / "common"))

SEEN: list[dict] = []


class _FakeModel(http.server.BaseHTTPRequestHandler):
    """An OpenAI-compatible chat-completions endpoint that records what it was sent."""

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode() if length else "{}"
        SEEN.append({
            "path": self.path,
            "authorization": self.headers.get("Authorization", ""),
            "policy_session": self.headers.get("x-amzn-bedrock-agentcore-policy-session-id", ""),
            "body": body,
        })
        # Strands always asks for a stream ("stream": true), so a non-streaming JSON body is
        # parsed as nothing and the turn comes back empty. Answer in the OpenAI SSE shape.
        def chunk(delta=None, finish=None, usage=None):
            d = {"id": "chatcmpl-test", "object": "chat.completion.chunk", "created": 0,
                 "model": "test-model",
                 "choices": [{"index": 0, "delta": delta or {}, "finish_reason": finish}]}
            if usage:
                d["usage"] = usage
            return f"data: {json.dumps(d)}\n\n".encode()

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        self.wfile.write(chunk({"role": "assistant"}))
        self.wfile.write(chunk({"content": "reachable"}))
        self.wfile.write(chunk(finish="stop",
                               usage={"prompt_tokens": 7, "completion_tokens": 1,
                                      "total_tokens": 8}))
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, *a):
        pass


def main() -> int:
    # Loopback only: a test fixture nothing outside this process should reach.
    srv = http.server.HTTPServer(("127.0.0.1", 0), _FakeModel)
    base = f"http://127.0.0.1:{srv.server_port}"
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    token_file = Path(os.environ.get("TMPDIR", "/tmp")) / "eks-agents-model-path-token"
    token_file.write_text("first-token-value")

    os.environ.update({
        "AGENT_NAME": "research",
        "OPENAI_BASE_URL": base,
        "AGENT_IDENTITY_TOKEN_FILE": str(token_file),
        "AGENT_MODEL": "test-model",
    })
    for stale in ("OPENAI_API_KEY", "AGENT_GATEWAY_URL", "AUTH_TEST_BYPASS"):
        os.environ.pop(stale, None)

    spec = importlib.util.spec_from_file_location("agent_app", AGENTS_DIR / "reference" / "app.py")
    agent_app = importlib.util.module_from_spec(spec)
    sys.modules["agent_app"] = agent_app
    spec.loader.exec_module(agent_app)

    agent, endpoint = agent_app.build_agent()

    results = []

    def check(name, got, want):
        ok = got == want
        results.append((ok, f"{name}: got {got!r}, want {want!r}"))
        colour = "\033[32mPASS\033[0m" if ok else "\033[31mFAIL\033[0m"
        print(f"  {colour} {name} -> {got!r}")

    print("\nthe model call")
    reply = str(agent("Reply with the single word: reachable"))
    check("the agent returns the model's text", "reachable" in reply, True)
    check("exactly one request reached the model endpoint", len(SEEN), 1)
    check("the request carried an Authorization header",
          SEEN[0]["authorization"].startswith("Bearer "), True)
    check("the header carried the token file's exact contents",
          SEEN[0]["authorization"], "Bearer first-token-value")
    check("it posted to a chat-completions path",
          SEEN[0]["path"].endswith("/chat/completions"), True)
    # A text-only message goes as one string: the gateway's guardrail scores a list of parts as its
    # serialized JSON, and refuses ordinary prompts sent that way.
    sent = json.loads(SEEN[0]["body"]).get("messages", [])
    check("a text-only user message is sent as a string, not a list of parts",
          all(isinstance(m.get("content"), str) for m in sent if m.get("role") == "user"), True)

    print("\nthe session id reaches the spans")
    # The evaluation runner fetches a conversation from the trace backend by session.id, and
    # Langfuse groups traces into a session on it. An agent whose spans lack it produces traces
    # that nothing can join, and every session-level evaluator then grades nothing. So assert it on
    # the spans a real turn emits, not on the Agent's constructor arguments.
    from opentelemetry import trace as otel_trace  # noqa: PLC0415
    from opentelemetry.sdk.trace import TracerProvider  # noqa: PLC0415
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor  # noqa: PLC0415
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter  # noqa: PLC0415

    exporter = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    otel_trace.set_tracer_provider(provider)
    session_agent, _ = agent_app.build_agent(session_id="eval-case-7")
    session_agent("Reply with the single word: reachable")
    spans = exporter.get_finished_spans()
    tagged = [sp.name for sp in spans if (sp.attributes or {}).get("session.id") == "eval-case-7"]
    check("the turn emitted spans", len(spans) > 0, True)
    check("the agent-invocation span carries session.id",
          any(n.startswith("invoke_agent") for n in tagged), True)

    print("\ntoken rotation, which the kubelet does in place")
    # The SAME agent, after the file rotates. A turn can outlive the token it started with (ten
    # minutes, refreshed at 80%), so the credential is read per request, not per build: an agent
    # that holds the string it was built with is refused 403 insufficient_scope once that copy
    # expires.
    token_file.write_text("rotated-token-value")
    agent("Reply with the single word: reachable")
    check("the same agent's next request carries the rotated token",
          SEEN[-1]["authorization"], "Bearer rotated-token-value")
    check("the request before the rotation carried the first one",
          SEEN[0]["authorization"], "Bearer first-token-value")
    rotated_agent, _ = agent_app.build_agent()
    rotated_agent("Reply with the single word: reachable")
    check("a rebuilt agent carries the rotated token",
          SEEN[-1]["authorization"], "Bearer rotated-token-value")

    print("\nthe MCP client's credential, per request")
    auth = agent_app.TokenFileAuth(str(token_file))
    import httpx
    first = next(auth.auth_flow(httpx.Request("POST", "http://mcp.invalid/mcp")))
    token_file.write_text("third-token-value")
    second = next(auth.auth_flow(httpx.Request("POST", "http://mcp.invalid/mcp")))
    check("the MCP request carries the token file's contents",
          first.headers.get("Authorization"), "Bearer rotated-token-value")
    check("and the next one carries the file as it is now",
          second.headers.get("Authorization"), "Bearer third-token-value")
    token_file.write_text("rotated-token-value")

    print("\na static key does not displace the token")
    os.environ["OPENAI_API_KEY"] = "static-key-the-gateway-refuses"
    keyed_agent, _ = agent_app.build_agent()
    keyed_agent("Reply with the single word: reachable")
    check("the token file wins over OPENAI_API_KEY",
          SEEN[-1]["authorization"], "Bearer rotated-token-value")
    os.environ.pop("OPENAI_API_KEY")

    print("\nthe policy session a temporal policy needs")
    sess_agent, _ = agent_app.build_agent(session_id="conv-42")
    sess_agent("Reply with the single word: reachable")
    check("no policy-session header unless AGENT_POLICY_SESSIONS is on", SEEN[-1]["policy_session"], "")
    os.environ["AGENT_POLICY_SESSIONS"] = "true"
    sess_agent, _ = agent_app.build_agent(session_id="conv-42")
    sess_agent("Reply with the single word: reachable")
    check("with it on, the conversation session is the policy session", SEEN[-1]["policy_session"], "conv-42")
    os.environ.pop("AGENT_POLICY_SESSIONS")

    print("\nan unreachable MCP endpoint degrades, it does not crash")
    # Nothing listens on port 1 on loopback, so the MCP client cannot start -- the state an agent
    # is in while its MCP server is still rolling out.
    os.environ["AGENT_MCP_URL"] = "http://127.0.0.1:1/mcp"
    try:
        degraded, _ = agent_app.build_agent()
        check("an agent whose MCP endpoint is down still builds", "built", "built")
        degraded("Reply with the single word: reachable")
        check("and still answers a turn, without the tools", SEEN[-1]["authorization"] != "", True)
    except Exception as exc:  # noqa: BLE001
        check("an agent whose MCP endpoint is down still builds", f"raised {type(exc).__name__}", "built")
    os.environ["AGENT_TOOLS_REQUIRED"] = "true"
    try:
        agent_app.build_agent()
        check("AGENT_TOOLS_REQUIRED=true refuses to build without its tools", "built", "raised")
    except Exception:  # noqa: BLE001
        check("AGENT_TOOLS_REQUIRED=true refuses to build without its tools", "raised", "raised")
    os.environ.pop("AGENT_TOOLS_REQUIRED")
    os.environ.pop("AGENT_MCP_URL")

    print("\nthe credential is required")
    os.environ.pop("AGENT_IDENTITY_TOKEN_FILE")
    try:
        agent_app.build_agent()
        check("an agent with no credential refuses to start", "started", "SystemExit")
    except SystemExit:
        check("an agent with no credential refuses to start", "SystemExit", "SystemExit")

    srv.shutdown()
    token_file.unlink(missing_ok=True)

    failed = [m for ok, m in results if not ok]
    print()
    if failed:
        for m in failed:
            print(f"\033[31m  {m}\033[0m")
        print(f"\033[31m{len(failed)} of {len(results)} model-path checks failed\033[0m")
        return 1
    print(f"\033[32mall {len(results)} model-path checks behave correctly\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(main())
