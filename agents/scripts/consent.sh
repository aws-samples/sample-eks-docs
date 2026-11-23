#!/usr/bin/env bash
#
# Open the OAuth consent receiver in your browser for one approval -- one command instead of two
# port-forwards.
#
#   ./scripts/consent.sh --cluster <name> --region <region> <key>
#
# The receiver (gitops/charts/consent-receiver) has no Service and listens on its pod's loopback, so
# it is reached only through `kubectl port-forward`, which the cluster's own authentication gates.
#
#   kubectl reaches the cluster from here   port-forward locally (loopback only), and print the URL --
#   (public endpoint, workstation mode)     the case with enable_bastion = false
#   it does not (private endpoint)          start the port-forward on the cluster's bastion over SSM,
#                                           then tunnel localhost:<port> to it with Session Manager
#
# Then, on the open source path (oauth_consent), open http://localhost:<port>/connect/<key> and
# approve. On the AWS services path (agentcore_consent), open the authorization URL the agent's tool
# call returned; after you approve, AgentCore sends the browser to localhost:<port>/complete/<key>,
# which this tunnel delivers to the receiver. The port must match the callback or return URL
# (default 8765). The bastion side ends after 30 minutes.
#
# Needs the AWS CLI's Session Manager plugin for the bastion case:
#   https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
set -uo pipefail
CLUSTER="" REGION="${AWS_REGION:-}" PORT=8765 NS=consent BASTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --bastion) BASTION="$2"; shift 2 ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done
KEY="${1:-}"
[[ -n "$CLUSTER" && -n "$REGION" && -n "$KEY" ]] || { sed -n '5p' "$0" | sed 's/^# //'; exit 2; }
URL="http://localhost:$PORT/connect/$KEY (open source), or the authorization URL the agent's tool call returned (AWS services)"

if kubectl -n "$NS" get deploy consent-receiver >/dev/null 2>&1; then
  echo "open $URL and approve; Ctrl-C here when the page says Connected"
  # Re-established when it drops, as on the bastion below: a forward is pinned to one pod, and a
  # receiver that restarts mid-approval otherwise leaves the browser's redirect with nothing to hit.
  # kubectl binds 127.0.0.1 only.
  trap 'exit 0' INT TERM
  while true; do kubectl -n "$NS" port-forward deploy/consent-receiver "$PORT:$PORT"; sleep 2; done
fi

if [[ -z "$BASTION" ]] && ! aws ec2 describe-instances --region "$REGION" \
     --filters "Name=tag:Name,Values=$CLUSTER-bastion" "Name=instance-state-name,Values=running" \
     --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null | grep -q '^i-'; then
  echo "kubectl cannot reach $CLUSTER from here, and it has no running bastion." >&2
  echo "With the public endpoint (enable_bastion = false), this machine's address is probably outside" >&2
  echo "cluster_endpoint_public_access_cidrs: apply again from here, wait a few minutes, and retry." >&2
  exit 1
fi

command -v session-manager-plugin >/dev/null 2>&1 || {
  echo "kubectl cannot reach $CLUSTER from here, and the Session Manager plugin is not installed." >&2
  echo "  macOS: brew install --cask session-manager-plugin" >&2
  echo "  other: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2
  exit 1; }

if [[ -z "$BASTION" ]]; then
  BASTION="$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$CLUSTER-bastion" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)"
  [[ -n "$BASTION" && "$BASTION" != "None" ]] || { echo "no running $CLUSTER-bastion; pass --bastion <instance-id>" >&2; exit 1; }
fi

# The bastion's end: a port-forward bound to its loopback, ended after 30 minutes -- and RE-ESTABLISHED
# when it drops. kubectl port-forward is pinned to one pod, so a receiver that restarts (a new image,
# a rescheduled node) kills the forward, and the next browser redirect finds nothing.
CMD="source /etc/bastion-env 2>/dev/null; pkill -f 'port-forward deploy/consent-receiver' ; nohup timeout 1800 sh -c 'while true; do kubectl -n $NS port-forward deploy/consent-receiver $PORT:$PORT; sleep 2; done' >/tmp/consent-pf.log 2>&1 & sleep 4; curl -fsS -o /dev/null http://127.0.0.1:$PORT/healthz && echo ready"
CID="$(aws ssm send-command --region "$REGION" --instance-ids "$BASTION" --document-name AWS-RunShellScript \
  --parameters "$(python3 -c 'import json,sys;print(json.dumps({"commands":[sys.argv[1]]}))' "$CMD")" \
  --query Command.CommandId --output text)" || exit 1
for _ in $(seq 1 24); do
  sleep 5
  out="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$BASTION" \
          --query '[Status,StandardOutputContent]' --output text 2>/dev/null)"
  [[ "$out" == Success*ready* ]] && break
  [[ "$out" == Failed* ]] && { echo "the bastion could not reach the receiver: $out" >&2; exit 1; }
done
[[ "$out" == Success*ready* ]] || { echo "the bastion's port-forward did not come up: $out" >&2; exit 1; }

echo "open $URL and approve; Ctrl-C here when the page says Connected"
exec aws ssm start-session --region "$REGION" --target "$BASTION" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"$PORT\"],\"localPortNumber\":[\"$PORT\"]}"
