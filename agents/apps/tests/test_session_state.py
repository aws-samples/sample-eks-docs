"""The conversation survives between turns, for the caller that owns it and nobody else.

    python apps/tests/test_session_state.py

The reference agent is rebuilt for every turn, so without a session manager the second message of
a conversation reaches the model with no history. This stands up a fake OpenAI-compatible endpoint
on loopback, drives turns through build_agent with the workspace session store pointed at a
temporary directory, and asserts what the model is sent:

  1. A second turn in the same session carries the first turn's messages.
  2. The same session id from a DIFFERENT caller starts empty: the key is the verified caller and
     the session together, so a guessed session id reaches nothing.
  3. A new session for the same caller starts empty.
  4. With nothing configured, nothing is saved and nothing is loaded.

The S3 store is the same Strands interface over a bucket; it is exercised against a real bucket
by `scripts/exercise.sh session`.
"""

from __future__ import annotations

import http.server
import json
import os
import sys
import tempfile
import threading
from pathlib import Path

AGENTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS_DIR / "common"))
sys.path.insert(0, str(AGENTS_DIR / "reference"))

SEEN: list[dict] = []


class _FakeModel(http.server.BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))) or b"{}")
        SEEN.append(body)

        def chunk(delta=None, finish=None):
            d = {"id": "x", "object": "chat.completion.chunk", "created": 0, "model": "m",
                 "choices": [{"index": 0, "delta": delta or {}, "finish_reason": finish}]}
            return f"data: {json.dumps(d)}\n\n".encode()

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        self.wfile.write(chunk({"role": "assistant"}))
        self.wfile.write(chunk({"content": "noted"}))
        self.wfile.write(chunk(finish="stop"))
        self.wfile.write(b"data: [DONE]\n\n")

    def log_message(self, *a):
        pass


def user_texts(body: dict) -> list[str]:
    out = []
    for m in body.get("messages", []):
        if m.get("role") != "user":
            continue
        c = m.get("content")
        if isinstance(c, list):
            out += [p.get("text", "") for p in c if isinstance(p, dict)]
        elif isinstance(c, str):
            out.append(c)
    return out


def main() -> int:
    srv = http.server.HTTPServer(("127.0.0.1", 0), _FakeModel)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    store = tempfile.mkdtemp(prefix="eks-agents-sessions-")
    token = Path(tempfile.mkdtemp()) / "token"
    token.write_text("t")
    os.environ.update({
        "AGENT_NAME": "research",
        "OPENAI_BASE_URL": f"http://127.0.0.1:{srv.server_port}",
        "AGENT_IDENTITY_TOKEN_FILE": str(token),
        "AGENT_MODEL": "m",
        "AGENT_GATEWAY_TOOLS": "off",
        "AGENT_WORKSPACE_PERSISTENT": "true",
        "AGENT_SESSION_DIR": store,
    })
    for stale in ("CHECKPOINT_BUCKET", "AGENT_CONSOLIDATION_DB_SECRET_ARN", "AGENT_GATEWAY_URL"):
        os.environ.pop(stale, None)

    import app  # noqa: PLC0415

    failures = 0

    def check(cond: bool, what: str) -> None:
        nonlocal failures
        print(("ok   " if cond else "FAIL ") + what)
        failures += 0 if cond else 1

    def turn(user: str, session: str, prompt: str) -> list[str]:
        agent, _ = app.build_agent(session_id=session, user_id=user)
        agent(prompt)
        return user_texts(SEEN[-1])

    turn("caller-a", "s1", "my favourite colour is teal")
    second = turn("caller-a", "s1", "what did I just tell you?")
    check(any("teal" in t for t in second), "a second turn in the same session carries the first")
    other = turn("caller-b", "s1", "what did I just tell you?")
    check(not any("teal" in t for t in other), "the same session id from another caller starts empty")
    fresh = turn("caller-a", "s2", "what did I just tell you?")
    check(not any("teal" in t for t in fresh), "a new session for the same caller starts empty")
    check(any(Path(store).rglob("*.json")), "the conversation was written under the session directory")

    os.environ.pop("AGENT_WORKSPACE_PERSISTENT")
    check(app.session_manager("caller-a", "s1") is None, "with no store configured, nothing is saved")
    check(app.session_key("a", "s1") != app.session_key("b", "s1"), "the key depends on the caller")

    print(f"\n{'all passed' if failures == 0 else f'{failures} failed'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
