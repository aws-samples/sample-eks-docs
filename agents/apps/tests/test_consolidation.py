"""Consolidation (memory rung 3, open source path) is wired the way the platform expects.

    python apps/tests/test_consolidation.py

What it checks, without a database, a gateway or Mem0 itself:

  1. Off means off: with AGENT_CONSOLIDATION_DB_SECRET_ARN unset the agent builds no memory manager
     and never imports Mem0, so the switch costs a default agent nothing.
  2. Mem0's configuration sends BOTH model calls to the gateway on the agent's own token, the
     embeddings to the same base URL the gateway serves /llm/<agent>/embeddings under, and the
     vector store to the host and database the Agent resource names, one table per agent.
  3. A table name is a safe identifier whatever the agent is called.
  4. A memory tier that is down does not refuse the turn: the agent serves without memory.
  5. The server scopes memory to the VERIFIED caller, with the user it names beneath that, so a
     caller cannot read someone else's memories by naming them.

The end-to-end behaviour -- a fact told in one session recalled in the next, and not for another
user -- is `scripts/exercise.sh memory` against a cluster.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

AGENTS_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(AGENTS_DIR / "common"))
sys.path.insert(0, str(AGENTS_DIR / "reference"))

os.environ.setdefault("AGENT_NAME", "research")

import app  # noqa: E402

failures = 0


def check(cond: bool, what: str) -> None:
    global failures
    print(("ok   " if cond else "FAIL ") + what)
    if not cond:
        failures += 1


# 1. Off.
os.environ.pop("AGENT_CONSOLIDATION_DB_SECRET_ARN", None)
check(app.consolidation_memory("research", "http://gw/llm/research", "tok") is None, "no secret ARN, no memory")
check("mem0" not in sys.modules, "Mem0 is not imported when consolidation is off")

# 2. The configuration.
os.environ.update(
    AGENT_CONSOLIDATION_DB_HOST="agent-semantic-recall-cluster-rw.agent-memory.svc.cluster.local",
    AGENT_CONSOLIDATION_DB_NAME="agentmemory",
    AGENT_CONSOLIDATION_EMBEDDING_MODEL="amazon.titan-embed-text-v2:0",
    AGENT_CONSOLIDATION_EMBEDDING_DIMS="1024",
    AGENT_MODEL="route-name",
    MEM0_DIR="/tmp/mem0-test",
)
cfg = app.mem0_config("research", "http://gw/llm/research", "the-token", {"user": "agent_memory", "password": "pw"})
vs, llm, emb = cfg["vector_store"]["config"], cfg["llm"]["config"], cfg["embedder"]["config"]
check(cfg["vector_store"]["provider"] == "pgvector", "the store is pgvector")
check(vs["host"].startswith("agent-semantic-recall-cluster-rw.") and vs["dbname"] == "agentmemory", "the store is the rung-2 tier")
check(vs["user"] == "agent_memory" and vs["password"] == "pw", "the login is the one read from Secrets Manager")
check(vs["collection_name"] == "mem0_research" and vs["embedding_model_dims"] == 1024, "one table per agent, sized to the model")
check(llm["openai_base_url"] == emb["openai_base_url"] == "http://gw/llm/research", "both model calls go to the agent's gateway route")
check(llm["api_key"] == emb["api_key"] == "the-token", "both carry the agent's own token")
check(emb["model"] == "amazon.titan-embed-text-v2:0" and emb["embedding_dims"] == 1024, "the embedder asks for the configured model and size")
check(cfg["history_db_path"] == "/tmp/mem0-test/history.db", "Mem0's local state is under MEM0_DIR, off the read-only root")

# 3. Identifiers.
check(app._table_name("Team-A.agent") == "mem0_team_a_agent", "an agent name becomes a safe table name")

# 4. Fail open.
os.environ["AGENT_CONSOLIDATION_DB_SECRET_ARN"] = "arn:aws:secretsmanager:us-west-2:000000000000:secret:x"


def refuse(_arn: str) -> dict:
    raise RuntimeError("secrets manager unreachable")


app._memory_login = refuse
app._MEM0["memory"] = None
try:
    result = app.consolidation_memory("research", "http://gw/llm/research", "tok", "u")
    check(result is None, "a memory tier that cannot be reached serves the turn without memory")
except Exception as exc:  # noqa: BLE001
    check(False, f"a memory failure raised instead of failing open: {exc!r}")

# 4b. The gateway adapter: a list of texts becomes one request per string, in order, and JSON mode
# is dropped -- the two shapes the gateway's Bedrock translation refuses.
from types import SimpleNamespace as NS  # noqa: E402

sent = {"emb": [], "chat": []}


def fake_embed(**kw):
    sent["emb"].append(kw["input"])
    return NS(data=[NS(index=0, embedding=[float(len(kw["input"]))])])


def fake_chat(**kw):
    sent["chat"].append(kw)
    return "ok"


mem = NS(embedding_model=NS(client=NS(embeddings=NS(create=fake_embed))),
         llm=NS(client=NS(chat=NS(completions=NS(create=fake_chat)))))
app.adapt_for_gateway(mem)
out = mem.embedding_model.client.embeddings.create(input=["a", "bbb"], model="m")
check(sent["emb"] == ["a", "bbb"], "a list of texts is sent one string per request")
check([d.embedding for d in out.data] == [[1.0], [3.0]] and [d.index for d in out.data] == [0, 1], "results come back in order")
mem.llm.client.chat.completions.create(model="m", messages=[], response_format={"type": "json_object"})
check("response_format" not in sent["chat"][-1], "json_object is dropped")
mem.llm.client.chat.completions.create(model="m", messages=[], response_format={"type": "json_schema"})
check("response_format" in sent["chat"][-1], "any other response_format is passed through")
mem.llm.client.chat.completions.create(model="m", messages=[], temperature=0.1, top_p=0.1)
check("top_p" not in sent["chat"][-1] and "temperature" not in sent["chat"][-1], "temperature and top_p are both dropped")

# 5. The server's scoping, read from its source rather than by starting it (it needs an issuer).
server_src = (AGENTS_DIR / "reference" / "server.py").read_text()
check('user_id = f"{subject}/{named_user}" if named_user else subject' in server_src,
      "the server scopes memory under the verified caller's subject")

# 6. The agent is told that what the person says is kept, whenever consolidation is on, whatever
# the system prompt: without it the model tells people nothing is stored while it is.
app_src = (AGENTS_DIR / "reference" / "app.py").read_text()
check("if memory is not None:\n        system_prompt = system_prompt + " in app_src and "MEMORY_NOTE = (" in app_src,
      "the memory note is appended to the system prompt when consolidation is on")

print(f"\n{'all passed' if failures == 0 else f'{failures} failed'}")
sys.exit(1 if failures else 0)
