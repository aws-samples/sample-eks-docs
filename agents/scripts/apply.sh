#!/usr/bin/env bash
#
# terraform apply, with a guard between the plan and the apply, that rides out a dropped network.
#
#   ./scripts/apply.sh --root terraform/open-source -var-file=my.tfvars
#   ./scripts/apply.sh --root terraform/open-source --allow-replace -var-file=my.tfvars
#   ./scripts/apply.sh --root terraform/open-source --yes -var-file=my.tfvars   # no prompt
#   ./scripts/apply.sh --root terraform/open-source --wait-minutes 30 -var-file=my.tfvars
#
# It plans to a file, refuses the plan if it would REPLACE a stateful or security resource or if the
# refresh read one as DELETED (scripts/lib/plan_guard.py), and otherwise applies exactly that plan.
# Every other argument goes to `terraform plan`.
#
# A NETWORK DROP is not the end of the run. When the plan or the apply fails on a network error
# between this machine and AWS (dial tcp, no such host, i/o timeout, connection reset ...), it waits
# for AWS to answer again (sts get-caller-identity, every 15 s, up to --wait-minutes, default 15),
# then PLANS AGAIN from the state Terraform saved and runs the guard on that new plan -- a refresh
# after a drop is exactly when a resource can read as deleted. Up to --attempts plans (default 5).
# Without --yes it asks again before each apply.
#
# A RESOURCE TAINTED BY THE DROP is untainted only when it is safe to: a create whose read-back or
# wait was cut off leaves the provider marking it tainted, and the next plan replaces it (for
# example, CreateRole succeeds and GetRole fails on the cut). When every replacement in the plan is because of
# a taint, and each object exists in AWS tagged for this stack (an ECR repository, IAM role, log
# group, or an EKS cluster or capability that is also ACTIVE), they are untainted and the plan is
# made again; its refresh corrects any setting in place. Anything else tainted is left to Terraform
# and the guard (a tainted secret version does need replacing).
#
# "ALREADY EXISTS" after a drop means AWS created something whose reply never arrived, so it is not
# in state -- the usual case: the SDK retries a create after the drop and every retry answers
# "already exists". Each one this stack provably owns (an ECR repository, IAM role, log group,
# S3 bucket, EKS cluster or capability carrying eks-agents/cluster = <name>, which the provider tags
# at create) is imported and the plan made again. Anything else gets the `terraform import` command
# printed instead (scripts/lib/apply_recover.py).
#
# WHY THE GUARD. A single bad read during refresh can make a plain `terraform apply` replace a
# non-empty bucket's public access block, policy, encryption, ownership controls, lifecycle and
# versioning. The plan shows it, but in a form that reads as routine: "has been deleted" above a
# list of "must be replaced". This stops there and names each one.
set -uo pipefail
ROOT=""; ALLOW=""; YES=""; ARGS=(); WAIT_MINUTES=15; ATTEMPTS=5
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2 ;;
    --allow-replace) ALLOW="--allow-replace"; shift ;;
    --yes) YES=1; shift ;;
    --wait-minutes) WAIT_MINUTES="$2"; shift 2 ;;
    --attempts) ATTEMPTS="$2"; shift 2 ;;
    -h|--help) sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
