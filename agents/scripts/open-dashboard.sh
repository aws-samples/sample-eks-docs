#!/usr/bin/env bash
#
# Open Grafana or Langfuse in your browser, from the machine you run Terraform on.
#
#   ./scripts/open-dashboard.sh --cluster <name> --region <region> grafana|langfuse [--port N]
#
# Neither has a load balancer: each is a ClusterIP Service, reached only through `kubectl
# port-forward`, which the cluster's own authentication gates, and each asks for its own sign-in.
#
#   kubectl reaches the cluster from here   port-forward locally (loopback only), and print the URL --
#   (public endpoint, workstation mode)     the case with enable_bastion = false
#   it does not (private endpoint)          start the port-forward on the cluster's bastion over SSM,
#                                           bound to its loopback, then tunnel localhost:<port> to it
#                                           with Session Manager
#
# Then open http://localhost:<port> and sign in with the user this prints; the command it prints reads
# the password from Secrets Manager. Ctrl-C ends the tunnel. The bastion side ends after an hour.
#
# Needs the AWS CLI's Session Manager plugin for the bastion case:
#   https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
set -uo pipefail
CLUSTER="" REGION="${AWS_REGION:-}" PORT="" BASTION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --bastion) BASTION="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done
WHAT="${1:-}"
case "$WHAT" in
  grafana)
    NS=monitoring SVC=kube-prometheus-stack-grafana SVC_PORT=80 PORT="${PORT:-3000}"
    USER_HINT="admin"
    SECRET="$CLUSTER/platform/grafana-admin" KEY=admin-password
    WHERE="Dashboards, folder Agents: \"Agents · overview\" and \"Agents · policy decisions\"" ;;
  langfuse)
    NS=langfuse SVC=langfuse-web SVC_PORT=3000 PORT="${PORT:-3001}"
    USER_HINT="admin@eks-agents.local"
    SECRET="$CLUSTER/platform/langfuse-init" KEY=password
    WHERE="the agents project: Tracing lists each turn, with its model and tool calls" ;;
  *) WHAT="" ;;
esac
[[ -n "$CLUSTER" && -n "$REGION" && -n "$WHAT" ]] || { sed -n '5p' "$0" | sed 's/^# //'; exit 2; }

say_how() {
  echo "open http://localhost:$PORT and sign in as $USER_HINT. The password:"
  echo "  aws secretsmanager get-secret-value --region $REGION --secret-id $SECRET --query SecretString --output text | jq -r '.\"$KEY\"'"
  echo "then: $WHERE. Ctrl-C here ends the tunnel."
}

if kubectl -n "$NS" get svc "$SVC" >/dev/null 2>&1; then
  say_how
  # kubectl binds 127.0.0.1 only. Re-established when it drops: a forward is pinned to one pod.
  trap 'exit 0' INT TERM
  while true; do kubectl -n "$NS" port-forward "svc/$SVC" "$PORT:$SVC_PORT"; sleep 2; done
fi

find_bastion() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:Name,Values=$CLUSTER-bastion" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null
}
[[ -n "$BASTION" ]] || BASTION="$(find_bastion)"
if [[ -z "$BASTION" || "$BASTION" == "None" ]]; then
  echo "kubectl cannot reach $SVC in $NS from here, and $CLUSTER has no running bastion." >&2
  echo "Is the component on (enable_observability, enable_langfuse) and synced? With the public endpoint" >&2
  echo "(enable_bastion = false), this machine's address may be outside cluster_endpoint_public_access_cidrs." >&2
  exit 1
fi

command -v session-manager-plugin >/dev/null 2>&1 || {
  echo "kubectl cannot reach $CLUSTER from here, and the Session Manager plugin is not installed." >&2
  echo "  macOS: brew install --cask session-manager-plugin" >&2
  echo "  other: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2
  exit 1; }

# The bastion's end: a port-forward bound to its loopback, ended after an hour, re-established when it
# drops. It answers only on the bastion itself; the Session Manager tunnel below is the only way in.
CMD="source /etc/bastion-env 2>/dev/null; pkill -f 'port-forward svc/$SVC ' ; nohup timeout 3600 sh -c 'while true; do kubectl -n $NS port-forward svc/$SVC $PORT:$SVC_PORT; sleep 2; done' >/tmp/$WHAT-pf.log 2>&1 & for i in 1 2 3 4 5 6; do sleep 3; curl -s -o /dev/null http://127.0.0.1:$PORT/ && echo ready && exit 0; done; echo 'no answer on the bastion:'; kubectl -n $NS get svc $SVC 2>&1; tail -3 /tmp/$WHAT-pf.log"
CID="$(aws ssm send-command --region "$REGION" --instance-ids "$BASTION" --document-name AWS-RunShellScript \
  --parameters "$(python3 -c 'import json,sys;print(json.dumps({"commands":[sys.argv[1]]}))' "$CMD")" \
  --query Command.CommandId --output text)" || exit 1
out=""
for _ in $(seq 1 24); do
  sleep 5
  out="$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$BASTION" \
          --query '[Status,StandardOutputContent]' --output text 2>/dev/null)"
  [[ "$out" == Success*ready* ]] && break
  [[ "$out" == Success* || "$out" == Failed* ]] && break
done
[[ "$out" == Success*ready* ]] || { echo "the bastion's port-forward to $SVC did not come up:" >&2; echo "$out" >&2; exit 1; }

say_how
exec aws ssm start-session --region "$REGION" --target "$BASTION" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"$PORT\"],\"localPortNumber\":[\"$PORT\"]}"
