# The reference agent image.
#
# Built to run under runtimeClassName: isolated-sandbox with the security context the Agent resource
# sets, which constrains this Dockerfile more than it might look:
#
#   runAsNonRoot, runAsUser 10001   so nothing may be owned by root or need to write outside the
#                                   writable mounts
#   readOnlyRootFilesystem: true    so the image cannot write anywhere except /tmp and /workspace,
#                                   which the pod mounts as emptyDir
#   capabilities drop ALL           so nothing may need a capability, including binding a low port
#
# An image that works outside the sandbox and fails inside it usually fails on one of those three.
# The notes below say which choice is there for which.

# BUILD CONTEXT IS agents/, not this directory, because the image needs common/cluster_auth.py --
# the one implementation of the credential check the agent server, the MCP server and the chat UI
# all share. Build it with:
#
#     docker build -f reference/Dockerfile -t "$ECR:v1" .
#
# run from agents/. A build from this directory cannot see common/ and fails on the COPY below.

FROM public.ecr.aws/docker/library/python:3.13-slim AS build

# A virtualenv rather than a --user install, because readOnlyRootFilesystem means HOME is not
# writable at runtime and a --user install resolves against it.
ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

COPY reference/requirements.txt /tmp/requirements.txt
# pip check fails the build on a dependency conflict; the venv's own pip is then removed, so the
# image the final stage copies carries no installer.
RUN pip install --no-cache-dir -r /tmp/requirements.txt && pip check && pip uninstall -y pip

# ---------------------------------------------------------------------------

FROM public.ecr.aws/docker/library/python:3.13-slim

# Debian's security updates that the base image tag does not carry yet, and no pip in the image:
# nothing installs at runtime, and pip's vendored urllib3 and msgpack are what an image scan flags.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
 && rm -rf /var/lib/apt/lists/* \
 && python -m pip uninstall -y pip

# The uid the Agent resource runs the pod as. Declared here as well so the image is correct when run
# outside this stack, and so a file this Dockerfile creates is owned by the right user rather than
# by root and unreadable.
ARG AGENT_UID=10001
ARG AGENT_GID=10001

RUN groupadd --gid "$AGENT_GID" agent \
 && useradd --uid "$AGENT_UID" --gid "$AGENT_GID" --create-home --shell /usr/sbin/nologin agent

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
COPY --from=build --chown=root:root "$VIRTUAL_ENV" "$VIRTUAL_ENV"

WORKDIR /workspace
COPY --chown=root:root reference/app.py /app/app.py

# The HTTP server, and the credential check it gates /chat with. app.py still runs as a one-shot
# CLI; server.py is what the chat UI and other in-cluster callers call.
COPY --chown=root:root reference/server.py /app/server.py
COPY --chown=root:root reference/worker.py /app/worker.py
COPY --chown=root:root common/cluster_auth.py /app/cluster_auth.py

COPY --chown=root:root common/person_access.py /app/person_access.py

# Unbuffered, so a log line appears when it is written rather than when the buffer fills. On an
# agent that is the difference between watching a turn and waiting for one to finish.
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# No HOME write at runtime: the venv is baked and nothing installs on start. If you add a dependency
# that writes a cache to HOME, point it at /tmp instead of making the root filesystem writable.
ENV HOME=/tmp
ENV XDG_CACHE_HOME=/tmp

# OpenTelemetry with the GenAI semantic conventions, which is the instrumentation both paths share.
# The endpoint is set by the Agent resource per path, so it is not baked here -- that is what keeps
# the choice of backend reversible without rebuilding the agent.
ENV OTEL_TRACES_EXPORTER=otlp
ENV OTEL_METRICS_EXPORTER=otlp
ENV OTEL_LOGS_EXPORTER=otlp

# WHICH IMAGE THIS IS: gateway (agents/reasoning, the default) or bedrock-direct
# (agents/reasoning-direct). One Dockerfile, two images, so the code and the dependencies are the
# same and only the model route differs:
#
#   docker build -f reference/Dockerfile -t <ecr>/agents/reasoning:v1 .
#   docker build -f reference/Dockerfile --build-arg MODEL_ROUTE=bedrock-direct \
#     -t <ecr>/agents/reasoning-direct:v1 .
#
# The default image has no route to Bedrock in its code and refuses to start without a gateway. The
# direct image calls Bedrock on the agent's own role when the platform has no gateway, which gives up
# the budget, failover, tool policy and audit point the gateway provides -- see build_direct_model in
# app.py. Baked as an ENV here rather than set by the Agent resource, so choosing the direct route is
# choosing an image, a decision visible in the Agent's `image` field and in the registry.
ARG MODEL_ROUTE=gateway
RUN case "$MODEL_ROUTE" in gateway|bedrock-direct) ;; \
      *) echo "MODEL_ROUTE must be gateway or bedrock-direct, not '$MODEL_ROUTE'" >&2; exit 1 ;; esac
ENV AGENT_IMAGE_MODEL_ROUTE=$MODEL_ROUTE

USER agent

# No EXPOSE and no host port, in either mode.
#
# AGENT_SERVE=1 runs the HTTP server, which binds a container port that a ClusterIP Service reaches;
# the route in front of that Service is what governs exposure, and the Agent resource only creates
# one when `expose` says so. Unset, this is the one-shot CLI and nothing listens at all.
#
# Defaulting to the CLI means an agent only serves traffic when something asked it to.
COPY --chown=root:root reference/entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
