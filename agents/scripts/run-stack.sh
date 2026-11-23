#!/usr/bin/env bash
#
# Run a command against one stack's cluster, from wherever that cluster is reachable, using THIS
# working tree.
#
#   ./scripts/run-stack.sh --root terraform/open-source -- ./scripts/bootstrap-gitops.sh --path open-source --sync
#   ./scripts/run-stack.sh --root terraform/open-source -- kubectl get runtimeclass
#
# WHERE IT RUNS. The stack's Terraform outputs decide:
#
#   a bastion (enable_bastion, the default)   on the bastion, over SSM. The API endpoint is private,
#                                             so that is the only host that reaches it.
#   no bastion (the workstation mode)          here, against a kubeconfig for this stack's cluster
#                                             alone. Terraform allows no bastion only with the public
#                                             endpoint, so this machine reaches it -- when its
#                                             address is in cluster_endpoint_public_access_cidrs.
#
# exercise.sh, build-images.sh --root and teardown.sh --root call this themselves, so their commands
# are the same in both modes. A command never reaches a different cluster through this machine's
# current kubectl context. The command sees RUN_STACK=1, which is how those scripts know they are
# already where they should be.
#
# ON THE BASTION. The tree (tracked and untracked files under apps/, scripts/ and gitops/; never
# terraform/, which holds state and tfvars that name an account) is archived, staged in the
# bastion's staging bucket under build-context/ (no agent role can read it), and fetched on the bastion
# through a presigned URL that expires in 15 minutes. The command runs from the unpacked tree with
# the bastion's own credentials and kubeconfig. The staged object is deleted afterwards.
#
# Extra files to send (e.g. the ECR URL map) go with --file <local path>; each lands at the tree's
# root under its own base name.
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_ROOT=""
FILES=()
TIMEOUT=3600
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)    TF_ROOT="$2"; shift 2 ;;
    --file)    FILES+=("$2"); shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --)        shift; break ;;
    -h|--help) sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (put the command after --)" >&2; exit 2 ;;
  esac
