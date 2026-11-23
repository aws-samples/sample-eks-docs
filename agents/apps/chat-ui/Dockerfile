# The operator chat UI image.
#
# Built to run under runtimeClassName: isolated-sandbox with the same security context the Agent
# resource sets: runAsNonRoot as uid 10001, readOnlyRootFilesystem, all capabilities dropped. An
# image that works outside the sandbox and fails inside it usually fails on one of those three.
#
# BUILD CONTEXT IS agents/, not this directory, because the image needs common/cluster_auth.py --
# the one implementation of the credential check all three services share. Build it with:
#
#     docker build -f chat-ui/Dockerfile -t "$ECR:v1" .
#
# run from agents/. A build from this directory cannot see common/ and fails on the COPY below.

FROM public.ecr.aws/docker/library/python:3.13-slim AS build

# A virtualenv rather than a --user install: readOnlyRootFilesystem means HOME is not writable at
# runtime, and a --user install resolves against it.
ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

COPY chat-ui/requirements.txt /tmp/requirements.txt
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

RUN useradd --uid 10001 --create-home --shell /usr/sbin/nologin chatui

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
COPY --from=build --chown=root:root /opt/venv /opt/venv

WORKDIR /app
COPY --chown=root:root chat-ui/app.py /app/app.py
COPY --chown=root:root common/cluster_auth.py /app/cluster_auth.py

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# No HOME write at runtime: the venv is baked and nothing installs on start.
ENV HOME=/tmp
ENV XDG_CACHE_HOME=/tmp

USER chatui

# No EXPOSE, and no host port. The pod publishes nothing; a ClusterIP Service is what reaches this
# port, and the route in front of it is what governs exposure. See gitops/examples/chat-ui.
ENTRYPOINT ["python", "/app/app.py"]
