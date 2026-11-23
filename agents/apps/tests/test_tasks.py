"""A task agent's worker: one message, kept invisible while it runs, answered, then deleted.

    python apps/tests/test_tasks.py

What would make runtime: tasks lose or duplicate work, one check each:

  1. A task that succeeds sends its answer to the result queue and is deleted -- in that order, so
     a pod that dies between the two repeats a task rather than losing its answer.
  2. A task that fails is NOT deleted and is made visible again at once, so another pod retries it
     and the queue's maxReceiveCount, not this code, decides when it goes to the dead-letter queue.
     A task the model stops at its output limit is answered "incomplete" and deleted instead: every
     retry would stop at the same place (three attempts, then the dead-letter queue).
  3. A malformed task is answered "refused" and deleted: it can never succeed, so cycling it to the
     dead-letter queue would only look like a transient failure.
  4. A task that runs longer than the visibility timeout keeps its message: the heartbeat extends it.
  5. No message (another pod took it) exits cleanly, and the user id a producer names is scoped
     under tasks/ and the sending IAM principal SQS verified, never under an HTTP caller's subject.

No AWS and no model: SQS is a fake, and the turn is replaced.
"""

from __future__ import annotations

import json
import os
import sys
import time
import types
from pathlib import Path

AGENTS_DIR = Path(__file__).resolve().parents[1]
os.environ.update({"AGENT_TASK_QUEUE_URL": "https://sqs.us-west-2.amazonaws.com/111122223333/c-research-tasks",
                   "AGENT_RESULT_QUEUE_URL": "https://sqs.us-west-2.amazonaws.com/111122223333/c-research-results",
                   "AGENT_TASK_VISIBILITY_SECONDS": "30", "AWS_REGION": "us-west-2"})
sys.path.insert(0, str(AGENTS_DIR / "reference"))

RESULTS: list[tuple[str, bool]] = []


def check(name: str, ok: bool) -> None:
    RESULTS.append((name, ok))
    print(("  PASS " if ok else "  FAIL ") + name)


class FakeSQS:
    def __init__(self, messages):
        self.messages, self.calls = list(messages), []

    def receive_message(self, **kw):
        self.calls.append(("receive", kw))
        return {"Messages": [self.messages.pop(0)]} if self.messages else {}

    def send_message(self, **kw):
        self.calls.append(("send", kw))

    def delete_message(self, **kw):
        self.calls.append(("delete", kw))

    def change_message_visibility(self, **kw):
        self.calls.append(("visibility", kw))

    def kinds(self):
        return [c[0] for c in self.calls]


def run(worker, sqs, turn):
    sys.modules["boto3"] = types.SimpleNamespace(client=lambda *a, **k: sqs)
    worker.run_turn = turn
    return worker.main()


def msg(body, mid="m-1"):
    return {"MessageId": mid, "ReceiptHandle": "r-1", "Body": body, "Attributes": {"ApproximateReceiveCount": "1"}}


