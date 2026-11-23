# Workloads

This directory holds the code for the workloads the templates run: the reference agent, the MCP server, the chat UI, the consent receiver, the evaluation runner, and a Lambda tool. Read it to build the images, or to write an agent image of your own. Nothing in `terraform/` or `gitops/` depends on this code, only on the environment variables in [The contract an agent image satisfies](#the-contract-an-agent-image-satisfies), so you can replace any of these images with your own.

## Build the images

`scripts/build-images.sh` builds and pushes every image whose ECR repository exists and whose tag isn't in ECR yet, so a rerun after you turn on a layer builds only the repositories that layer added. With `--root`, it builds your working tree in the stack's AWS CodeBuild project (`enable_image_build`, on by default), for x86_64 like EKS Auto Mode's default node pool, so it needs only the AWS CLI:

```bash
./scripts/build-images.sh --root terraform/aws-services
```

The repositories are immutable, so to rebuild an image pass a new `--tag` and point your `Agent` resources (and `chatUi.imageTag`, for the chat UI) at it.

To build one image by hand, build from this directory, because every Dockerfile copies files from `common/`, and build for x86_64. An arm64 image pulls successfully and then fails with `exec format error`.

```bash
cd apps
docker build -f reference/Dockerfile -t 111122223333.dkr.ecr.us-west-2.amazonaws.com/agents/reasoning:v2 .
docker build -f reference/Dockerfile --build-arg MODEL_ROUTE=bedrock-direct \
  -t 111122223333.dkr.ecr.us-west-2.amazonaws.com/agents/reasoning-direct:v2 .
```

To skip the build, set `agent_image_registry` in either Terraform root to a registry of your own that already holds these images. The same repository paths are appended to it.

## What's in this directory

| Directory | What it is | Image (ECR repository) | How it's tested |
|---|---|---|---|
| [`reference/`](reference) | The reference agent: a Strands agent wired to every contract below, with a one-shot CLI and an HTTP server. See [its README](reference/README.md). | `agents/reasoning` (default, `MODEL_ROUTE=gateway`) and `agents/reasoning-direct` (`MODEL_ROUTE=bedrock-direct`). `agents/execution`, the execution tier in [`reasoning-execution-split`](../gitops/examples/reasoning-execution-split), is the reasoning image retagged. | `test_model_path`, `test_session_state`, `test_consolidation`, `test_agentcore_memory`, `test_tasks`, `test_services` |
| [`mcp-server/`](mcp-server) | Three tools (`get_time`, `describe_cluster`, `lookup_order`) over MCP streamable HTTP. Requires a projected token with audience `mcp-server` when `MCP_REQUIRE_TOKEN=true`. Runs unsandboxed in namespace `mcp-servers` on both paths, from [`gitops/examples/mcp-server`](../gitops/examples/mcp-server). | `agents/mcp-server` | `test_services`, `test_gates` |
| [`chat-ui/`](chat-ui) | A static page and an SSE proxy, so a person can talk to an agent. Verifies the load balancer's signed OIDC header and refuses a request without one, then calls the agent on its own token. Turned on with `enable_chat_ui`; see [`gitops/examples/chat-ui`](../gitops/examples/chat-ui). | `agents/chat-ui` | `test_services`, `test_relay` |
| [`consent-receiver/`](consent-receiver) | The OAuth consent receiver for third-party credentials: one person approves once and the gateway holds the token. Reached only through `kubectl port-forward`. Turned on with `oauth_consent` (open source) or `agentcore_consent` (AWS services); chart in `gitops/charts/consent-receiver`. | `agents/consent-receiver` | No unit test. See [Third-party credentials](https://docs.aws.amazon.com/eks/latest/userguide/agents-third-party-credentials.html). |
| [`evals/`](evals) | The evaluation runner: Strands Evals grading sampled sessions (`online`) or declared cases against deployed agents as a release gate (`experiment`). The judge calls the model through the gateway on the pod's own token. Turned on with `enable_evaluations`; chart in `gitops/charts/agent-evals`. | `agents/evals` | `test_evals_runner` (needs `evals/requirements.txt`) |
| [`common/`](common) | `cluster_auth.py`, the token verifier the agent server, the MCP server, and the chat UI share, and `person_access.py`, the tools that act with a person's authority. Copied into each image. | None | `test_gates`, `test_person_access` |
| [`mcp-lambda/`](mcp-lambda) | A Lambda tool backend for an AgentCore Gateway target, on the AWS services path. See [its README](mcp-lambda/README.md). | None (a Lambda zip) | The `tools` phase of `scripts/exercise.sh`, once the target is wired |
| [`tests/`](tests) | Unit tests for the credential checks, the model path, the chat UI relay, saved sessions, consolidation, and the evaluation runner. Each file runs as a script, for example `python3 apps/tests/test_gates.py`. | None | `scripts/validate.sh` runs every file whose dependencies import |

## The contract an agent image satisfies

The `Agent` resource sets these variables, so an agent never assembles an endpoint itself. Any image that reads them works as an `Agent`'s `image`.

| Variable | What it is |
|---|---|
| `AGENT_GATEWAY_URL`, `OPENAI_BASE_URL` | The model endpoint, the same value under both names so an agent written for the OpenAI SDK finds it. Set only when the platform has a gateway. |
| `AGENT_IDENTITY_TOKEN_FILE` | The projected token the agent presents to the gateway as its API key. It rotates, so read it for each request rather than once at startup. |
| `AGENT_MODEL` | The model to ask for. Through a gateway, a name from the gateway's catalog; without one, an Amazon Bedrock model ID (default `us.anthropic.claude-sonnet-5-5`) with `AWS_BEDROCK_REGION`. |
| `AGENT_MCP_URL`, `AGENT_MCP_TOKEN_FILE` | The tool endpoint, and a token for the MCP server's own audience when the `Agent` sets `mcpAudience`. |
| `AGENT_NAME`, `AGENT_SYSTEM_PROMPT`, `AGENT_SERVE` | The agent's name, its prompt, and whether to run the HTTP server rather than the CLI. |
| `AGENT_INBOUND_AUDIENCE`, `AGENT_ALLOWED_CALLER_NAMESPACES`, `CLUSTER_OIDC_ISSUER` | What a caller's token must carry to reach the agent's server. |
| `CHECKPOINT_BUCKET`, `CHECKPOINT_PREFIX` | The agent's own S3 prefix, with `enable_checkpoints`. Its IAM role is scoped to that prefix. |
| `SESSION_STATE_ENDPOINT` | The session cache, with `enable_session_state`. |
| `AGENT_VECTOR_BUCKET_ARN`, `AGENT_VECTOR_INDEXES` | Semantic recall on S3 Vectors, with `enable_semantic_recall` on the AWS services path. |
| `AGENT_MEMORY_ID`, `AGENT_MEMORY_NAMESPACES` | AgentCore Memory, with `enable_consolidation` on the AWS services path. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` and the other `OTEL_*` variables | The telemetry collector, with `enable_observability`. |
| `AWS_CONTAINER_CREDENTIALS_FULL_URI` | EKS Pod Identity, which delivers the agent's IAM role. |

Every span of a turn also carries `session.id`. Langfuse, AgentCore Evaluations, and the evaluation runner all group a conversation's turns on it, so an agent that omits it still serves traffic but none of its conversations can be graded. The reference agent sets it through Strands `trace_attributes`, takes it from a caller as `session_id` on `/chat`, and returns it in `X-Session-Id`.

The default image, `agents/reasoning`, holds no model credential: it reaches a model only through the gateway, and refuses to start without one. `agents/reasoning-direct` is for a platform with no gateway, where it calls Amazon Bedrock on the agent's own role and gives up the gateway's budget, failover, tool policy, and audit point. It's the image the base uses, before you turn on `enable_gateway`; [AI agents on Amazon EKS](https://docs.aws.amazon.com/eks/latest/userguide/agents.html) covers the trade.
