# The evaluation runner image.
#
# BUILD CONTEXT IS agents/, like the other images here, so every build in this directory is the same
# command:
#
#     docker build -f evals/Dockerfile -t "$ECR/agents/evals:v1" .
#
# Runs as a non-root uid with a read-only root filesystem and no capabilities, under the restricted
# Pod Security profile the agent-evals namespace enforces. It writes nothing but /tmp.

FROM public.ecr.aws/docker/library/python:3.13-slim AS build
ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv "$VIRTUAL_ENV"
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
COPY evals/requirements.txt /tmp/requirements.txt
# pip check fails the build on a dependency conflict; the venv's own pip is then removed, so the
# image the final stage copies carries no installer.
RUN pip install --no-cache-dir -r /tmp/requirements.txt && pip check && pip uninstall -y pip

FROM public.ecr.aws/docker/library/python:3.13-slim

# Debian's security updates that the base image tag does not carry yet, and no pip in the image:
# nothing installs at runtime, and pip's vendored urllib3 and msgpack are what an image scan flags.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
 && rm -rf /var/lib/apt/lists/* \
 && python -m pip uninstall -y pip
ARG EVALS_UID=10001
ARG EVALS_GID=10001
RUN groupadd --gid "$EVALS_GID" evals \
 && useradd --uid "$EVALS_UID" --gid "$EVALS_GID" --create-home --shell /usr/sbin/nologin evals

ENV VIRTUAL_ENV=/opt/venv
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
COPY --from=build --chown=root:root "$VIRTUAL_ENV" "$VIRTUAL_ENV"
COPY --chown=root:root evals/runner.py /app/runner.py

ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
# HOME and the caches point at /tmp because the root filesystem is read-only.
ENV HOME=/tmp
ENV XDG_CACHE_HOME=/tmp

USER evals
WORKDIR /tmp
ENTRYPOINT ["python", "/app/runner.py"]