def main() -> int:
    import worker

    print("1. success: answer, then delete")
    sqs = FakeSQS([msg(json.dumps({"prompt": "hello", "task_id": "t-1"}))])
    rc = run(worker, sqs, lambda t: "the answer")
    kinds = [k for k in sqs.kinds() if k != "receive"]
    sent = [c[1] for c in sqs.calls if c[0] == "send"]
    check("exit 0", rc == 0)
    check("answer sent, then the message deleted", kinds == ["send", "delete"])
    body = json.loads(sent[0]["MessageBody"]) if sent else {}
    check("the answer names the task and says done", body.get("task_id") == "t-1" and body.get("status") == "done" and body.get("answer") == "the answer")
    check("the answer goes to the result queue", sent and sent[0]["QueueUrl"].endswith("-results"))

    print("2. failure: not deleted, visible again at once")
    sqs = FakeSQS([msg(json.dumps({"prompt": "hello"}))])
    def boom(t):
        raise RuntimeError("model unavailable")
    rc = run(worker, sqs, boom)
    check("exit non-zero, so the Job records the failure", rc == 1)
    check("not deleted", "delete" not in sqs.kinds())
    vis = [c[1] for c in sqs.calls if c[0] == "visibility"]
    check("visibility reset to 0 for a retry", vis and vis[-1]["VisibilityTimeout"] == 0)
    check("no answer sent for a failed task", "send" not in sqs.kinds())

    print("2b. output limit: answered incomplete, not retried")
    sqs = FakeSQS([msg(json.dumps({"prompt": "very long"}))])
    def limit(t):
        raise worker.Incomplete("the first half")
    rc = run(worker, sqs, limit)
    sent = [json.loads(c[1]["MessageBody"]) for c in sqs.calls if c[0] == "send"]
    check("exit 0, answered incomplete with the partial text", rc == 0 and sent and sent[0]["status"] == "incomplete" and sent[0]["answer"] == "the first half")
    check("deleted, because a retry would stop at the same limit", "delete" in sqs.kinds())

    print("2c. no text: answered incomplete, not done")
    sqs = FakeSQS([msg(json.dumps({"prompt": "say nothing"}))])
    rc = run(worker, sqs, lambda t: "")
    sent = [json.loads(c[1]["MessageBody"]) for c in sqs.calls if c[0] == "send"]
    check("an empty answer is incomplete, with the reason", rc == 0 and sent and sent[0]["status"] == "incomplete" and "no text" in sent[0].get("error", ""))
    check("and deleted", "delete" in sqs.kinds())

    print("3. malformed: refused and deleted")
    for bad, why in (("not json", "not JSON"), (json.dumps({"task_id": "x"}), "no prompt"),
                     (json.dumps({"prompt": "p", "user_id": "a b"}), "bad user_id")):
        sqs = FakeSQS([msg(bad)])
        rc = run(worker, sqs, lambda t: "never")
        sent = [json.loads(c[1]["MessageBody"]) for c in sqs.calls if c[0] == "send"]
        check(f"{why}: answered refused and deleted", rc == 0 and sent and sent[0]["status"] == "refused" and "delete" in sqs.kinds())

    print("4. long task: the heartbeat keeps the message")
    sqs = FakeSQS([msg(json.dumps({"prompt": "slow"}))])
    orig = worker.Heartbeat.__init__
    def fast(self, *a, **k):
        orig(self, *a, **k)
        self.interval = 0.05
    worker.Heartbeat.__init__ = fast
    def slow(t):
        time.sleep(0.3)
        return "done slowly"
    rc = run(worker, sqs, slow)
    worker.Heartbeat.__init__ = orig
    ext = [c[1] for c in sqs.calls if c[0] == "visibility"]
    check("visibility extended while the task ran", len(ext) >= 2 and all(e["VisibilityTimeout"] == 30 for e in ext))
    sent = [json.loads(c[1]["MessageBody"]) for c in sqs.calls if c[0] == "send"]
    check("the answer reports the extensions", sent and sent[0]["visibility_extensions"] >= 2 and rc == 0)

    print("5. nothing waiting; user id scoping")
    sqs = FakeSQS([])
    check("no message exits 0 without sending or deleting", run(worker, sqs, lambda t: "x") == 0 and sqs.kinds() == ["receive"])
    check("a named user is scoped under tasks/", worker.parse(json.dumps({"prompt": "p", "user_id": "alice"}), "m")["user_id"] == "tasks/alice")
    check("no user is tasks", worker.parse(json.dumps({"prompt": "p"}), "m")["user_id"] == "tasks")
    scoped = worker.parse(json.dumps({"prompt": "p", "user_id": "alice"}), "m", "AROAEXAMPLEROLEID:alice-session")
    check("a named user is scoped under the sending principal, without the session name", scoped["user_id"] == "tasks/AROAEXAMPLEROLEID/alice")
    other = worker.parse(json.dumps({"prompt": "p", "user_id": "alice"}), "m", "AIDAOTHERUSERID")
    check("two producers naming the same user get different scopes", other["user_id"] == "tasks/AIDAOTHERUSERID/alice" and other["user_id"] != scoped["user_id"])
    check("a malformed SenderId adds no scope", worker.parse(json.dumps({"prompt": "p"}), "m", "bad sender!")["user_id"] == "tasks")

    failed = [n for n, ok in RESULTS if not ok]
    print(f"\n{len(RESULTS) - len(failed)}/{len(RESULTS)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