done
[[ -n "$TF_ROOT" && $# -gt 0 ]] || { echo "usage: $0 --root <terraform root> [--file f] -- <command...>" >&2; exit 2; }
for t in aws terraform python3 tar; do command -v "$t" >/dev/null || { echo "$t is required" >&2; exit 2; }; done

out() { terraform -chdir="$TF_ROOT" output -json "$1" 2>/dev/null || echo null; }
BID="$(out bastion | python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("instance_id",""))')"
# The bastion's own staging bucket, falling back to the checkpoint bucket when the bastion output
# names none. The base has no checkpoint bucket (enable_checkpoints is off).
BUCKET="$(out bastion | python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("staging_bucket",""))')"
[[ -n "$BUCKET" ]] || BUCKET="$(out checkpoint_bucket_name | python3 -c 'import json,sys; print(json.load(sys.stdin) or "")')"
# THE STACK'S REGION, from its own outputs: the shell's default can name another Region, and then
# every call here looks for the cluster in the wrong place. The shell's Region is the fallback for a
# root with no outputs. The command below inherits it, so its own AWS calls go there too.
REGION="$(out region | python3 -c 'import json,sys; print(json.load(sys.stdin) or "")')"
REGION="${REGION:-${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}}"
[[ -n "$REGION" ]] && export AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION"
# EXIT 64 MEANS NOTHING RAN, distinct from the remote command's own exit, so a caller
# that must not continue without the remote half (teardown.sh --root) can tell the two apart.
# EVERY way of not starting is 64, not only the missing outputs below: the upload, the presign and
# send-command each fail with the CLI's own status (255) under `set -e`, and an invocation that
# never reaches the instance ends on the status check with 1. When SSM is unreachable from the
# laptop for one call, this script would exit 1, and teardown.sh would read that as the remote
# teardown's own result and run steps 8-11 with every Agent still present. So
# the bastion script prints NOTHING_RAN_MARKER before anything else, and its absence from the output
# is 64 too -- which also covers a result that could not be read back, the safe direction.
[[ -n "$REGION" ]] || { echo "set AWS_REGION" >&2; exit 64; }

# The tree a command runs in, here or on the bastion; see scripts/lib/stage-tree.sh.
REPO_ROOT="$ROOT"
# shellcheck source=lib/stage-tree.sh
. "$ROOT/scripts/lib/stage-tree.sh"

if [[ -z "$BID" ]]; then
  # No bastion: the workstation mode. Terraform refuses enable_bastion = false unless the endpoint is
  # public, so this machine is the operator host -- provided its address is in the allowlist.
  command -v kubectl >/dev/null || { echo "kubectl is required to run here (no bastion)" >&2; exit 64; }
  CLUSTER="$(out cluster_name | python3 -c 'import json,sys; print(json.load(sys.stdin) or "")')"
  [[ -n "$CLUSTER" ]] || { echo "no bastion and no cluster_name in $TF_ROOT's outputs; apply first" >&2; exit 64; }
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  stage_tree "$STAGE/tree" ${FILES[@]+"${FILES[@]}"}
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --kubeconfig "$STAGE/kubeconfig" >/dev/null \
    || { echo "could not write a kubeconfig for $CLUSTER; nothing ran" >&2; exit 64; }
  export KUBECONFIG="$STAGE/kubeconfig"
  # Three tries, ten seconds apart: one throttled or dropped request is not "unreachable".
  ok=0
  for try in 1 2 3; do
    if kerr="$(kubectl version --request-timeout=20s 2>&1 >/dev/null)"; then ok=1; break; fi
    (( try < 3 )) && sleep 10
  done
  (( ok )) || {
    echo "kubectl's last error: $(printf '%s' "$kerr" | tail -1)" >&2
    # Say WHY, not "probably": a refused address times out rather than being refused, and a network
    # with several egress addresses can pass the Terraform root's own lookup and still be refused.
    echo "no bastion, and $CLUSTER's public endpoint does not answer from here. Nothing ran." >&2
    # `|| true`: it exits 1 when the endpoint does not answer, and under set -e that would replace 64,
    # which teardown.sh --root reads as "nothing ran".
    "$(dirname "$0")/check-endpoint.sh" --cluster "$CLUSTER" --region "$REGION" >&2 || true
    exit 64; }
  echo "no bastion in $TF_ROOT (workstation mode): running here against $CLUSTER: $(printf '%q ' "$@")" >&2
  cd "$STAGE/tree"
  export RUN_STACK=1
  # Where it runs, for a command whose checks need the VPC: exercise.sh's ingress phases (an internal
  # load balancer resolves and answers only inside the VPC).
  export RUN_STACK_WHERE=workstation
  rc=0; "$@" || rc=$?
  cd /
  exit $rc
fi
[[ -n "$BUCKET" ]] || { echo "no staging bucket in $TF_ROOT's outputs (bastion.staging_bucket); apply to create it" >&2; exit 64; }

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
# No macOS extended attributes in the archive: GNU tar on the bastion warns on every file about them.
export COPYFILE_DISABLE=1
stage_tree "$STAGE/tree" ${FILES[@]+"${FILES[@]}"}
tar --no-xattrs -C "$STAGE/tree" -czf "$STAGE/ctx.tgz" . 2>/dev/null || tar -C "$STAGE/tree" -czf "$STAGE/ctx.tgz" .

KEY="build-context/$(date -u +%Y%m%dT%H%M%SZ)-$$.tar.gz"
aws s3 cp --only-show-errors --region "$REGION" "$STAGE/ctx.tgz" "s3://$BUCKET/$KEY" \
  || { echo "could not stage the tree in s3://$BUCKET; nothing ran on the bastion" >&2; exit 64; }
# In the background: the caller has its result by then, and the staging bucket's lifecycle rule
# expires any object a cleanup missed after a day.
cleanup_obj() { ( aws s3 rm --only-show-errors --region "$REGION" "s3://$BUCKET/$KEY" >/dev/null 2>&1 & ) ; }
trap 'cleanup_obj; rm -rf "$STAGE"' EXIT
GET="$(aws s3 presign --region "$REGION" --expires-in 900 "s3://$BUCKET/$KEY")" \
  || { echo "could not presign the staged tree; nothing ran on the bastion" >&2; exit 64; }
MARKER="run-stack: started $KEY"

CMD="$(printf '%q ' "$@")"
python3 - "$GET" "$CMD" "$TIMEOUT" "$MARKER" > "$STAGE/in.json" <<'PY'
import json, shlex, sys
get, cmd, timeout, marker = sys.argv[1:5]
body = "\n".join([
    f"echo {shlex.quote(marker)}",
    "set -eo pipefail",
    "export HOME=/root",
    "source /etc/bastion-env 2>/dev/null || true",
    # With Default Host Management Configuration on in the account, SSM Agent can run commands with
    # AWS_SHARED_CREDENTIALS_FILE pointing at its own role's credentials. The CLI reads that file
    # before the instance profile, so kubectl authenticates as a role with no access entry (401).
    "unset AWS_SHARED_CREDENTIALS_FILE",
    "export RUN_STACK=1",
    "export RUN_STACK_WHERE=bastion",
    "D=$(mktemp -d)",
    f"curl -fsS '{get}' -o $D/ctx.tgz",
    "tar -C $D -xzf $D/ctx.tgz",
    "cd $D",
    "rc=0",
    f"{cmd} || rc=$?",
    "cd / && rm -rf $D",
    "exit $rc",
])
print(json.dumps({"Parameters": {"commands": [body], "executionTimeout": [timeout]}}))
PY
CID="$(aws ssm send-command --region "$REGION" --instance-ids "$BID" --document-name AWS-RunShellScript \
        --cli-input-json "file://$STAGE/in.json" --query Command.CommandId --output text)" || CID=""
[[ -n "$CID" && "$CID" != None ]] || { echo "ssm send-command failed; nothing ran on the bastion" >&2; exit 64; }
echo "on $BID (ssm command $CID): $CMD" >&2

# Run a command, killing it after $1 seconds (macOS has no timeout(1)). The watchdog's own output is
# discarded, so a caller's $(...) does not wait for its sleep to end.
poll_bounded() {
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) >/dev/null 2>&1 & local dog=$!
  wait "$pid"; local rc=$?
  kill "$dog" 2>/dev/null; wait "$dog" 2>/dev/null
  (( rc == 143 )) && echo "the poll ran past ${secs}s and was stopped"
  return "$rc"
}
STATUS=Pending LAST=""
STARTED=$(date +%s); LAST_BEAT=$STARTED
DEADLINE=$(( STARTED + TIMEOUT + 60 ))
while (( $(date +%s) < DEADLINE )); do
  # POLL OFTEN WHILE A COMMAND IS LIKELY TO BE ENDING. Most calls are one kubectl command that ends
  # in 2-3 s, and a fixed 10 s poll would make each of them take at least 10 s (a walk of the User Guide
  # makes about 120 of these calls). Every 2 s for the first 30 s, then every 10 s.
  if (( $(date +%s) - STARTED < 30 )); then sleep 2; else sleep 10; fi
  # A POLL THAT FAILS IS NOT A COMMAND STILL RUNNING. If every failed call read as Pending, expired
  # credentials would spin here until the deadline with no error, and a call with no read timeout
  # can hang for many minutes on one dead connection. A transient error is retried;
  # one that no retry fixes ends the wait at once.
  # The status, the output and the error in one call: each `aws` call costs about a second here, and
  # two more calls to read the output after the status is read would cost two seconds on every run.
  # ONE POLL IS BOUNDED AS A WHOLE, NOT ONLY ITS CONNECTION. The CLI's timeouts cover one HTTP
  # attempt; its retries and a credential_process refresh (an SSO or federation helper renewing an
  # expired session) are outside them, so one such call can hold this loop for minutes after
  # the command has ended. poll_bounded kills a poll that runs past 60 s, which reads as a failed
  # poll and is retried.
  if POLL="$(poll_bounded 60 aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$BID" \
               --cli-connect-timeout 10 --cli-read-timeout 30 \
               --query '{s:Status,o:StandardOutputContent,e:StandardErrorContent}' --output json 2>&1)"; then
    STATUS="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["s"])' <<<"$POLL" 2>/dev/null || echo Pending)"
    LAST="$POLL"; PERR=""
  elif grep -qE 'ExpiredToken|InvalidClientTokenId|UnrecognizedClient|AccessDenied|Unable to locate credentials' <<<"$POLL"; then
    echo "run-stack: cannot read the command's status: $(tail -1 <<<"$POLL")" >&2
    echo "the command may still be running on the bastion (ssm command $CID); refresh the AWS credentials and check it there" >&2
    exit 64
  else
    STATUS=Pending; PERR="$(tail -1 <<<"$POLL")"
  fi
  case "$STATUS" in Pending|InProgress|Delayed) ;; *) break ;; esac
  # SSM returns the command's output only when it ends, so a long step (a sync that waits on
  # Langfuse can take 7 minutes) is otherwise silent and looks hung. One line a
  # minute, on stderr so a caller that reads the command's output is unaffected.
  if (( $(date +%s) - LAST_BEAT >= 60 )); then
    LAST_BEAT=$(date +%s)
    if [[ -n "${PERR:-}" ]]; then
      # The status is unknown, not Pending: the last poll failed, and the command may have ended.
      echo "  ... no status from SSM for this command ($(( LAST_BEAT - STARTED ))s); retrying. Last poll error: $PERR" >&2
    else
      echo "  ... still running on the bastion ($(( LAST_BEAT - STARTED ))s, $STATUS); its output arrives when it ends" >&2
    fi
  fi
done
# SSM truncates inline output at 24,000 characters; enough for a phase, and the status is exact.
field() { python3 -c 'import json,sys; v=json.load(sys.stdin).get(sys.argv[1]); sys.stdout.write(v if isinstance(v,str) else "")' "$1" <<<"$LAST" 2>/dev/null || true; }
OUT="$(field o)"
ERR="$(field e)"
BODY="${OUT#"$MARKER"}"; BODY="${BODY#$'\n'}"
[[ -n "$BODY" ]] && printf '%s\n' "$BODY"
[[ -n "$ERR" && "$ERR" != None ]] && printf '%s\n' "$ERR" >&2
if [[ "$OUT" != "$MARKER"* ]]; then
  echo "the bastion never reported starting the command (status $STATUS); treating it as not run" >&2
  exit 64
fi
[[ "$STATUS" == Success ]]
