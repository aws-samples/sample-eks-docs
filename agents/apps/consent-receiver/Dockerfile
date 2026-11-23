# The OAuth consent receiver (app.py). Runs as a non-root user; the pod sets a read-only root.
# Build from agents/:  docker build -f consent-receiver/Dockerfile -t <ecr>/agents/consent-receiver:v1 .
FROM public.ecr.aws/docker/library/python:3.13-slim
COPY consent-receiver/requirements.txt /tmp/requirements.txt
# Debian's security updates that the base image tag does not carry yet; pip check fails the build on
# a dependency conflict, and pip is then removed, since nothing installs at runtime.
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y && rm -rf /var/lib/apt/lists/* \
 && pip install --no-cache-dir -r /tmp/requirements.txt && rm /tmp/requirements.txt \
 && pip check && python -m pip uninstall -y pip \
 && groupadd --gid 10001 consent \
 && useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin consent
COPY --chown=root:root consent-receiver/app.py /app/app.py
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 HOME=/tmp
USER 10001
ENTRYPOINT ["python", "/app/app.py"]
