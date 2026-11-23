# The reference agent

A small Strands agent wired to every contract the platform defines. Read it before you write an agent image of your own: it shows what an agent has to agree with the platform on, and the environment variables it reads are listed in [the workloads README](../README.md#the-contract-an-agent-image-satisfies).

## Two images

One Dockerfile builds two images, and the build argument `MODEL_ROUTE` is the only difference between them. `scripts/build-images.sh` builds both.

| Image | `MODEL_ROUTE` | How it reaches a model |
|---|---|---|
| `agents/reasoning` (default) | `gateway` | Only through the gateway, at `OPENAI_BASE_URL`. It has no code path to Amazon Bedrock and refuses to start without a gateway endpoint. |
| `agents/reasoning-direct` | `bedrock-direct` | Through the gateway when one is set. Otherwise it calls Amazon Bedrock on the agent's own Pod Identity role, in `AWS_BEDROCK_REGION`, with the model in `AGENT_MODEL` (default Claude Sonnet 5.5, `us.anthropic.claude-sonnet-5-5`). |

Choosing the direct route is choosing an image, so it's visible in the `Agent`'s `image` field and in the registry rather than hidden in a runtime setting. [Deploy an agent](https://docs.aws.amazon.com/eks/latest/userguide/agents-application-setup.html) describes what the direct route gives up.

Model names depend on the route. Through AgentGateway on the open source path, the default is the route name `bedrock-claude-sonnet`. Through AgentCore Gateway on the AWS services path, `model.gatewayModelId` is required and the examples use `bedrock/openai.gpt-oss-120b`, because the gateway's catalog has no Claude Sonnet model. Claude Sonnet 5.5 rejects `temperature` and `top_p`, so the agent sets no sampling parameters.

## What it does at each contract

| Contract | What the agent does |
|---|---|
| Model credential | Presents the projected token from `AGENT_IDENTITY_TOKEN_FILE` as the OpenAI client's `api_key`, and builds the model client for each turn so a rotated token is picked up. `OPENAI_API_KEY` is used only when no token file is set, for running outside the cluster. |
| Tools | Loads the tool catalog from the MCP endpoint at `AGENT_MCP_URL` on each turn, presenting the gateway token or, when set, the token in `AGENT_MCP_TOKEN_FILE`. If the endpoint is down it serves without tools, unless `AGENT_TOOLS_REQUIRED=true`. `AGENT_GATEWAY_TOOLS=off` turns tools off. |
| Saved conversations | Saves the conversation after each turn and reloads it for the same caller and session: in S3 under `CHECKPOINT_PREFIX` when `CHECKPOINT_BUCKET` is set, or on `/workspace` when `AGENT_WORKSPACE_PERSISTENT=true`. The key combines the verified caller and the session ID, so one caller can't load another's conversation. |
| Consolidated memory | Uses Mem0 as a library on the pgvector tier, with its model calls through the same gateway, when `AGENT_CONSOLIDATION_DB_SECRET_ARN` is set (open source path, `enable_consolidation`). |
| Telemetry | Exports OpenTelemetry traces and metrics to `OTEL_EXPORTER_OTLP_ENDPOINT`, with `session.id` on every span. With no endpoint set, it logs a warning and exports nothing. |

Missing configuration fails at startup rather than on the first turn, so an agent without its endpoint or credential stops its rollout instead of passing its readiness probe and failing on traffic.

## CLI and server

`AGENT_SERVE=1` runs the HTTP server in `server.py`; otherwise the entrypoint runs the one-shot CLI in `app.py`. The `Agent` resource sets `AGENT_SERVE` when `expose` isn't `none`, so an agent listens only when you ask it to.

| | CLI (`app.py`) | Server (`server.py`) |
|---|---|---|
| Takes | One prompt, from argv or stdin | `POST /chat` with `{"prompt": "...", "session_id": "..."}`; `session_id` is optional |
| Returns | The finished turn | Server-sent events, one `data:` line per chunk, and the session ID in `X-Session-Id` |
| Who may call it | Whoever can run the pod | A caller presenting a projected service account token whose audience is this agent (`AGENT_INBOUND_AUDIENCE`), from a namespace in `AGENT_ALLOWED_CALLER_NAMESPACES` |

The server verifies the caller's token itself, against the cluster's OIDC issuer, because `mesh_mode` is `none` by default and a gate that depends on an optional component is no gate on the default configuration. Where the mesh is on, both checks apply. `/healthz` is unauthenticated: it takes no input and returns no agent data.

## Run it locally

```bash
cd apps/reference
AGENT_NAME=research \
AGENT_GATEWAY_URL=http://localhost:8080/llm/research \
AGENT_IDENTITY_TOKEN_FILE=./token \
python3 app.py "what is the status of order ORD-12345?"
```

## Build it

Build from `apps/`, not from this directory, because the image copies `common/cluster_auth.py` and `common/person_access.py`. [Build the images](../README.md#build-the-images) has the commands.

The `Agent` resource runs the pod as uid 10001 with a read-only root filesystem and every capability dropped, and the Dockerfile is written for that: dependencies install into a virtualenv rather than with `pip install --user`, and `HOME` and `XDG_CACHE_HOME` point at `/tmp`. If you add a dependency that writes a cache, point it at `/tmp` rather than making the root filesystem writable.

`strands-agents` depends on `boto3`, so every image built from this directory carries an AWS SDK even though the default image never calls Bedrock with it. What contains model-generated code that imports it is the agent's IAM role and the network policy, not the image.
