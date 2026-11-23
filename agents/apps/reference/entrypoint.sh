#!/bin/sh
# Two modes, one image.
#
#   AGENT_SERVE=1   the HTTP server in server.py, for the chat UI, another agent, or a schedule.
#   unset           the one-shot CLI in app.py, which takes a prompt and exits.
#
# The CLI is the default so that an agent listens only when something asked it to. The Agent
# resource sets AGENT_SERVE when `expose` is not "none".
set -eu

# runtime: tasks. One task per pod, from the agent's queue; see worker.py.
if [ "${AGENT_WORKER:-}" = "1" ]; then
  exec python /app/worker.py
fi
if [ "${AGENT_SERVE:-}" = "1" ]; then
  exec python /app/server.py
fi

exec python /app/app.py "$@"