[[ -n "$ROOT" && -d "$ROOT" ]] || { echo "usage: $0 --root <terraform root> [--allow-replace] [--yes] [--wait-minutes N] [--attempts N] [plan args...]" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d -t tfapply.XXXXXX)"; trap 'rm -rf "$WORK"' EXIT
PLAN="$WORK/plan"; LOG="$WORK/out.log"
# The stack's Region, for the AWS checks: AWS_REGION, else `region` in the -var-file passed, else the
# CLI's default.
REGION="${AWS_REGION:-}"; VAR_FILES=""; STACK=""
for a in ${ARGS[@]+"${ARGS[@]}"}; do
  case "$a" in -var-file=*) VAR_FILES="${VAR_FILES:+$VAR_FILES }$a"; f="${a#-var-file=}"; [[ "$f" = /* ]] || f="$ROOT/$f"
    [[ -n "$REGION" ]] || REGION="$(sed -nE 's/^[[:space:]]*region[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$f" 2>/dev/null | head -1)"
    [[ -n "$STACK" ]] || STACK="$(sed -nE 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$f" 2>/dev/null | head -1)" ;;
  esac
done
REGION="${REGION:-$(aws configure get region 2>/dev/null || true)}"

# Run a terraform subcommand, keep its output for classification, return its exit status. The flags go
# before the arguments: `apply <plan>` takes none after the plan file.
tf() { local sub="$1"; shift; terraform -chdir="$ROOT" "$sub" -input=false -lock-timeout=120s "$@" 2>&1 | tee "$LOG"; return "${PIPESTATUS[0]}"; }

wait_for_aws() {
  local deadline=$(( $(date +%s) + WAIT_MINUTES * 60 ))
  echo "apply.sh: the network to AWS dropped; waiting up to ${WAIT_MINUTES} min for it to answer again" >&2
  while (( $(date +%s) < deadline )); do
    if aws sts get-caller-identity ${REGION:+--region "$REGION"} >/dev/null 2>&1; then
      echo "apply.sh: AWS answers again; planning from the saved state" >&2
      return 0
    fi
    sleep 15
  done
  echo "apply.sh: AWS did not answer within ${WAIT_MINUTES} min; run this again when the network is back" >&2
  return 1
}

# After a failure: retry on a network error, print import commands on "already exists", stop on
# anything else. Returns 0 to plan again.
recover() {
  local rc=$1 kind=0
  python3 "$HERE/lib/apply_recover.py" classify "$LOG"; kind=$?
  case "$kind" in
    10) wait_for_aws && return 0 ;;
    12) # Another update on the same object is still running (an EKS cluster accepts one at a time).
        # Wait for it rather than fail: the next plan re-reads the object and applies what's left.
        echo "apply.sh: AWS is still applying another update to the same resource; waiting 60 s, then planning again" >&2
        sleep 60; return 0 ;;
    11) [[ -s "$WORK/plan.json" ]] || echo '{}' > "$WORK/plan.json"
        # Created in AWS but not recorded: the reply to the create was lost (the SDK's retries
        # after a drop each return "already exists"). Adopt each one this stack provably
        # owns -- tagged eks-agents/cluster = name at create -- by importing it, then plan again.
        if (( adopted == 0 )) && [[ -n "$STACK" && -n "$REGION" ]] \
           && pairs="$(python3 "$HERE/lib/apply_recover.py" adopt "$LOG" "$WORK/plan.json" "$STACK" "$REGION")"; then
          adopted=1
          while IFS=$'\t' read -r addr rid; do
            [[ -n "$addr" ]] || continue
            echo "apply.sh: $addr exists in AWS, tagged for $STACK, but not in state; importing it" >&2
            # shellcheck disable=SC2086 # VAR_FILES is a list of -var-file= flags
            terraform -chdir="$ROOT" import -input=false -lock-timeout=120s $VAR_FILES "$addr" "$rid" >&2 || exit $?
          done <<<"$pairs"
          return 0
        fi
        echo "apply.sh: AWS has resources Terraform did not record (their create reply was lost), and not all are provably this stack's. Import each, then apply again:" >&2
        python3 "$HERE/lib/apply_recover.py" import-hints "$LOG" "$WORK/plan.json" "$ROOT" "$VAR_FILES" >&2 ;;
  esac
  exit "$rc"
}

attempt=0; untainted=0; adopted=0
while (( attempt < ATTEMPTS )); do
  attempt=$((attempt + 1))
  (( attempt > 1 )) && echo "apply.sh: plan $attempt of $ATTEMPTS" >&2
  tf plan -out="$PLAN" ${ARGS[@]+"${ARGS[@]}"}; rc=$?
  (( rc == 0 )) || { recover "$rc"; continue; }
  terraform -chdir="$ROOT" show -json "$PLAN" > "$WORK/plan.json" || exit $?

  # Tainted by a cut-off wait, and healthy in AWS: untaint and plan again, once per run.
  if (( untainted == 0 )) && [[ -n "$REGION" && -n "$STACK" ]] && safe="$(python3 "$HERE/lib/apply_recover.py" untaint "$WORK/plan.json" "$STACK" "$REGION" 2>/dev/null)"; then
    untainted=1
    while read -r addr; do
      [[ -n "$addr" ]] || continue
      echo "apply.sh: $addr is tainted by a cut-off create but exists in AWS, tagged for $STACK; untainting it rather than replacing it" >&2
      terraform -chdir="$ROOT" untaint -lock-timeout=120s "$addr" || exit $?
    done <<<"$safe"
    attempt=$((attempt - 1)); continue
  fi

  python3 "$HERE/lib/plan_guard.py" $ALLOW < "$WORK/plan.json" || exit $?
  if [[ -z "$YES" ]]; then
    read -r -p "Apply this plan? Only 'yes' is accepted: " answer
    [[ "$answer" == "yes" ]] || { echo "not applied"; exit 1; }
  fi
  tf apply "$PLAN"; rc=$?
  (( rc == 0 )) && exit 0
  recover "$rc"
done
echo "apply.sh: still failing after $ATTEMPTS plans; the last output is above" >&2
exit 1
