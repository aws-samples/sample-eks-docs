"""One task, one pod: the reference agent as a task worker (Agent runtime: tasks).

KEDA starts this pod when a message is waiting on the agent's task queue. It:

  1. takes ONE message (long poll; exits 0 if another pod took it first),
  2. keeps it invisible to other pods while the task runs, by extending its visibility timeout every
     third of AGENT_TASK_VISIBILITY_SECONDS -- so a task longer than the timeout is not handed to a
     second pod,
  3. runs the turn with the same agent the HTTP server builds (app.build_agent): the same gateway,
     tools, memory and saved sessions,
  4. sends {"task_id", "status": "done", "answer"} to the result queue, then deletes the message.

A task that fails is NOT deleted: its visibility is reset to zero so another pod can try, and after
the queue's maxReceiveCount SQS moves it to the dead-letter queue. The pod exits non-zero so the
Job records the failure. A task the model stops at its output limit is not a failure to retry --
every attempt would stop at the same place -- so it is answered "incomplete", with the partial
text, and deleted.

THE MESSAGE is JSON: {"prompt": "...", "task_id": "...", "user_id": "..."}. Only prompt is required.
task_id defaults to the message id.

user_id IS A LABEL, NOT AN IDENTITY. It names whose memories and saved session the task uses, and it
is scoped beneath the producer that SQS verified: the IAM principal in the message's SenderId (a
role's or user's unique id, without the role session name). The memory key is
tasks/<principal>/<user_id>. A producer can name any user, but only within its own scope, so two
producers naming the same user never share memories, and no producer reaches the memories of a
caller of the HTTP server, whose user ids sit under that caller's own verified subject. Nothing in
the message proves which person a task is for, and a task never acts with a person's authority: it
runs with this agent's own permissions. Who may send a task at all is the queue's IAM.
"""

from __future__ import annotations

import json
import logging
import os
import re
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

log = logging.getLogger("worker")

TASK_QUEUE = os.environ.get("AGENT_TASK_QUEUE_URL", "")
RESULT_QUEUE = os.environ.get("AGENT_RESULT_QUEUE_URL", "")
VISIBILITY = int(os.environ.get("AGENT_TASK_VISIBILITY_SECONDS", "300") or 300)
REGION = os.environ.get("AWS_REGION", "") or os.environ.get("AWS_DEFAULT_REGION", "")
ID_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")
MAX_PROMPT = 20000


def sender_principal(sender_id: str) -> str:
    """The stable part of SQS's SenderId: a role's unique id without the session name after the
    colon, or a user's unique id. Empty when SQS gave none."""
    principal = (sender_id or "").split(":", 1)[0].strip()
    return principal if ID_PATTERN.match(principal or "-") and principal else ""


def parse(body: str, message_id: str, sender_id: str = "") -> dict:
    """The task, or ValueError with the reason. Bounded and pattern-checked like the HTTP server's
    inputs, because the task id and user id become session keys and span attributes. The user id is
    scoped beneath the sending IAM principal that SQS verified."""
    try:
        task = json.loads(body)
    except json.JSONDecodeError as exc:
        raise ValueError(f"the message body is not JSON: {exc}") from exc
    if not isinstance(task, dict):
        raise ValueError("the message body must be a JSON object")
    prompt = str(task.get("prompt") or "").strip()
    if not prompt:
        raise ValueError("prompt is required")
    if len(prompt) > MAX_PROMPT:
        raise ValueError(f"prompt is longer than {MAX_PROMPT} characters")
    task_id = str(task.get("task_id") or message_id).strip()
    user = str(task.get("user_id") or "").strip()
    for name, value in (("task_id", task_id), ("user_id", user)):
        if value and not ID_PATTERN.match(value):
            raise ValueError(f"{name} must be 1-128 characters of letters, digits and . _ : -")
    scope = "/".join(p for p in ("tasks", sender_principal(sender_id)) if p)
    return {"prompt": prompt, "task_id": task_id, "user_id": f"{scope}/{user}" if user else scope}


