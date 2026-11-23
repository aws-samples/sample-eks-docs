"""Consolidation on the AWS services path: the reference agent writes to and reads from AgentCore memory.

    python apps/tests/test_agentcore_memory.py

With a stand-in for the bedrock-agentcore client, no AWS call:

  1. Off means off: without AGENT_MEMORY_ID the agent builds no AgentCore memory manager.
  2. The namespace paths: /agents/{actorId}/{sessionId} becomes /agents/<actor>/, so a record from
     an earlier session is found; a template without {actorId} is not searched for one person.
  3. Each turn is written as one conversational event, with the actor derived from the verified
     user_id and a session id AgentCore accepts; tool blocks are not sent.
  4. Search uses namespacePath and returns the records' text.
  5. Two users get two actors.

The end-to-end behaviour -- a person's fact told through the chat UI recalled in a later
conversation, and not for another person -- is `scripts/exercise.sh people` against a cluster.
"""

from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

AGENTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS_DIR / "common"))
sys.path.insert(0, str(AGENTS_DIR / "reference"))
os.environ.setdefault("AGENT_NAME", "research")

import boto3  # noqa: E402

import app  # noqa: E402

failures = 0


def check(cond: bool, what: str) -> None:
    global failures
    print(f"{'ok  ' if cond else 'FAIL'} {what}")
    failures += 0 if cond else 1


class FakeClient:
    def __init__(self):
        self.events, self.searches = [], []

    def create_event(self, **kw):
        self.events.append(kw)
        return {"event": {"eventId": "e1"}}

    def retrieve_memory_records(self, **kw):
        self.searches.append(kw)
        return {"memoryRecordSummaries": [{"content": {"text": "The user's favourite colour is teal."},
                                           "namespaces": ["/agents/x/s1"], "score": 0.9}]}


fake = FakeClient()
boto3.client = lambda *a, **k: fake

# 1
os.environ.pop("AGENT_MEMORY_ID", None)
check(app.agentcore_memory("research", "sub-a", "s1") is None, "no AGENT_MEMORY_ID, no AgentCore memory manager")

# 2
actor = app._agentcore_actor("system:serviceaccount:agents:chat-ui/a1b2")
check(app.agentcore_namespace_paths("/agents/{actorId}/{sessionId}", actor) == [f"/agents/{actor}/"],
      "a session-scoped template is searched under the person's own prefix")
check(app.agentcore_namespace_paths("/shared/{sessionId}", actor) == [],
      "a template without {actorId} is not searched for one person")
check(app._agentcore_session("a.b:c") == "a-b-c", "a session id is made to fit AgentCore's pattern")

# 3, 4
os.environ.update({"AGENT_MEMORY_ID": "mem_agents-abcdefghij", "AGENT_MEMORY_NAMESPACES": "/agents/{actorId}/{sessionId}",
                   "AWS_REGION": "us-west-2"})
manager = app.agentcore_memory("research", "system:serviceaccount:agents:chat-ui/a1b2", "s.1")
check(manager is not None, "with AGENT_MEMORY_ID the agent builds a memory manager")
store = app.AgentCoreMemoryStore("mem_agents-abcdefghij", actor, "s-1", [f"/agents/{actor}/"], "us-west-2")
messages = [
    {"role": "user", "content": [{"text": "My favourite colour is teal."}]},
    {"role": "assistant", "content": [{"toolUse": {"name": "search_memory"}}, {"text": "Got it."}]},
]
asyncio.run(store.add_messages(messages))
ev = fake.events[-1]
check(ev["actorId"] == actor and ev["sessionId"] == "s-1" and ev["memoryId"] == "mem_agents-abcdefghij",
      "the event names the memory, the person's actor and the session")
check([p["conversational"]["role"] for p in ev["payload"]] == ["USER", "ASSISTANT"]
      and ev["payload"][1]["conversational"]["content"]["text"] == "Got it.",
      "each message is one conversational entry, tool blocks left out")
found = asyncio.run(store.search("favourite colour"))
check(fake.searches[-1].get("namespacePath") == f"/agents/{actor}/" and "namespace" not in fake.searches[-1],
      "search is by namespacePath, so earlier sessions' records are found")
check([e.content for e in found] == ["The user's favourite colour is teal."], "search returns the records' text")

# 5
check(app._agentcore_actor("x/alice") != app._agentcore_actor("x/bob"), "two people get two actors")

print(f"\n{'all passed' if failures == 0 else f'{failures} failed'}")
sys.exit(1 if failures else 0)