class Heartbeat(threading.Thread):
    """Extends the message's visibility while the task runs."""

    def __init__(self, sqs, receipt: str) -> None:
        super().__init__(daemon=True)
        self.sqs, self.receipt, self.stop = sqs, receipt, threading.Event()
        self.extensions = 0
        self.interval = max(10, VISIBILITY // 3)

    def run(self) -> None:
        while not self.stop.wait(self.interval):
            try:
                self.sqs.change_message_visibility(QueueUrl=TASK_QUEUE, ReceiptHandle=self.receipt, VisibilityTimeout=VISIBILITY)
                self.extensions += 1
                log.info("task still running; visibility extended by %ss (%d)", VISIBILITY, self.extensions)
            except Exception as exc:  # noqa: BLE001 - keep working; the task may still finish in time
                log.warning("could not extend the task's visibility: %s", exc)


class Incomplete(Exception):
    """The model stopped at its output limit. The same task would stop there again, so this is an
    answer (with what was written), not a failure to retry."""

    def __init__(self, partial: str) -> None:
        super().__init__("the model reached its maximum output length")
        self.partial = partial


def run_turn(task: dict) -> str:
    import contextlib
    import io

    import app

    agent, _ = app.build_agent(session_id=task["task_id"], user_id=task["user_id"])
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            result = agent(task["prompt"])
    except Exception as exc:
        if type(exc).__name__ != "MaxTokensReachedException":
            raise
        last = (agent.messages or [{}])[-1]
        text = "".join(b.get("text", "") for b in last.get("content", []) if isinstance(b, dict)) if last.get("role") == "assistant" else ""
        raise Incomplete(text.strip()) from exc
    return str(result).strip()


def main() -> int:
    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(name)s %(message)s")
    if not TASK_QUEUE or not RESULT_QUEUE:
        log.error("AGENT_TASK_QUEUE_URL and AGENT_RESULT_QUEUE_URL are required; the Agent resource sets both for runtime: tasks")
        return 2

    import boto3

    sqs = boto3.client("sqs", region_name=REGION)
    got = sqs.receive_message(QueueUrl=TASK_QUEUE, MaxNumberOfMessages=1, WaitTimeSeconds=20,
                              VisibilityTimeout=VISIBILITY, AttributeNames=["ApproximateReceiveCount", "SenderId"])
    messages = got.get("Messages") or []
    if not messages:
        log.info("no task waiting (another pod took it); exiting")
        return 0
    msg = messages[0]
    receipt = msg["ReceiptHandle"]
    attempt = msg.get("Attributes", {}).get("ApproximateReceiveCount", "?")

    try:
        task = parse(msg.get("Body", ""), msg["MessageId"], msg.get("Attributes", {}).get("SenderId", ""))
    except ValueError as exc:
        # A malformed task can never succeed: answer with the reason and drop it, rather than let it
        # cycle to the dead-letter queue as if it were a transient failure.
        log.warning("refused task %s: %s", msg["MessageId"], exc)
        sqs.send_message(QueueUrl=RESULT_QUEUE, MessageBody=json.dumps({"task_id": msg["MessageId"], "status": "refused", "error": str(exc)}))
        sqs.delete_message(QueueUrl=TASK_QUEUE, ReceiptHandle=receipt)
        return 0

    log.info("task %s (attempt %s): %d chars", task["task_id"], attempt, len(task["prompt"]))
    beat = Heartbeat(sqs, receipt)
    beat.start()
    started = time.time()
    try:
        answer = run_turn(task)
        # AN EMPTY TURN IS USUALLY A ONE-OFF. The model can occasionally return no text for the
        # User Guide's example task, and the next attempt answers. Ask once more before reporting
        # it, as the guide tells a person to do with a chat reply that streams only [DONE].
        if not answer:
            log.warning("task %s: the model returned no text; asking once more", task["task_id"])
            answer = run_turn(task)
    except Incomplete as inc:
        # Deterministic: a retry stops at the same limit, so answer and delete. Split the task, or
        # raise the model's output limit, to get the rest.
        beat.stop.set()
        log.warning("task %s stopped at the model's output limit after %.1fs", task["task_id"], time.time() - started)
        sqs.send_message(QueueUrl=RESULT_QUEUE, MessageBody=json.dumps({
            "task_id": task["task_id"], "status": "incomplete", "answer": inc.partial,
            "error": str(inc), "seconds": round(time.time() - started, 1), "visibility_extensions": beat.extensions,
        }))
        sqs.delete_message(QueueUrl=TASK_QUEUE, ReceiptHandle=receipt)
        return 0
    except Exception:  # noqa: BLE001
        log.exception("task %s failed", task["task_id"])
        beat.stop.set()
        # Back on the queue now rather than after the visibility timeout. After maxReceiveCount
        # attempts SQS moves it to the dead-letter queue.
        try:
            sqs.change_message_visibility(QueueUrl=TASK_QUEUE, ReceiptHandle=receipt, VisibilityTimeout=0)
        except Exception:  # noqa: BLE001
            pass
        return 1
    beat.stop.set()

    # NO TEXT IS NOT AN ANSWER. A model can end a turn with nothing to say -- on the AWS services
    # path with a gateway model, the UG's own example task can come back "done" with "" -- and a
    # producer reading "done" would take an empty report as the report. After the one retry above,
    # say it is incomplete, with the reason, as for a task stopped at the output limit, and answer
    # and delete it rather than return it to the queue.
    status, error = ("done", None) if answer else ("incomplete", "the model returned no text")
    if not answer:
        log.warning("task %s: the model returned no text", task["task_id"])

    sqs.send_message(QueueUrl=RESULT_QUEUE, MessageBody=json.dumps({
        "task_id": task["task_id"], "status": status, "answer": answer, **({"error": error} if error else {}),
        "seconds": round(time.time() - started, 1), "visibility_extensions": beat.extensions,
    }))
    sqs.delete_message(QueueUrl=TASK_QUEUE, ReceiptHandle=receipt)
    log.info("task %s done in %.1fs", task["task_id"], time.time() - started)
    return 0


if __name__ == "__main__":
    sys.exit(main())
