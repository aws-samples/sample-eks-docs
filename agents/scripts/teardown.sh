#!/usr/bin/env bash
#
# Tear the whole thing down, in the order that leaves nothing billing.
#
#   ./scripts/teardown.sh --path open-source --cluster my-agents --region us-west-2
#   ./scripts/teardown.sh --path open-source --cluster my-agents --region us-west-2 --yes
#   ./scripts/teardown.sh --path open-source --cluster my-agents --region us-west-2 --yes --destroy-with my.tfvars
#   ./scripts/teardown.sh --path open-source --cluster my-agents --region us-west-2 --sweep-only
#   ./scripts/teardown.sh --path open-source --cluster my-agents --sweep-only --revert-account-settings
#
# ARE YOU DELETING THE CLUSTER, OR KEEPING IT? The answer changes which steps matter, and it is the
# one thing this script cannot work out for itself.
#
#   deleting it   add --cluster-going-away. Step 7 is skipped, because deleting the cluster
#                 removes every object inside it. Step 5 still runs: it is what lets the EBS volumes go.
#                 Everything that prevents an ORPHANED AWS resource still runs.
#   keeping it    run it without the flag, which is the default. Steps 5 and 7 are then the point of
#                 the exercise -- see "AND THE CASE THAT IS NOT A DESTROY AT ALL" below.
#
# TWO HALVES, AND `--root <terraform root>` RUNS BOTH. Steps 0-7 need kubectl, so steps 0-9 run through
# scripts/run-stack.sh: on the stack's bastion, whose role reaches the private endpoint and, with
# bastion_teardown_access (the default), can delete this stack's repositories and empty its
# bucket; or here, with no bastion. Step 11 needs account-wide reads and always runs here. --root is
# the recommended way; otherwise run 0-9 where kubectl reaches the cluster and `--sweep-only` from
# somewhere that can see the account. The sweep refuses to report a clean result it could not verify.
#
# DRY RUN BY DEFAULT. Without --yes it prints what it would delete and deletes nothing.
#
# OPERATOR SECRETS ARE KEPT unless you add --delete-operator-secrets. The secrets you stored with
# scripts/set-credential.sh, under <cluster>/consent/ and <cluster>/agentcore/, cannot be
# regenerated, so the teardown reports each one with the command that deletes it. With
# --delete-operator-secrets (and --yes) it deletes them too, with no recovery window. The generated
# passwords under <cluster>/platform/ are always deleted.
#
# WHY THIS SCRIPT EXISTS, AND WHY `terraform destroy` IS NOT ENOUGH. Terraform owns the cluster, the
# network and the IAM it created. It does not own anything a controller INSIDE the cluster created
# on its behalf, and those resources either outlive the cluster silently or block the destroy:
#
#   EBS volumes behind PersistentVolumeClaims   up to ~224 GiB on the open source path with every
#                                               component on: Prometheus 100Gi, pgvector 50Gi,
#                                               session-state valkey 2x20Gi, Langfuse 24Gi across
#                                               five tiers, the warm-pool example 10Gi. Nothing
#                                               deletes these once the cluster is gone, because the
#                                               CSI driver that would is gone with it. They are
#                                               invisible on the EKS console afterwards and bill
#                                               monthly forever. THIS IS THE EXPENSIVE ONE.
#   Load balancers from Gateways and Services   an ALB or NLB per Gateway. Deleting the cluster
#                                               orphans them, and their ENIs then block the VPC
#                                               delete, so `terraform destroy` fails halfway with a
#                                               DependencyViolation and leaves a half-torn stack.
#   IAM roles the ACK capability created        one per Agent resource, under the agent role path.
#                                               Terraform never saw them, so they survive, and they
#                                               hold the permissions boundary policy, which makes
#                                               `terraform destroy` fail with DeleteConflict.
#   Images in the ECR repositories              `force_delete` is false on purpose, so a repository
#                                               with any image refuses to be deleted. The
#                                               quickstart tells you to push images, so this fires
#                                               on every real teardown.
#   Objects in the checkpoint bucket            the bucket is versioned, so emptying it means
#                                               deleting versions AND delete markers, not just
#                                               objects. `force_destroy` is false on purpose: a
#                                               terraform apply must never be able to delete an
#                                               agent's durable state as a side effect.
#   The EKS control-plane log group             /aws/eks/<cluster>/cluster survives the cluster when
#                                               control-plane logging was enabled.
#   A Lambda function and its role              NOT created by this repository. An AgentCore Gateway
#                                               Lambda target is wired by hand, and the function and
#                                               its execution role then carry whatever name you gave
#                                               them rather than the cluster's. Checked in the sweep
#                                               because that is exactly the shape a name-prefix
#                                               check cannot see.
#
# AND THE CASE THAT IS NOT A DESTROY AT ALL. Everything above assumes `terraform destroy` removes
# the cluster, so whatever is left inside it goes with it. Apply this stack to a cluster you intend
# to KEEP and that assumption inverts: the namespaces go, and every cluster-scoped object stays.
# What a full stack leaves on a kept cluster after a destroy that reports clean:
#
#   Hundreds of CRDs                           most of them in the ACK group, plus kro, Istio,
#                                               cert-manager, CloudNativePG, prometheus-operator,
#                                               Agent Sandbox and the Agent kind itself. DELETING
#                                               THE CAPABILITY DOES NOT REMOVE ITS CRDs: the count
#                                               does not move until they are deleted by name.
#   WHEN THE ACK CRDs ARRIVE, which is not when the capability does. The ACK capability can report
#   ACTIVE before its CRDs are registered. So do not
#   read "the capability is ACTIVE" as "the CRDs are here", in either direction -- the sweep below
#   counts what is actually registered rather than assuming a number.
#
#   Admission webhook configurations            cert-manager, CNPG and Istio all register
#                                               failurePolicy: Fail. With their Services gone every
#                                               matching CREATE fails cluster-wide. This is the one
#                                               that changes the cluster's BEHAVIOUR rather than its
#                                               bill, which is why it goes first.
#   ClusterRoles and ClusterRoleBindings        nothing namespaced owns them, so nothing reclaims
#                                               them when the namespaces go.
#   A default StorageClass                      eks-agents-gp3, which outranks whatever was default
#                                               on the cluster before.
#   Helm release secrets                        the base chart's whole revision history, in `default`
#   Istio CA ConfigMaps                         istiod writes istio-ca-root-cert and istio-ca-crl
#                                               into EVERY namespace, including kube-system.
#   EKS Capabilities                            ACK and kro stay ACTIVE, and keep billing
#   Dangling EKS access entries                 a capability's access entry outlives the capability
#
# So the order below is not cosmetic. In-cluster first, while the controllers are still alive to
# clean up after themselves; then the cluster-scoped residue, which only a surviving cluster keeps;
# then the things that block terraform; then terraform; then a sweep that looks for what is left.
#
# The sweep at the end is the part to trust. It queries AWS for anything still carrying this
# cluster's name or tag and prints it, so "the teardown finished" and "nothing is still billing" are
# two separate claims and you can see both.
#
# THE SWEEP SCANS BY TAG AS WELL AS BY NAME, and prints anything tagged for this cluster whose name
# it would not have recognised. Matching on `starts_with(<name>, '${CLUSTER}')` alone hides a whole
# stack: one applied with `name` set to something other than the cluster's own name, or a resource
# terraform names for the example rather than the cluster -- the ECR repositories and the tools
# Lambda -- is invisible to it, and the script prints "Sweep clean".
set -uo pipefail

PATH_NAME=""
CLUSTER=""
REGION="${AWS_REGION:-}"
APPLY=0

NS_REASONING="${NS_REASONING:-agents}"
NS_EXECUTION="${NS_EXECUTION:-agents-execution}"
NS_GATEWAY="${NS_GATEWAY:-agentgateway-system}"
NS_MEMORY="${NS_MEMORY:-agent-memory}"
# The ingress routes and rules (gitops/base namespaces.ingress). Deleted with the agents, while
# the load balancer controller still exists to take its listener rules off the ALB.
NS_INGRESS="${NS_INGRESS:-ingress}"
# The evaluation runner (gitops/charts/agent-evals). Deleted with the agents: its CronJobs call them.
NS_EVALS="${NS_EVALS:-agent-evals}"
# The OAuth consent receiver (gitops/charts/consent-receiver), when oauth_consent is set.
NS_CONSENT="${NS_CONSENT:-consent}"
# Namespaces the platform Applications create. Their PVCs are the lingering cost.
NS_PLATFORM="${NS_PLATFORM:-monitoring langfuse clickhouse-operator-system cert-manager agent-sandbox-system keda}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)    PATH_NAME="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    --yes)     APPLY=1; shift ;;
    # The cluster is about to be deleted, so skip step 7 (cluster-scoped residue), which exists only
    # for a cluster that SURVIVES and walks hundreds of CRDs. Step 5 still runs: deleting the namespaces is
    # what evicts the pods, which lets step 3's PVC deletes finish and the EBS volumes go (see its
    # comment).
    #
    # It skips NOTHING that prevents an orphaned AWS resource. Steps 1-4 (Agents, load balancers,
    # PVCs, the Argo CD root), 6 (capabilities), 8-9 (ECR, the bucket) and the sweep all still run,
    # because those are the resources that outlive the cluster rather than live inside it.
    --cluster-going-away) GOING_AWAY=1; shift ;;
    # Step 11 only, for the case the sweep exists to catch: steps 1-9 need kubectl and so run from
    # inside the VPC, where the host's credential cannot read the account. Run them there, then run
    # this from somewhere that can see.
    --sweep-only) SWEEP_ONLY=1; shift ;;
    # THE RECOMMENDED WAY TO RUN THIS. Steps 0-7 need kubectl, so --root <terraform root> runs 0-9
    # through scripts/run-stack.sh -- on the root's bastion (private endpoint), or here with no
    # bastion. Steps 8-9 (ECR, the bucket) need writes a bastion has only with
    # bastion_teardown_access, which is on by default. Then it carries on here: 8-9 again, which finds nothing to do when the
    # bastion did them and does them when the bastion's role could not, and the sweep (11),
    # which needs account-wide reads. Skipping the second half leaves the destroy failing on
    # RepositoryNotEmptyException and BucketNotEmpty.
    --root) STACK_ROOT="$2"; shift 2 ;;
    # Internal: what --root runs through run-stack.sh. Steps 0-9, then stop.
    --in-cluster-only) IN_CLUSTER_ONLY=1; shift ;;
    --revert-account-settings) REVERT_ACCOUNT=1; shift ;;
    # The Identity Center instance's region, when it is not the cluster's. An organization has at
    # most one instance and it is commonly in us-east-1; without this the sweep tries the cluster's
    # region and then us-east-1, which covers the common cases but not a third region.
    --idc-region) IDC_REGION="$2"; shift 2 ;;
    # Run step 10 too: terraform destroy in terraform/<path> with this -var-file (relative to that
    # root, as `terraform -chdir` reads it), then put back the rendered files the destroy deletes.
    # Without it the script stops at step 10 and prints the command; with it, one invocation goes
    # from a running stack to a sweep. Only with --yes does it destroy anything.
    --destroy-with) DESTROY_TFVARS="$2"; shift 2 ;;
    # Also delete <cluster>/consent/ and <cluster>/agentcore/ (see the header). Only with --yes.
    --delete-operator-secrets) DELETE_OPERATOR_SECRETS=1; shift ;;
    -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$PATH_NAME" ]] && { echo "--path is required: open-source or aws-services" >&2; exit 2; }
STACK_ROOT="${STACK_ROOT:-}"; IN_CLUSTER_ONLY="${IN_CLUSTER_ONLY:-0}"
[[ -z "$CLUSTER"  ]] && { echo "--cluster is required" >&2; exit 2; }
[[ -z "$REGION"   ]] && { echo "--region is required (or set AWS_REGION)" >&2; exit 2; }

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
leftovers=0
SWEEP_ONLY="${SWEEP_ONLY:-0}"
DESTROY_TFVARS="${DESTROY_TFVARS:-}"
GOING_AWAY="${GOING_AWAY:-0}"
DELETE_OPERATOR_SECRETS="${DELETE_OPERATOR_SECRETS:-0}"

# ACCOUNT-LEVEL CHANGES NEED THEIR OWN YES, and not --yes.
#
# --sweep-only deliberately forces APPLY=0, so `run` only prints in the mode you use once the
# cluster is gone -- which is exactly when the one account setting this stack leaves behind is
# discovered. Reusing --yes would have meant weakening the sweep's read-only promise to fix one
# thing, so this authorises that class and nothing else: it is the only flag that changes something
# outside the cluster's own resources.
REVERT_ACCOUNT="${REVERT_ACCOUNT:-0}"

# STEP TIMINGS. Each step's wall clock is printed when the next starts, and the slowest are listed at
# the end, so a teardown that stalls says where rather than only that it took long.
_STEP_NAME="" _STEP_T0=$SECONDS STEP_TIMES=()
_step_close() {
  [[ -n "$_STEP_NAME" ]] || return 0
  local d=$((SECONDS - _STEP_T0))
  STEP_TIMES+=("$d|$_STEP_NAME")
  (( d >= 60 )) && printf '      %s(%dm%02ds)%s\n' "$DIM" $((d / 60)) $((d % 60)) "$RESET"
  return 0
}
step() { _step_close; _STEP_NAME="$1"; _STEP_T0=$SECONDS; printf '\n%s== %s ==%s\n' "$DIM" "$1" "$RESET"; }
did()  { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
found(){ printf '  %s✗%s %s\n' "$RED" "$RESET" "$1"; leftovers=$((leftovers + 1)); }
note() { printf '      %s%s%s\n' "$DIM" "$1" "$RESET"; }

need() { command -v "$1" >/dev/null 2>&1 || { echo "$1 is required" >&2; exit 2; }; }
need aws

# A DROPPED NETWORK MUST NOT READ AS "NOTHING THERE". Every aws and kubectl call below goes through
# net_retry (scripts/lib/net-retry.sh): a failure that is the network, not an answer, waits for AWS
# to answer again and runs the call again. Without it, a read during a drop returns empty and reads
# as nothing to delete. Defined as
# functions, so no call site changes; `command aws` inside is the real binary.
# shellcheck source=lib/net-retry.sh
. "$(dirname "$0")/lib/net-retry.sh"
NET_REGION="$REGION"
NET_FLAG="$(mktemp -t teardown-netdrop.XXXXXX)"; rm -f "$NET_FLAG"
aws() { net_retry command aws "$@"; }
command -v kubectl >/dev/null 2>&1 && kubectl() { net_retry command kubectl "$@"; }

# Every mutating call goes through this, so --yes is the only thing standing between a dry run and a
# deletion, and there is exactly one place to audit that.
run() {
  if [[ "$APPLY" -eq 1 ]]; then
    "$@" >/dev/null 2>&1 && did "$*" || warn "failed (continuing): $*"
  else
    note "would run: $*"
  fi
}

# Same contract as `run`, but the deletions go in parallel and their lines are printed in the order
# they were queued rather than the order they finished -- so the transcript is still readable and
# still diffable between runs. Use it only where the deletions are INDEPENDENT: the ordering
# constraints in the steps below (operator namespaces last, webhooks before CRDs) are the whole
# reason this script exists, and `wait_all` is the barrier that keeps them.
#
# Deleting four namespaces serially costs the sum of four finalizer waits; in parallel it costs the
# slowest one.
PAR_DIR=""
PAR_N=0
run_bg() {
  if [[ "$APPLY" -ne 1 ]]; then note "would run: $*"; return 0; fi
  [[ -z "$PAR_DIR" ]] && PAR_DIR="$(mktemp -d)"
  PAR_N=$((PAR_N + 1))
  local out="$PAR_DIR/$(printf '%04d' "$PAR_N")"
  local desc="$*"
  # The failure's own last line goes with it: "failed" alone hides an AccessDenied on
  # delete-capability behind a 300 s wait.
  ( if err="$("$@" 2>&1 >/dev/null)"; then printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$desc"
    else printf '  %s!%s failed (continuing): %s\n      %s\n' "$YELLOW" "$RESET" "$desc" "$(printf '%s' "$err" | grep -v '^\s*$' | tail -1 | cut -c1-200)"; fi > "$out" ) &
}
wait_all() {
  [[ "$PAR_N" -eq 0 ]] && return 0
  wait
  cat "$PAR_DIR"/* 2>/dev/null
  rm -rf "$PAR_DIR"; PAR_DIR=""; PAR_N=0
}

# Wait for a condition instead of sleeping for a guess. Every fixed sleep in a teardown is wrong in
# both directions: too short when a controller is slow (which is when it matters) and pure waste
# when it was already done. `cmd` must exit 0 once the thing is gone.
#
# If the check itself cannot run -- a bastion credential that cannot call elasticloadbalancing, say
# -- this falls back to sleeping for the cap rather than declaring success it did not observe.
poll_until() {
  local what="$1" cap="$2"; shift 2
  [[ "$APPLY" -ne 1 ]] && { note "would wait for: $what"; return 0; }
  # Exit 0 means gone, 1 means not yet, anything else means the check could not run at all. Keeping
  # those three apart is the point: a credential error that read as "not yet" would spin for the
  # whole cap and then report a timeout that was never about the resource.
  local rc waited=0
  "$@" >/dev/null 2>&1; rc=$?
  if [[ "$rc" -gt 1 ]]; then
    warn "cannot check $what from here (exit $rc): sleeping ${cap}s instead"
    sleep "$cap"; return 0
  fi
  while [[ "$waited" -lt "$cap" ]]; do
    if [[ "$rc" -eq 0 ]]; then
      if [[ "$waited" -gt 0 ]]; then did "$what (after ${waited}s)"; else did "$what (already)"; fi
      return 0
    fi
    sleep 5; waited=$((waited + 5))
    "$@" >/dev/null 2>&1; rc=$?
  done
  warn "$what did not happen within ${cap}s -- continuing, and the sweep is what will catch it"
}

# Two conditions `poll_until` waits on, as functions rather than inline, because each has to return
# 2 -- "I could not look" -- distinctly from 1 -- "not yet". A credential that cannot read
# elasticloadbalancing returns an empty string, and an empty string compared against a count reads
# as "not yet" forever.
#
# TWO TAG KEYS, NOT ONE. The AWS Load Balancer Controller tags with elbv2.k8s.aws/cluster; EKS Auto
# Mode's built-in controller tags with eks:eks-cluster-name. A check against one key alone reports
# released on the other path, which is the exact shape of a false clean.
lbs_released() {
  local total=0 n k
  for k in elbv2.k8s.aws/cluster eks:eks-cluster-name; do
    n="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
           --resource-type-filters elasticloadbalancing:loadbalancer \
           --tag-filters "Key=$k,Values=$CLUSTER" \
           --query 'length(ResourceTagMappingList)' --output text 2>/dev/null)" || return 2
    [[ -z "$n" || ! "$n" =~ ^[0-9]+$ ]] && return 2
    total=$((total + n))
  done
  [[ "$total" -eq 0 ]]
}
RETAINED_N=0
volumes_released() {
  local n
  if n="$(aws ec2 describe-volumes --region "$REGION" \
         --filters "Name=tag:kubernetes.io/cluster/$CLUSTER,Values=owned" \
         --query 'length(Volumes)' --output text 2>/dev/null)" && [[ "$n" =~ ^[0-9]+$ ]]; then
    [[ "$n" -le "$RETAINED_N" ]]; return
  fi
  # THE BASTION CANNOT DESCRIBE VOLUMES -- its role reaches the cluster and little else -- so on an
  # in-VPC run this would be a blind 300 s sleep. The cluster can answer instead: a dynamically
  # provisioned EBS volume is deleted before its PersistentVolume object goes, so "no EBS-backed PV
  # left beyond the retained ones" is the same condition read from the other side. The sweep, run
  # with account credentials, still checks EC2.
  [[ "$KUBECTL_OK" -eq 1 ]] || return 2
  n="$(kubectl get pv -o jsonpath='{range .items[*]}{.spec.csi.driver}{"\n"}{end}' 2>/dev/null | grep -c 'ebs.csi' || true)"
  [[ "$n" =~ ^[0-9]+$ ]] || return 2
  [[ "$n" -le "$RETAINED_N" ]]
}
capabilities_gone() {
  local out
  out="$(aws eks list-capabilities --cluster-name "$CLUSTER" --region "$REGION" \
           --query 'capabilities[].capabilityName' --output text 2>&1)" || {
    # A deleted cluster has no capabilities, which is the answer wanted.
    [[ "$out" == *ResourceNotFoundException* ]] && return 0
    return 2
  }
  # Only this stack's three: a capability the cluster had before is not waited for.
  ! printf '%s\n' $out | grep -q -x -e "${CLUSTER}-ack" -e "${CLUSTER}-kro" -e "${CLUSTER}-argocd"
}

# THE AGENTS THEMSELVES, not just the ACK objects they compose. An Agent is gone when kro has deleted
# every composed object and removed its own finalizer -- and that can take more than 300 s after
# ACK's Role and Pod Identity association are already gone. Waiting only for those two lets step 6
# delete the KRO and ACK capabilities under Agents still finalizing; kro then cannot list the
# vanished ACK kinds ("deletion blocked: list deletion inventory: ... could not find the requested
# resource"), nothing can ever remove kro.run/finalizer, and the `agents` namespace (300 s), the
# base release uninstall (5 min) and finally the CRD delete (no limit) all wait on it.
agents_left() {
  kubectl get crd agents.agents.eks.amazonaws.com >/dev/null 2>&1 || return 0
  local out
  out="$(kubectl get agents.agents.eks.amazonaws.com -A --no-headers 2>/dev/null)" || return 2
  [[ -z "$out" ]]
}
agent_blockers() {
  kubectl get agents.agents.eks.amazonaws.com -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.status.conditions[?(@.type=="Ready")].message}{"\n"}{end}' 2>/dev/null \
    | cut -c1-220
}
# 0 when no IAM role ACK made for an Agent of this cluster survives; 1 when one does; 2 when the
# check cannot run. ACK tags what it creates with services.k8s.aws/*, which is what separates its
# roles from any Terraform made under the same prefix.
agent_aws_clean() {
  local roles r tags
  roles="$(aws iam list-roles --query "Roles[?starts_with(RoleName,'${CLUSTER}-agent-')].RoleName" --output text 2>/dev/null)" || return 2
  [[ -z "${roles// /}" || "$roles" == None ]] && return 0
  for r in $roles; do
    tags="$(aws iam list-role-tags --role-name "$r" --query 'Tags[].Key' --output text 2>/dev/null)" || return 2
    [[ "$tags" == *services.k8s.aws/* ]] && return 1
  done
  return 0
}
# Release Agents kro cannot finalize -- ONLY once the AWS side they composed is verified gone,
# which is the one thing the finalizer protects. Without the release, every later step that waits on
# the namespace, the release or the CRD spends its whole timeout on them.
release_stuck_agents() {
  agents_left && return 0
  local rc=0; agent_aws_clean || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    warn "Agents are still finalizing and an ACK-made IAM role for $CLUSTER survives (or could not be checked): NOT releasing them"
    agent_blockers | sed 's/^/        /'
    return 1
  fi
  warn "Agents still finalizing with no ACK-made IAM left for $CLUSTER: removing kro.run/finalizer so nothing below waits on them"
  agent_blockers | sed 's/^/        /'
  local a
  for a in $(kubectl get agents.agents.eks.amazonaws.com -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null); do
    run kubectl -n "${a%%/*}" patch agents.agents.eks.amazonaws.com "${a#*/}" --type=merge -p '{"metadata":{"finalizers":null}}'
  done
}

if [[ "$APPLY" -eq 0 ]]; then
  printf '%sDRY RUN.%s Nothing will be deleted. Re-run with --yes to act.\n' "$YELLOW" "$RESET"
fi
if [[ "$GOING_AWAY" -eq 1 ]]; then
  printf '%sCLUSTER GOING AWAY.%s Step 7 is skipped: the cluster delete removes what it does. Step 5 still runs -- see its comment.\n' \
    "$YELLOW" "$RESET"
fi
printf 'cluster %s in %s, path %s\n' "$CLUSTER" "$REGION" "$PATH_NAME"

# --sweep-only is implemented as "delete nothing and reach no cluster", which the steps above
# already handle: every in-cluster step is guarded on KUBECTL_OK and every deletion goes through
# `run`, which is a no-op without --yes. So the run prints what steps 1-10 WOULD do and then
# executes step 11 for real, which is exactly the division the sweep's preflight asks for.
if [[ "$SWEEP_ONLY" -eq 1 ]]; then
  APPLY=0
  printf '%sSWEEP ONLY.%s Steps 1-10 are listed and not run; step 11 is the point of this mode.\n' "$YELLOW" "$RESET"
fi

REMOTE_DONE=0
if [[ -n "$STACK_ROOT" && "$SWEEP_ONLY" -ne 1 ]]; then
  remote=(./scripts/teardown.sh --path "$PATH_NAME" --cluster "$CLUSTER" --region "$REGION" --in-cluster-only)
  [[ "$APPLY" -eq 1 ]] && remote+=(--yes)
  [[ "$GOING_AWAY" -eq 1 ]] && remote+=(--cluster-going-away)
  printf '%sSteps 0-9 through run-stack.sh for %s: on its bastion, or here with a kubeconfig for %s alone%s\n' "$DIM" "$STACK_ROOT" "$CLUSTER" "$RESET"
  # The bastion's result is printed as it returns; its own exit is informational, because its sweep
  # does not run (--in-cluster-only) and a step it could not do is reported in its output.
  #
  # EXCEPT WHEN NOTHING RAN (run-stack.sh exit 64). Carrying on then deletes the EKS
  # Capabilities in step 6 with every Agent still present: the ACK capability goes before it can
  # delete the IAM roles it created, and each agent's role -- and the permissions boundary it holds
  # -- outlives the destroy, which then fails on DeleteConflict. A bastion pass that stops on, say, a
  # missing staging bucket must not let the rest run anyway. Stop instead.
  # Exit 64 is "nothing ran", which makes it safe to try again once a dropped network is back
  # (staging the tree or send-command failed); any other exit is the in-cluster pass's own.
  brc=0
  for stry in 1 2 3; do
    brc=0
    AWS_REGION="$REGION" "$(dirname "$0")/run-stack.sh" --root "$STACK_ROOT" --timeout 3600 -- "${remote[@]}" || brc=$?
    [[ "$brc" -eq 64 && "$stry" -lt 3 ]] || break
    warn "the in-cluster pass did not start (attempt $stry of 3); checking the network before trying again"
    command aws sts get-caller-identity --region "$REGION" >/dev/null 2>&1 && break   # AWS answers: not a drop
    wait_for_aws || break
  done
  if [[ "$brc" -eq 64 ]]; then
    printf '%sThe run-stack.sh pass did not start, so steps 0-9 have not run. Stopping before anything is
' "$RED"
    printf 'deleted: step 6 would remove the capabilities and orphan every agent'"'"'s IAM role.%s
' "$RESET"
    exit 64
  fi
  REMOTE_DONE=1
  printf '\n%sSteps 8-11 here (8-9 have nothing left to do if the first pass did them)%s\n' "$DIM" "$RESET"
fi

KUBECTL_OK=0
if [[ "$REMOTE_DONE" -eq 1 ]]; then
  KUBECTL_OK=0
elif [[ "$SWEEP_ONLY" -eq 1 ]]; then
  KUBECTL_OK=0
elif command -v kubectl >/dev/null 2>&1 && kubectl version --request-timeout=10s >/dev/null 2>&1; then
  # REACHABLE IS NOT THE SAME AS RIGHT. Every in-cluster step below deletes with --all, so it has to
  # be the cluster named by --cluster and not whatever the current kubeconfig context happens to be.
  # Run from a laptop after the cluster is gone, the context can still point at a DIFFERENT cluster
  # in the same account, the credential reaches it, and steps 0-7 run there with --yes. Compare the
  # API server kubectl talks to with the endpoint of the cluster named for teardown, and refuse on
  # any doubt.
  kube_server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"
  want_server="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
    --query cluster.endpoint --output text 2>/dev/null || true)"
  if [[ -n "$want_server" && "$want_server" != "None" && "${kube_server%/}" == "${want_server%/}" ]]; then
    KUBECTL_OK=1
  else
    KUBECTL_OK=0
    warn "kubectl reaches ${kube_server:-an unknown server}, which is NOT cluster $CLUSTER (${want_server:-not found or not readable}): skipping every in-cluster step"
    note "Point kubectl at $CLUSTER (aws eks update-kubeconfig --name $CLUSTER --region $REGION),"
    note "or, if $CLUSTER is already gone, carry on: the steps that need no cluster still run."
  fi
else
  warn "no reachable cluster: skipping every in-cluster step"
  note "If the cluster is already gone, the in-cluster resources it created are NOT. Run the sweep"
  note "at the end and delete what it finds by hand -- that is the case this script exists to avoid."
fi

# ---------------------------------------------------------------------------
step "0. Stop Argo CD reconciling, BEFORE anything is deleted"
# ---------------------------------------------------------------------------
# Every child Application runs with selfHeal, so deleting anything it owns while it still runs puts
# it straight back. If step 2 deletes the ingress Gateway, eks-agents-base re-creates it -- and so
# its load balancer -- and the cascade from step 4 then deletes the Gateway, its GatewayClass's
# LoadBalancerConfiguration and the namespace TOGETHER. The managed controller will not process a
# Gateway whose class cannot read its configuration, deletion included, so the Gateway's finalizer
# never clears, the namespace hangs in Terminating, and the ALB is left billing in a VPC terraform
# destroy then cannot delete. Recovery needs the finalizers stripped and the load balancer and its
# security groups deleted by hand.
#
# So Argo stops first, and it stops by ORPHANING rather than cascading: the resources finalizer comes
# off each Application before it is deleted, the workloads stay, and steps 1-5 below remove them in
# the order that lets every controller release what it holds -- Gateways while their class and
# configuration still exist, namespaces after.
# WHAT THE CRD APPLICATIONS OWN, read before they go. The Gateway API CRDs these sync carry no mark
# of their own -- no tracking annotation, no last-applied annotation, field manager `unknown` -- so
# once the Application is deleted nothing on the cluster says they were this stack's, and step 7
# would leave them as "EKS-managed". The Application's own resource list
# is the record; step 7 deletes exactly those CRDs, and only when no object of their kinds is left.
APP_CRDS=""
if [[ "$KUBECTL_OK" -eq 1 ]]; then
  # eks-agents-base installs the gateway.k8s.aws CRDs (gitops/base/templates/44-aws-gateway-api-crds.yaml).
  for app in gateway-api-crds eks-agents-base; do
    APP_CRDS="$APP_CRDS $(kubectl -n argocd get applications.argoproj.io "$app" \
      -o jsonpath='{range .status.resources[?(@.kind=="CustomResourceDefinition")]}{.name}{" "}{end}' 2>/dev/null || true)"
  done
  [[ -n "${APP_CRDS// /}" ]] && note "CRDs the Gateway API Applications own: $(echo $APP_CRDS | wc -w | tr -d ' ')"
fi
if [[ "$KUBECTL_OK" -eq 1 ]]; then
  apps="$(kubectl -n argocd get applications.argoproj.io -o name 2>/dev/null || true)"
  if [[ -n "$apps" ]]; then
    for a in $apps; do
      run kubectl -n argocd patch "$a" --type merge -p '{"metadata":{"finalizers":null}}'
    done
    run kubectl -n argocd delete applications.argoproj.io --all --wait=true --timeout=120s
  else
    did "no Argo CD Applications"
  fi
fi

# ---------------------------------------------------------------------------
step "1. Agent resources, so the ACK capability deletes the IAM it created"
# ---------------------------------------------------------------------------
# An Agent is a kro instance that composes an ACK Role and a Pod Identity association. Deleting the
# Agent lets those controllers delete the AWS objects they made. Delete the CLUSTER first and those
# roles survive with the permissions boundary attached, and terraform then cannot delete the policy.
if [[ "$KUBECTL_OK" -eq 1 ]]; then
  agents="$(kubectl get agents.agents.eks.amazonaws.com -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {end}' 2>/dev/null)"
  if [[ -n "${agents// /}" ]]; then
    note "agents: $agents"
    run kubectl delete agents.agents.eks.amazonaws.com --all -A --wait=false
    # Wait for the Agents to be GONE -- see agents_left -- printing what kro says each is blocked on
    # once a minute, so a slow composed object is named rather than discovered as a timeout.
    if [[ "$APPLY" -eq 1 ]]; then
      waited=0
      until agents_left; do
        if (( waited >= 900 )); then
          warn "Agents not gone after ${waited}s"
          release_stuck_agents || true
          break
        fi
        (( waited > 0 && waited % 60 == 0 )) && { note "still finalizing after ${waited}s:"; agent_blockers | sed 's/^/        /'; }
        sleep 10; waited=$((waited + 10))
      done
      agents_left && did "Agents deleted (after ${waited}s)"
    else
      note "would wait for: every Agent gone (up to 900s), naming each one's blocker every minute"
    fi
    # The roles go when ACK reconciles the deletion, which is not instant. Wait for the ACK custom
    # resources themselves to disappear rather than for a guessed number of seconds -- they are the
    # thing whose absence means the IAM role and the Pod Identity association are actually deleted,
    # and `kubectl delete agents` returning says only that the kro instance is gone.
    poll_until "ACK reconciled the Agents' IAM away" 180 \
      bash -c 'test -z "$(kubectl get roles.iam.services.k8s.aws,podidentityassociations.eks.services.k8s.aws \
                 -A --no-headers 2>/dev/null)"'
  else
    did "no Agent resources"
  fi
fi

# ---------------------------------------------------------------------------
step "2. Gateways and LoadBalancer Services, so the controllers release their load balancers"
# ---------------------------------------------------------------------------
# Each one is an ALB or NLB. Orphaned, they keep billing AND their ENIs hold the subnets, so the
# VPC delete fails with a DependencyViolation partway through `terraform destroy`.
if [[ "$KUBECTL_OK" -eq 1 ]]; then
  # Fully qualified: `gateway` is ambiguous on a cluster carrying ACK CRDs, and the short name
  # resolves to a different kind entirely.
  # ONLY WHERE THE GATEWAY API IS INSTALLED. On a cluster where ingress was never on the kinds do
  # not exist, and --ignore-not-found covers a missing object, not a missing resource type, so the
  # deletes would print "failed (continuing)" for nothing left behind.
  # READ FROM THE CRD, NOT FROM DISCOVERY. `kubectl api-resources` depends on the cluster's whole
  # discovery, which an unavailable aggregated API (KEDA's external metrics, for one) can leave
  # incomplete; an empty answer then reads as "no Gateway API", and the ingress Gateway stays, its
  # load balancer with it, and the agents namespace hangs on it.
  if kubectl get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  run kubectl delete gateways.gateway.networking.k8s.io --all -A --wait=true --timeout=300s
  # AND THEIR GATEWAYCLASS. It is cluster-scoped, so no namespace delete reaches it, and it holds
  # its LoadBalancerConfiguration (parametersRef) in use -- so the managed controller keeps that
  # object's finalizer and the namespace holding it hangs Terminating with
  #   "loadbalancerconfigurations.gateway.k8s.aws has 1 resource instances"
  # Deleting the class releases it.
  run kubectl delete gatewayclasses.gateway.networking.k8s.io -l app.kubernetes.io/part-of=eks-agents-paved-paths \
    --ignore-not-found --wait=true --timeout=120s
  else
    did "no Gateway API on this cluster, so no Gateways or GatewayClasses to delete"
  fi
  svcs="$(kubectl get svc -A --no-headers 2>/dev/null | awk '$3=="LoadBalancer"{print $1"/"$2}')"
  if [[ -n "$svcs" ]]; then
    note "LoadBalancer services: $(echo "$svcs" | tr '\n' ' ')"
    while read -r s; do
      [[ -z "$s" ]] && continue
      run_bg kubectl delete svc "${s#*/}" -n "${s%/*}" --wait=true --timeout=300s
    done <<< "$svcs"
    wait_all
  else
    did "no LoadBalancer services"
  fi

  # THE DNS RECONCILER, after the routes and before the zone.
  #
  # external-dns runs `policy: sync`, so it DELETES the records whose routes have gone -- which is
  # why it is stopped here rather than first: let it see the routes disappear, then remove it. The
  # private hosted zone is force_destroy either way, so a record it did not get to does not block
  # the destroy; what this avoids is a controller still writing to Route 53 while Terraform is
  # removing the role it writes with, which logs an access denial every interval and reads like a
  # permissions problem.
  if kubectl get ns external-dns >/dev/null 2>&1; then
    run kubectl delete ns external-dns --wait=true --timeout=180s
  else
    did "no external-dns namespace"
  fi

  # Waiting on the condition rather than on a guess: the Service going does not mean the load
  # balancer went, and it is the ENIs that block the VPC delete.
  poll_until "load balancers for $CLUSTER released" 240 lbs_released
fi

# ---------------------------------------------------------------------------
step "3. PersistentVolumeClaims, which is where the real lingering cost is"
# ---------------------------------------------------------------------------
# Deleting a PVC while the cluster is alive lets the EBS CSI driver delete the volume. Deleting the
# CLUSTER first leaves the volume with no controller to reclaim it, and it bills until somebody
# finds it in the EC2 console months later.
#
# Two things to know before trusting this step:
#   - a PV with reclaimPolicy: Retain is kept DELIBERATELY. Langfuse's Postgres ships
#     persistentVolumeClaimRetentionPolicy.whenDeleted: Retain, so its volume survives on purpose.
#     This prints those rather than forcing them, because the whole point of Retain is that a human
#     decides.
#   - the sweep in step 11 is what proves the volumes actually went.
if [[ "$KUBECTL_OK" -eq 1 ]]; then
  retained="$(kubectl get pv -o jsonpath='{range .items[?(@.spec.persistentVolumeReclaimPolicy=="Retain")]}{.metadata.name}{"|"}{.spec.claimRef.namespace}/{.spec.claimRef.name}{"|"}{.spec.csi.volumeHandle}{"\n"}{end}' 2>/dev/null)"
  if [[ -n "${retained// /}" ]]; then
    RETAINED_N="$(printf '%s\n' "$retained" | grep -c . )"
    warn "PersistentVolumes with reclaimPolicy: Retain -- these SURVIVE on purpose, delete by hand"
    while IFS='|' read -r pv claim vol; do
      [[ -z "$pv" ]] && continue
      note "$pv  claim=$claim  volume=$vol"
    done <<< "$retained"
  fi

  # SCALING THE WORKLOAD DOWN DOES NOT WORK when an operator owns it, and deleting the PVC alone
  # leaves it Terminating forever. The prometheus-operator recreates its StatefulSet pod within
  # seconds of a scale to zero, and CloudNativePG does the same for its Cluster, so the volumes stay
  # `in-use` and the PVCs hang.
  #
  # Worse, scaling the OPERATOR down first deadlocks it: its own CRs then have nothing left to
  # process their finalizers, and the namespace sits Terminating with "All content successfully
  # deleted" while the objects are still there.
  #
  # So delete the owning custom resource -- or the whole namespace, which is simpler -- and leave
  # the operator running until its CRs are gone. Delete operator namespaces LAST.
  for ns in $NS_REASONING $NS_EXECUTION $NS_GATEWAY $NS_MEMORY $NS_PLATFORM; do
    pvcs="$(kubectl get pvc -n "$ns" --no-headers 2>/dev/null | awk '{print $1}')"
    [[ -z "$pvcs" ]] && continue
    note "$ns: $(echo "$pvcs" | tr '\n' ' ')"
    # --wait=false ON PURPOSE. A PVC still mounted by a running pod carries
    # kubernetes.io/pvc-protection, so the delete is ACCEPTED and then blocks until the pod goes. A
    # wait here would time out and report a failure for a deletion that is correctly registered and
    # that step 5 completes.
    #
    # So register the intent here and let step 5 release it. Nothing is lost by not waiting: the
    # volumes are verified against AWS at the end of step 5, which is the only check that matters.
    run_bg kubectl delete pvc --all -n "$ns" --wait=false
  done
  wait_all
  note "deletion registered, not finished: a mounted PVC waits on its pod. Step 5 is what evicts it."
fi

# ---------------------------------------------------------------------------
step "4. No Argo CD Application is left (step 0 orphaned them)"
# ---------------------------------------------------------------------------
# selfHeal is on for the child Applications. Delete the workloads without removing the root and the
# controller puts them back, PVCs included.
if [[ "$KUBECTL_OK" -eq 1 ]]; then
  if kubectl get applications.argoproj.io eks-agents-platform -n argocd >/dev/null 2>&1; then
    note "deleting the root Application removes the children it created, and the finalizer makes"
    note "that an uninstall rather than an orphaning"
    run kubectl delete applications.argoproj.io eks-agents-platform -n argocd --wait=true --timeout=600s
  else
    did "no root Application"
  fi
fi

# ---------------------------------------------------------------------------
step "5. The namespaces, which is what removes the workloads on a cluster you are KEEPING"
# ---------------------------------------------------------------------------
# On a cluster about to be destroyed this is redundant. On one that survives it is the step that
# actually removes the running workloads, and it has to happen before the CRDs below: delete a CRD
# while an operator's custom resource still has a finalizer and the namespace hangs Terminating.
#
# Operator namespaces go LAST for the reason in step 3 -- an operator scaled down before its own
# CRs are gone has nothing left to process their finalizers.
#
# THIS STEP RUNS EVEN WITH --cluster-going-away, and it is the reason that flag does not skip it.
# "The cluster delete removes the namespaces anyway" is true and beside the point: deleting the
# namespace is what evicts the pods, which is what lets the PVCs deleted in step 3 finish, which is
# what makes the CSI driver delete the EBS volumes. Skip it and the cluster goes away with its
# volumes still attached to nothing -- the single most expensive thing this script exists to stop.
if [[ "$KUBECTL_OK" -eq 1 ]]; then
  # Parallel WITHIN each group and serial BETWEEN them. The two groups are the ordering constraint
  # from step 3 -- operators outlive their own custom resources -- and `wait_all` is what enforces
  # it. Parallelising across the barrier would deadlock exactly as described above.
  for ns in $NS_REASONING $NS_EXECUTION $NS_GATEWAY $NS_MEMORY $NS_INGRESS $NS_EVALS $NS_CONSENT; do
    kubectl get ns "$ns" >/dev/null 2>&1 || continue
    run_bg kubectl delete ns "$ns" --wait=true --timeout=300s
  done
  wait_all

  # AN AGGREGATED API WHOSE SERVER IS IN A NAMESPACE BEING DELETED goes first. KEDA registers
  # v1beta1.external.metrics.k8s.io, served from its own namespace. Once that namespace's pods are
  # gone, the APIService is unavailable, and the namespace controller, which has to list every
  # resource type to empty a namespace, can't finish ANY namespace (NamespaceDeletionDiscoveryFailure),
  # so each delete below waits out its timeout, and on a cluster you keep they stay Terminating.
  # Nothing else serves these APIs, so deleting the registration loses nothing.
  local_ops=" $NS_PLATFORM istio-system cnpg-system "
  for svc in $(kubectl get apiservices -o jsonpath='{range .items[?(@.spec.service)]}{.metadata.name}={.spec.service.namespace}{"\n"}{end}' 2>/dev/null); do
    [[ "$local_ops" == *" ${svc#*=} "* ]] && run kubectl delete apiservice "${svc%%=*}" --timeout=60s
  done
  for ns in $NS_PLATFORM istio-system cnpg-system; do
    kubectl get ns "$ns" >/dev/null 2>&1 || continue
    run_bg kubectl delete ns "$ns" --wait=true --timeout=300s
  done
  wait_all

  # A NAMESPACE STILL TERMINATING says why, so the cause is in the log rather than guessed at: its
  # own conditions (what it is waiting for), and any aggregated API that is unavailable.
  for ns in $NS_REASONING $NS_EXECUTION $NS_GATEWAY $NS_MEMORY $NS_INGRESS $NS_EVALS $NS_CONSENT $NS_PLATFORM istio-system cnpg-system; do
    [[ "$(kubectl get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)" == Terminating ]] || continue
    echo "  ! namespace $ns is still Terminating:"
    kubectl get ns "$ns" -o jsonpath='{range .status.conditions[?(@.status=="True")]}{"      "}{.type}: {.message}{"\n"}{end}' 2>/dev/null
  done
  kubectl get apiservices --no-headers 2>/dev/null | awk '$3 != "True" {print "  ! unavailable APIService: " $0}'

  # THE ONE CHECK IN THIS SCRIPT WORTH WAITING FOR. The pods are gone, so the PVCs from step 3 have
  # finished, so the CSI driver has deleted the volumes -- or it has not, and this is the last moment
  # at which a driver still exists to do it. An orphaned volume bills monthly, is invisible on the
  # EKS console once the cluster goes, and nothing later in this teardown can reclaim it.
  #
  # The target is NOT zero. A PV with reclaimPolicy: Retain is kept on purpose and its volume
  # survives on purpose, so this waits for the count to reach the number of those rather than zero;
  # waiting for zero would burn the cap on every cluster that has one and report a timeout for
  # working-as-intended behaviour.
  poll_until "EBS volumes for $CLUSTER deleted (down to the $RETAINED_N retained)" 300 volumes_released
fi

# ---------------------------------------------------------------------------
step "5a. Helm releases scripts/install-platform.sh made, WHILE THEIR CRDs STILL EXIST"
# ---------------------------------------------------------------------------
# Without Argo CD the platform arrives as Helm releases, and nothing above removes them: their
# cluster-scoped objects -- the CSI driver's DaemonSets, ClusterRoles, the release records -- outlive
# every namespace. And they must go BEFORE step 7 deletes the CRDs, because Helm builds the delete
# from the release manifest: once a kind in it is gone, `helm uninstall` refuses the whole release
#   unable to build kubernetes objects for delete: no matches for kind "Gateway"
#
# Only names this stack's Applications declare are uninstalled -- the same release names
# install-platform.sh derives (helm.releaseName, else the Application name) -- so a release
# somebody else installed on a cluster you keep is never touched.
if [[ "$KUBECTL_OK" -eq 1 ]] && command -v helm >/dev/null 2>&1; then
  # The names come from the platform chart RENDERED, not from its templates, which are not YAML
  # until rendered. helm is certain here (this step runs only with it), and it is the chart
  # install-platform.sh renders, here with every template in (`excluded: []`), so a layer turned off
  # after it was installed still has its release found and removed.
  ours="$(python3 - "$(dirname "$0")/.." "$PATH_NAME" <<'PY'
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "scripts" / "lib"))
import platform_render
names = set()
for docs in platform_render.render(sys.argv[1], sys.argv[2]).values():
    for d in docs:
        if d.get("kind") != "Application":
            continue
        names.add(d["metadata"]["name"])
        spec = d.get("spec", {})
        for src in [spec.get("source")] + list(spec.get("sources") or []):
            if src and (src.get("helm") or {}).get("releaseName"):
                names.add(src["helm"]["releaseName"])
print("\n".join(sorted(names)))
PY
)"
  # THE CLUSTER NETWORK POLICIES FIRST, while the enforcement ConfigMap still exists. The base
  # release OWNS amazon-vpc-cni (templates/10-network-policy-controller.yaml), so uninstalling it
  # switches the network policy controller off -- and the controller is what removes each
  # ClusterNetworkPolicy's `networking.k8s.aws/cnp-resources` finalizer. With it off, step 7's
  # deletes wait forever on objects that cannot finish deleting: they hang until the ConfigMap is
  # recreated, then clear in seconds. Step 7 deletes them before the ConfigMap for the same reason,
  # and running this step first must not undo that order.
  for p in eks-agents-infrastructure eks-agents-execution-tier-no-egress \
           eks-agents-dns eks-agents-approved-destinations eks-agents-gateway-only eks-agents-cluster-api eks-agents-mcp-servers eks-agents-reasoning-default-deny; do
    kubectl get clusternetworkpolicies.networking.k8s.aws "$p" >/dev/null 2>&1 || continue
    run_bg kubectl delete clusternetworkpolicies.networking.k8s.aws "$p" --timeout=180s
  done
  wait_all

  found=0
  while read -r rel relns; do
    [[ -z "$rel" ]] && continue
    grep -qxF "$rel" <<<"$ours" || continue
    found=1
    run_bg helm uninstall "$rel" -n "$relns" --wait --timeout 5m
  done < <(helm list -A -o json 2>/dev/null | python3 -c 'import json,sys
for r in json.load(sys.stdin): print(r["name"], r["namespace"])' 2>/dev/null)
  wait_all
  [[ "$found" -eq 0 ]] && did "no Helm releases from install-platform.sh"
fi

# ---------------------------------------------------------------------------
step "5b. kro's ResourceGraphDefinitions, WHILE KRO IS STILL ALIVE"
# ---------------------------------------------------------------------------
#
# THIS HAS TO HAPPEN BEFORE STEP 6, not in step 7 -- after the capability that processes the
# finalizer is deleted.
#
# An RGD carries `kro.run/finalizer`. Deleting the kro capability removes the only controller that
# can clear it, so a delete issued afterwards hangs for its whole timeout, reports
# `failed (continuing)`, and leaves the object Terminating FOREVER on a cluster you keep: `agent`
# sits with deletionTimestamp set and finalizers=["kro.run/finalizer"] with no kro capability left
# to process it.
#
# Step 6's own comment says kro "has to be alive to de-register the Agent kind cleanly"; this is
# the order that comment describes.
if [[ "$KUBECTL_OK" -eq 1 ]]; then
  if kubectl get resourcegraphdefinitions.kro.run >/dev/null 2>&1; then
    rgds="$(kubectl get resourcegraphdefinitions.kro.run -o name 2>/dev/null)"
    if [[ -n "${rgds// /}" ]]; then
      note "$(printf '%s\n' $rgds | wc -l | tr -d ' ') ResourceGraphDefinition(s), deleted before the kro capability"
      run kubectl delete resourcegraphdefinitions.kro.run --all --wait=true --timeout=300s
    else
      did "no ResourceGraphDefinitions"
    fi
  else
    did "no kro CRDs: nothing to de-register"
  fi
fi

# ---------------------------------------------------------------------------
step "6. EKS Capabilities, which keep billing and are not terraform's on a cluster you kept"
# ---------------------------------------------------------------------------
# NOT WHILE AN AGENT IS STILL FINALIZING: with kro or ACK gone it never can. See agents_left.
if [[ "$KUBECTL_OK" -eq 1 && "$APPLY" -eq 1 ]] && ! agents_left; then
  release_stuck_agents || true
fi
# These run OFF-cluster, so nothing inside the cluster reflects them and deleting namespaces does
# not touch them. They go after the steps above because ACK has to be alive to delete the IAM it
# created for each Agent, and kro has to be alive to de-register the Agent kind cleanly.
# ONLY THIS STACK'S THREE. A cluster you keep can run capabilities of its own -- an Argo CD a team
# installed ahead of this stack -- and a delete of everything listed would remove them. Terraform
# names this stack's <name>-ack, <name>-kro and <name>-argocd. A list that FAILS is reported, not read as
# empty: from a bastion without eks:ListCapabilities it would otherwise print "no EKS capabilities".
caps=""
if allcaps="$(aws eks list-capabilities --cluster-name "$CLUSTER" --region "$REGION" \
      --query 'capabilities[].capabilityName' --output text 2>&1)"; then
  for c in $allcaps; do
    case "$c" in "${CLUSTER}-ack"|"${CLUSTER}-kro"|"${CLUSTER}-argocd") caps="$caps $c" ;; esac
  done
  others="$(printf '%s\n' $allcaps | grep -v -x -e "${CLUSTER}-ack" -e "${CLUSTER}-kro" -e "${CLUSTER}-argocd" | tr '\n' ' ')"
  [[ -n "${others// /}" ]] && note "left alone, not this stack's: $others"
else
  warn "could not list EKS capabilities: $(printf '%s' "$allcaps" | tail -1 | cut -c1-160)"
fi
if [[ -n "${caps// /}" ]]; then
  for c in $caps; do
    run_bg aws eks delete-capability --cluster-name "$CLUSTER" --capability-name "$c" --region "$REGION"
  done
  wait_all
  # The CRD step below depends on these being actually gone, not merely requested. delete-capability
  # returns as soon as it is accepted, and a capability whose CRDs are deleted while it is still
  # DELETING re-registers them.
  poll_until "EKS capabilities deleted" 300 capabilities_gone
else
  did "no EKS capabilities"
fi

# ---------------------------------------------------------------------------
step "7. Cluster-scoped objects, which ONLY a surviving cluster keeps"
# ---------------------------------------------------------------------------
# Read the header for what this step finds. The ordering inside this step matters:
#
#   webhooks first, because a failurePolicy: Fail webhook whose Service is gone makes every
#   matching CREATE fail -- including anything a later step might need to create;
#   then the admission policy, then RBAC, then the CRDs.
#
# Deleting a CRD deletes every custom resource defined against it, so an ACK CR still present here
# would have its AWS resource ORPHANED rather than deleted. Steps 1-5 are what empty them; this
# checks rather than assumes, and refuses to delete the ACK CRDs if any are left.
if [[ "$KUBECTL_OK" -eq 1 && "$GOING_AWAY" -eq 1 ]]; then
  did "skipped: --cluster-going-away, and every object here dies with the cluster"
  note "This is the slow step -- hundreds of CRDs, each a serial API call -- and the only one whose whole"
  note "purpose is a cluster that survives. Drop the flag if the cluster is one you are keeping."
elif [[ "$KUBECTL_OK" -eq 1 ]]; then
  # --- admission webhooks. Scoped to the releases this stack installs, by name.
  # One call per kind with --ignore-not-found, rather than a get and a delete per name: the flag
  # keeps absent names from printing an error.
  run kubectl delete mutatingwebhookconfiguration --ignore-not-found \
    cert-manager-webhook cnpg-mutating-webhook-configuration istio-sidecar-injector \
    kube-prometheus-stack-admission clickhouse-operator-mutating-webhook-configuration
  run kubectl delete validatingwebhookconfiguration --ignore-not-found \
    cert-manager-webhook cnpg-validating-webhook-configuration istio-validator-istio-system \
    istiod-default-validator kube-prometheus-stack-admission \
    clickhouse-operator-validating-webhook-configuration

  # --- this stack's own admission policies. The bindings go first: a policy with a live binding is
  # still enforced, and deleting them the other way round leaves a window where it is not.
  #
  # BY LABEL, not by name. There are two -- the sandbox rule and ingress's
  # eks-agents-ingress-authenticated -- and naming only the first leaves the second behind,
  # where it refuses the next HTTPRoute attached to a Gateway of that name.
  run kubectl delete validatingadmissionpolicybinding -l app.kubernetes.io/part-of=eks-agents-paved-paths --ignore-not-found
  run kubectl delete validatingadmissionpolicy -l app.kubernetes.io/part-of=eks-agents-paved-paths --ignore-not-found

  # --- THE CAPABILITIES' ACCESS ENTRIES, which EKS creates and does not remove.
  #
  # Creating a capability makes an EKS access entry for its role, with the matching managed access
  # policy (AmazonEKSACKPolicy and friends), and deleting the capability does not remove the entry. On a
  # kept cluster all three are still present after the capabilities are deleted AND after
  # `terraform destroy` removes the IAM roles they name -- so they point at deleted principals.
  #
  # The sweep in step 11 reports these, but only this step deletes them. They carry no charge, but a
  # dangling access entry is cluster configuration naming a deleted role, and on a cluster you keep
  # that is exactly the kind of thing nobody finds later.
  #
  # Scoped to this stack's own naming, <cluster>-capability-<type>, so an access entry somebody else
  # created is never touched.
  # LISTED AND MATCHED, not constructed. Building the ARN would need the partition and the account
  # id, neither of which this script otherwise has -- and an ARN assembled from a wrong partition
  # silently matches nothing, which reads as "already clean".
  # A LIST THAT FAILS IS NOT AN EMPTY LIST. Discarding its error would, on a bastion whose role
  # cannot list access entries, report "no capability access entries left" with all three still
  # present.
  cap_entries="" listed=0
  if all_entries="$(aws eks list-access-entries --cluster-name "$CLUSTER" --region "$REGION" \
       --query 'accessEntries[]' --output text 2>/dev/null)"; then
    listed=1
    cap_entries="$(tr '\t' '\n' <<<"$all_entries" | grep -E "role/${CLUSTER}-capability-(ack|kro|argocd)$" || true)"
  else
    warn "cannot list access entries from here; the sweep (step 11) lists any left, and"
    warn "  aws eks delete-access-entry --cluster-name $CLUSTER --principal-arn <arn> removes one"
  fi
  if [[ "$listed" -eq 0 ]]; then
    :
  elif [[ -n "${cap_entries// /}" ]]; then
    while read -r pa; do
      [[ -z "$pa" ]] && continue
      run aws eks delete-access-entry --cluster-name "$CLUSTER" --region "$REGION" --principal-arn "$pa"
    done <<< "$cap_entries"
  else
    did "no capability access entries left"
  fi

  # --- THE AGENTS' OWN NODEPOOL AND NODECLASS, which cost money if they are left.
  #
  # This is the one item in this step with a RUNNING BILL rather than a configuration smell. The
  # NodePool is cluster-scoped, nothing namespaced owns it, and it survives everything above: on a
  # kept cluster `nodepool.karpenter.sh/eks-agents` is still `Ready` with `NodeClassReady` after a
  # full teardown. A Ready NodePool PROVISIONS INSTANCES for
  # any pod that matches its selector and tolerates its taint, so leaving it behind leaves an
  # autoscaler attached to a cluster whose agents are gone.
  #
  # ORDER MATTERS: the NodePool references the NodeClass, so the pool goes first. Deleting it also
  # drains and terminates the nodes it launched, which is the point -- those are this stack's nodes,
  # tainted for agents, and nothing else was scheduled on them.
  # BY LABEL, NOT BY THE DEFAULT NAME. `nodeClass.name` is a chart value -- `eks-agents` is only its
  # default -- so a platform team that renamed it would have had these left behind by a name-scoped
  # delete, silently, which is the failure this whole step exists to stop. Both objects carry
  # app.kubernetes.io/part-of, and that is what identifies them whatever they are called.
  #
  # The name is still checked as a fallback: a label selector that matches nothing exits 0 and reads
  # like success, so neither mechanism is trusted alone.
  for sel in "-l app.kubernetes.io/part-of=eks-agents-paved-paths" "eks-agents --ignore-not-found"; do
    pools="$(kubectl get nodepool.karpenter.sh $sel -o name 2>/dev/null)"
    [[ -z "${pools// /}" ]] && continue
    for np in $pools; do
      pname="${np#*/}"
      nodes_from_pool="$(kubectl get nodes -l "karpenter.sh/nodepool=$pname" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
      note "nodepool $pname has $nodes_from_pool node(s); deleting the pool drains them"
      run kubectl delete nodepool.karpenter.sh "$pname" --wait=true --timeout=600s
    done
  done
  for sel in "-l app.kubernetes.io/part-of=eks-agents-paved-paths" "eks-agents --ignore-not-found"; do
    classes="$(kubectl get nodeclass.eks.amazonaws.com $sel -o name 2>/dev/null)"
    [[ -z "${classes// /}" ]] && continue
    for nc in $classes; do
      run kubectl delete nodeclass.eks.amazonaws.com "${nc#*/}" --wait=true --timeout=300s
    done
  done

  # --- the namespace the ARGOCD capability created. The capability runs OFF-cluster and does not
  # remove it, so on a kept cluster it stays: after a teardown that
  # reports clean, `argocd` still holds argocd-webhook-creds-secret, the destination and repository
  # secrets, and the `default` and `eks-agents` AppProjects.
  #
  # DELETED ONLY WHEN ALL THREE SAY IT IS THIS STACK'S. A self-managed Argo CD conventionally lives in
  # `argocd` too, and deleting its namespace would take somebody else's control plane with it.
  #   1. no Deployment, StatefulSet or DaemonSet in it: a self-managed Argo CD runs a repo-server,
  #      an application-controller and a server at minimum; the capability runs none
  #   2. no ARGOCD capability left on the cluster: step 6 deleted this stack's, and one still ACTIVE (a
  #      step 6 that could not run from here) still uses the namespace. A failed list is a no
  #   3. no Application or AppProject this stack did not create. `argocd/default` is Argo CD's own
  #      and present on every installation; everything else of this stack's carries the part-of label
  if kubectl get ns argocd >/dev/null 2>&1; then
    argo_workloads="$(kubectl -n argocd get deploy,sts,ds --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if argo_caps="$(aws eks list-capabilities --cluster-name "$CLUSTER" --region "$REGION" \
          --query 'capabilities[?type==`ARGOCD` || ends_with(capabilityName, `argocd`)].capabilityName' --output text 2>/dev/null)"; then
      argo_caps="$(tr -d '[:space:]' <<<"$argo_caps")"
    else
      argo_caps="(could not list)"
    fi
    foreign_argo="$(kubectl get applications.argoproj.io,appprojects.argoproj.io -n argocd \
      -l 'app.kubernetes.io/part-of!=eks-agents-paved-paths' \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -v '^default$' | grep -c . || true)"
    if [[ "$argo_workloads" == "0" && -z "$argo_caps" && "$foreign_argo" == "0" ]]; then
      note "the 'argocd' namespace is the ARGOCD capability's: no workloads, no capability left, no Argo CD objects but this stack's"
      run kubectl delete ns argocd --wait=true --timeout=180s
    else
      warn "the 'argocd' namespace still exists and is NOT deleted"
      [[ "$argo_workloads" != "0" ]] && note "$argo_workloads workload(s) in it: a self-managed Argo CD runs here, not the capability"
      [[ -n "$argo_caps" ]] && note "an ARGOCD capability is still on the cluster: $argo_caps"
      [[ "$foreign_argo" != "0" ]] && note "$foreign_argo Application/AppProject object(s) this stack did not create"
    fi
  fi

  # --- the default StorageClass this stack installs. EKS Auto Mode ships NO default StorageClass,
  # so removing this returns the cluster to that state rather than to some other default.
  run kubectl delete storageclass eks-agents-gp3 --ignore-not-found

  # --- THE CLUSTER-SCOPED NETWORK POLICIES, which nothing else here removes.
  #
  # On a cluster you KEEP they are the worst thing to leave behind -- worse than residue, because
  # they change the surviving cluster's posture rather than merely sitting in it. The Admin tier
  # evaluates FIRST and an Accept there ends evaluation:
  #
  #   eks-agents-infrastructure (priority 1) accepts both directions for kube-system,
  #   istio-system and monitoring. Left behind, every network policy the cluster's own owner later
  #   writes for those namespaces is inert, and no object reports the overlap.
  #
  #   eks-agents-execution-tier-no-egress (priority 10) denies both directions for the execution
  #   namespace. Left behind, a namespace the owner later creates with that name is dead on
  #   arrival, with nothing to explain why.
  #
  # Deleted by name rather than by label, because a label selector that matches nothing exits 0 and
  # reads exactly like success -- see the Istio CRDs in step 7 below.
  for p in eks-agents-infrastructure eks-agents-execution-tier-no-egress \
           eks-agents-dns eks-agents-approved-destinations eks-agents-gateway-only eks-agents-cluster-api eks-agents-mcp-servers eks-agents-reasoning-default-deny; do
    kubectl get clusternetworkpolicies.networking.k8s.aws "$p" >/dev/null 2>&1 || continue
    # A bounded wait: a finalizer the controller cannot remove hangs an unbounded delete.
    run_bg kubectl delete clusternetworkpolicies.networking.k8s.aws "$p" --timeout=180s
  done
  wait_all
  # The namespaced tier goes with its namespace in step 5, so this catches only the case where a
  # namespace was kept -- an agent namespace somebody wanted to keep, or step 5 timing out.
  run kubectl delete applicationnetworkpolicies.networking.k8s.aws \
    -A -l app.kubernetes.io/part-of=eks-agents-paved-paths --ignore-not-found

  # --- ENFORCEMENT ITSELF, and only if this stack is what turned it on.
  #
  # The amazon-vpc-cni ConfigMap is the CLUSTER'S, not this release's, and on a cluster that already
  # had network policy enforcement it existed before any of this ran. Deleting it unconditionally
  # would change a configuration this stack never set. So: delete it only when it carries this
  # stack's label, which the chart sets and which a pre-existing ConfigMap does not have.
  #
  # VERIFY THE RESULT RATHER THAN ASSUMING IT. Removing the object returns the cluster to its
  # default, and whether that default is "enforcement off" is the cluster's business, not this
  # script's -- so this reports what it did and leaves you to check.
  if [[ "$(kubectl -n kube-system get configmap amazon-vpc-cni \
             -o jsonpath='{.metadata.labels.app\.kubernetes\.io/part-of}' 2>/dev/null)" \
        == "eks-agents-paved-paths" ]]; then
    note "the enforcement ConfigMap carries this stack's label, so this stack created it"
    run kubectl delete configmap amazon-vpc-cni -n kube-system
    note "confirm the cluster's resulting state, which is its default rather than a value this stack set:"
    note "  kubectl -n kube-system get cm amazon-vpc-cni -o jsonpath='{.data.enable-network-policy-controller}'"
  elif kubectl -n kube-system get configmap amazon-vpc-cni >/dev/null 2>&1; then
    warn "leaving the amazon-vpc-cni ConfigMap: it does not carry this stack's label, so it is the"
    note "cluster's own configuration and predates this install. Enforcement stays as you had it."
  else
    did "no enforcement ConfigMap to remove"
  fi

  # --- Helm release history and the ConfigMaps istiod writes into every namespace.
  run kubectl delete secret -n default --field-selector type=helm.sh/release.v1
  # ONE list call for every namespace at once, rather than a get per namespace followed by a delete
  # per namespace. istiod writes these into EVERY namespace including kube-system.
  istio_cms="$(kubectl get cm -A --field-selector metadata.name=istio-ca-root-cert \
                 -o jsonpath='{range .items[*]}{.metadata.namespace} {end}' 2>/dev/null)"
  if [[ -n "${istio_cms// /}" ]]; then
    for ns in $istio_cms; do
      run_bg kubectl delete cm istio-ca-root-cert istio-ca-crl -n "$ns" --ignore-not-found
    done
    wait_all
  else
    did "no istio CA ConfigMaps"
  fi

  # --- cluster RBAC, by the label each chart sets, then the two this repository names itself.
  for sel in app.kubernetes.io/part-of=istio app.kubernetes.io/name=cert-manager \
             app.kubernetes.io/name=agentgateway; do
    run kubectl delete clusterrole,clusterrolebinding -l "$sel"
  done
  run kubectl delete clusterrole,clusterrolebinding --ignore-not-found \
    eks-agents-kro-composer agent-sandbox-controller agent-sandbox-controller-extensions \
    cloudnative-pg kube-prometheus-stack-operator kube-prometheus-stack-prometheus \
    kube-prometheus-stack-kube-state-metrics

  # --- CRDs. kro's own resource definition goes first, so kro de-registers the Agent kind rather
  # than leaving an orphaned CRD behind, and the kro-owned label is what catches the kinds a graph
  # defined -- including any validation kinds this repo's examples register.
  # The RGDs went in step 5b, while kro could still finalize them. What is left here is the
  # RECOVERY case: an RGD already Terminating with kro gone, which no amount of waiting fixes
  # because the controller that owns the finalizer does not exist. Stripping the finalizer is the
  # only way out, and it is safe precisely because kro is gone -- there is no reconciliation left to
  # interrupt, and the composed objects were removed with their namespaces.
  stuck="$(kubectl get resourcegraphdefinitions.kro.run \
    -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
  if [[ -n "${stuck// /}" ]]; then
    warn "ResourceGraphDefinition(s) stuck Terminating with no kro to finalize them: $(echo "$stuck" | tr '\n' ' ')"
    note "Removing the kro finalizer, which is the only thing that clears this. Safe here because"
    note "the capability is already gone: nothing is reconciling and the composed objects went with"
    note "their namespaces in step 5."
    while read -r r; do
      [[ -z "$r" ]] && continue
      run kubectl patch resourcegraphdefinitions.kro.run "$r" --type=merge \
        -p '{"metadata":{"finalizers":null}}'
    done <<< "$stuck"
  fi
  # The kro capability is gone, so any instance left of a kro-owned kind keeps its CRD Terminating
  # forever: release them (only when no ACK-made IAM survives), and never wait without a bound.
  release_stuck_agents || true
  run kubectl delete crd -l kro.run/owned=true --wait=true --timeout=120s

  # LABEL SELECTORS ARE NOT ENOUGH HERE: relying on them makes a teardown report clean while
  # leaving CRDs behind. `helm uninstall istio-base` removes the release and leaves all 15 istio.io
  # CRDs in place, and those CRDs carry NO labels at all -- so
  # `kubectl delete crd -l app.kubernetes.io/part-of=istio` matches nothing and exits 0, which reads
  # exactly like success. Helm never deletes CRDs it installed, so "release uninstalled" says
  # nothing about CRD residue either.
  #
  # The selectors are kept because a chart that does label its CRDs is cheaper to catch that way,
  # but the group-domain sweep below is what actually clears these.
  for sel in app.kubernetes.io/part-of=istio app.kubernetes.io/name=cert-manager \
             app.kubernetes.io/name=agentgateway; do
    run kubectl delete crd -l "$sel"
  done

  # The ACK group has NO labels at all, so the group domain is the only available scope. Check for
  # live resources before deleting, because this is the deletion that can orphan an AWS resource.
  ack_crds="$(kubectl get crd -o name 2>/dev/null | grep 'services\.k8s\.aws$' || true)"
  if [[ -n "${ack_crds// /}" ]]; then
    live="$(kubectl get $(printf '%s,' $ack_crds | sed 's/,$//') -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$live" != "0" ]]; then
      found "$live ACK resource(s) still exist -- NOT deleting the ACK CRDs"
      note "Deleting a CRD with live resources orphans the AWS object it represents. Delete these"
      note "first, while a controller is still there to reconcile the deletion:"
      note "  kubectl get \$(kubectl get crd -o name | grep 'services.k8s.aws\$' | paste -sd, -) -A"
    else
      note "$(printf '%s\n' $ack_crds | wc -l | tr -d ' ') ACK CRDs, no live resources"
      printf '%s\n' $ack_crds | xargs -n 25 kubectl delete >/dev/null 2>&1 \
        && did "deleted the ACK CRD group" || warn "failed (continuing): ACK CRD deletion"
    fi
  else
    did "no ACK CRDs"
  fi

  # Everything else this stack's Applications carry. Named by group, because these charts label
  # inconsistently -- CloudNativePG and the ClickHouse operator set only managed-by=Helm, which is
  # far too broad to delete on, and prometheus-operator and Agent Sandbox set nothing.
  # ONE list of the cluster's CRDs matched against every group at once, then ONE batched delete,
  # rather than listing every CRD again for each group and issuing a delete per group.
  all_crds="$(kubectl get crd -o name 2>/dev/null)"
  group_crds=""
  # argoproj.io IS INCLUDED, and it is the ARGOCD capability's, not a chart's. The capability is
  # created with delete_propagation_policy = RETAIN, so deleting it leaves its CRDs -- correct on a
  # cluster being destroyed, residue on a cluster you keep:
  # applications/applicationsets/appprojects.argoproj.io would stay.
  #
  # Guarded below by the same live-object check the ACK group gets, because deleting these CRDs
  # deletes every Application with them -- and on a cluster running a SELF-MANAGED Argo CD those
  # Applications are not this stack's.
  for g in postgresql.cnpg.io monitoring.coreos.com agents.x-k8s.io extensions.agents.x-k8s.io \
           clickhouse.com kro.run internal.kro.run argoproj.io \
           networking.istio.io security.istio.io telemetry.istio.io extensions.istio.io \
           agentgateway.dev cert-manager.io acme.cert-manager.io; do
    group_crds="$group_crds $(printf '%s\n' "$all_crds" | grep "\.${g}\$" || true)"
  done
  # A SELF-MANAGED ARGO CD IS SOMEBODY ELSE'S. If Applications or AppProjects still exist, the
  # argoproj CRDs are left alone and reported: the capability's own Applications went with the root
  # Application in step 4, so anything still here belongs to an Argo CD this stack did not install.
  # The `default` AppProject in `argocd` DOES NOT COUNT. Argo CD creates it itself on first start,
  # so it is present on every installation including the capability's, with no labels -- and
  # treating it as evidence of a self-managed Argo CD would make this guard fire on every cluster
  # and leave the CRDs behind every time.
  # NOR DOES THIS STACK'S OWN `eks-agents` AppProject, or anything else carrying the part-of label.
  # `argocd/eks-agents` survives step 4 (nothing deletes an AppProject when its Applications go), and
  # counted as "1 Argo CD object" it would keep the CRDs.
  live_argo="$(kubectl get applications.argoproj.io,appprojects.argoproj.io -A \
    -l 'app.kubernetes.io/part-of!=eks-agents-paved-paths' \
    -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -v '^argocd/default$' | grep -c . || true)"
  if [[ "$live_argo" != "0" ]]; then
    warn "$live_argo Argo CD object(s) still exist -- NOT deleting the argoproj.io CRDs"
    note "Deleting those CRDs would delete every Application with them, and these are not this"
    note "stack's: its own went with the root Application in step 4. A self-managed Argo CD on this"
    note "cluster keeps working. Remove them by hand if they are leftovers you do want gone."
    group_crds="$(printf '%s\n' $group_crds | grep -v 'argoproj\.io$' || true)"
  fi

  if [[ -n "${group_crds// /}" ]]; then
    note "$(printf '%s\n' $group_crds | wc -l | tr -d ' ') CRDs across the stack's own API groups"
    if [[ "$APPLY" -eq 1 ]]; then
      printf '%s\n' $group_crds | xargs -n 25 kubectl delete --ignore-not-found >/dev/null 2>&1 \
        && did "deleted the stack's CRD groups" || warn "failed (continuing): CRD group deletion"
    else
      note "would run: kubectl delete <those CRDs>"
    fi
  else
    did "no CRDs in the stack's own API groups"
  fi

  # --- The Gateway API CRDs. Whether these are the cluster's or this stack's depends on the path: an
  # EKS-managed set, installed when `gatewayApi.crds.managed` is true, must not be deleted, but
  # gitops/platform/open-source/templates/10-gateway-api-crds.yaml installs the upstream standard channel
  # itself, so on a cluster where that has run the CRDs are this stack's and nothing else removes them.
  #
  # On such a cluster the gateway.networking.k8s.io CRDs carry
  # `gateway.networking.k8s.io/bundle-version: v1.7.0`, channel `standard`, and a
  # `kubectl.kubernetes.io/last-applied-configuration` annotation, with no Helm or Argo CD ownership
  # labels -- which is the fingerprint of that Application's own kubectl apply, matching its pinned
  # v1.7.0 / config/crd/standard exactly. They stay there from the deploy on.
  #
  # So the discriminator is that annotation rather than the cluster setting, because the setting
  # cannot be read from the cluster description. An EKS-managed
  # CRD is not applied with kubectl and does not carry it. That is a fingerprint and not a
  # guarantee, so this reports what it is about to do and leaves anything it cannot attribute.
  #
  # AND ARGO CD'S OWN FINGERPRINT, because that Application syncs with ServerSideApply=true and a
  # server-side apply writes NO last-applied annotation: all 10 CRDs from
  # 10-gateway-api-crds.yaml lack it, and would be read as EKS-managed and stay. What
  # they do carry is Argo CD's resource tracking, which names the Application: the annotation
  # argocd.argoproj.io/tracking-id, `argocd_gateway-api-crds:...` on the managed capability (it
  # prefixes the Application's namespace) and `gateway-api-crds:...` upstream, or under label
  # tracking app.kubernetes.io/instance=gateway-api-crds. Any one attributes the CRD to this stack.
  #
  # THE CONTROLLERS' OWN GATEWAYCLASSES GO FIRST. The agentgateway controller creates its class on
  # startup, and istiod creates istio, istio-remote and istio-waypoint, all unlabelled, so step 2's
  # label selector misses them, and they then count as live Gateway API objects below and block the
  # CRD delete. Their controllers went with the namespaces in step 5; Istio's classes are removed only
  # once istio-system is gone, so a mesh this stack didn't remove keeps them.
  own_classes=""
  if [[ "$(kubectl get gatewayclasses.gateway.networking.k8s.io agentgateway \
         -o jsonpath='{.spec.controllerName}' 2>/dev/null)" == "agentgateway.dev/agentgateway" ]]; then
    own_classes="agentgateway"
  fi
  if ! kubectl get ns istio-system >/dev/null 2>&1; then
    for c in $(kubectl get gatewayclasses.gateway.networking.k8s.io \
                 -o jsonpath='{range .items[?(@.spec.controllerName)]}{.metadata.name}={.spec.controllerName}{"\n"}{end}' 2>/dev/null \
               | awk -F= '$2 ~ /^istio\.io\// {print $1}'); do
      own_classes="$own_classes $c"
    done
  fi
  for c in $own_classes; do
    run kubectl delete gatewayclasses.gateway.networking.k8s.io "$c" --wait=true --timeout=120s
  done
  gw_crds="$(kubectl get crd -o name 2>/dev/null | grep 'gateway\.networking\.k8s\.io$' || true)"
  if [[ -z "${gw_crds// /}" ]]; then
    did "no Gateway API CRDs"
  else
    ours=""
    for c in $gw_crds; do
      # Recorded in step 0 as owned by a Gateway API Application: this stack's, whatever the object carries.
      if [[ " $APP_CRDS " == *" ${c#*/} "* ]]; then ours="$ours $c"; continue; fi
      meta="$(kubectl get "$c" -o jsonpath='{.metadata.annotations}{"\n"}{.metadata.labels}' 2>/dev/null)"
      if grep -q 'kubectl.kubernetes.io/last-applied-configuration' <<<"$meta" \
         || grep -qE '"argocd.argoproj.io/tracking-id":"([a-z0-9-]+_)?gateway-api-crds:' <<<"$meta" \
         || grep -qE '"app.kubernetes.io/instance":"gateway-api-crds"' <<<"$meta"; then
        ours="$ours $c"
      fi
    done
    if [[ -z "${ours// /}" ]]; then
      did "left $(printf '%s\n' $gw_crds | wc -l | tr -d ' ') Gateway API CRDs alone (no kubectl-apply or Argo CD tracking fingerprint, so EKS-managed)"
    else
      # Instances of those kinds, so the resource names and not the CRD objects: `kubectl get` on
      # `customresourcedefinition.../a,customresourcedefinition.../b` is an error, which would read
      # as 0 and let this guard pass with Gateways still present. The controllers' classes deleted
      # above are left out, so a dry run reports what --yes would do.
      gw_kinds="$(printf '%s\n' $ours | sed 's#^customresourcedefinition\.apiextensions\.k8s\.io/##' | paste -sd, -)"
      live="$(kubectl get "$gw_kinds" -A -o name 2>/dev/null \
        | grep -vxF -f <(for c in $own_classes; do echo "gatewayclass.gateway.networking.k8s.io/$c"; done; echo "-") \
        | grep -c . || true)"
      if [[ "$live" != "0" ]]; then
        found "$live Gateway API object(s) still exist -- NOT deleting those CRDs"
        note "A Gateway still present here means a load balancer this script has not removed."
      else
        note "$(printf '%s\n' $ours | wc -l | tr -d ' ') Gateway API CRDs carry the fingerprint of 10-gateway-api-crds.yaml"
        run kubectl delete $ours
      fi
    fi
  fi

  # --- Every other CRD a Gateway API Application owned (step 0's record): the gateway.k8s.aws kinds
  # the base chart installs, on a cluster whose Auto
  # Mode setting leaves them unmanaged. They carry no mark either, and otherwise stay through every
  # teardown.
  # Deleted only when no object of the kind is left, so a Gateway still holding a load balancer
  # blocks it.
  for c in $APP_CRDS; do
    [[ "$c" == *.gateway.networking.k8s.io ]] && continue
    kubectl get crd "$c" >/dev/null 2>&1 || continue
    n="$(kubectl get "$c" -A --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [[ "$n" != "0" ]]; then
      found "$n object(s) of $c still exist -- NOT deleting that CRD"
    else
      run kubectl delete crd "$c"
    fi
  done

  # --- The Gateway API bundle's admission policy. config/crd/standard at v1.7.0 ships a
  # ValidatingAdmissionPolicy and its binding, both named safe-upgrades.gateway.networking.k8s.io,
  # alongside the CRDs. They are cluster-scoped and outlive the CRDs, and they refuse ANY later
  # install of Gateway API CRDs older than v1.7.0 -- so a kept cluster is left unable to take the
  # version a different controller pins. Without this, both stay from the
  # first deploy through every teardown after it. Attributed the same way as the
  # CRDs, by the tracking-id that names the gateway-api-crds Application; one installed by EKS or by
  # hand does not carry it and is left alone.
  for kind in validatingadmissionpolicybindings validatingadmissionpolicies; do
    vap_ours="$(kubectl get "${kind}.admissionregistration.k8s.io" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.argocd\.argoproj\.io/tracking-id}{"\n"}{end}' 2>/dev/null \
      | awk -F'\t' '$2 ~ /^([a-z0-9-]+_)?gateway-api-crds:/ {print $1}')"
    for v in $vap_ours; do
      run kubectl delete "${kind}.admissionregistration.k8s.io" "$v"
    done
  done
fi

# ---------------------------------------------------------------------------
step "8. ECR images, which block the repository delete"
# ---------------------------------------------------------------------------
# force_delete is false on the repositories on purpose: an apply must not be able to drop images as
# a side effect. That makes emptying them a deliberate step here instead.
#
# TWO PREFIXES, not one. terraform names these "${name}/${repo}", so with name=my-agents they are
# my-agents/agents/reasoning. But the repository list in var.ecr_repository_names already begins
# "agents/", and a repository created by hand from the quickstart is a bare agents/reasoning. Matching only "${CLUSTER}/" misses
# those repositories and their images, and the sweep would miss them for the same reason. Both
# prefixes are checked, and `agents/` is deliberately NOT treated as cluster-specific: it is
# reported rather than assumed, because two clusters in one account share it.
#
# AND FIRST, CAN THIS CREDENTIAL SEE ECR AND S3 AT ALL? Every query below swallows stderr and reads
# an empty result as "nothing there", so an AccessDenied prints `no ECR repositories named
# <cluster>/*` and the step reports clean. That is the same failure the sweep's own preflight exists
# to catch, in the two steps whose output `terraform destroy` actually depends on.
#
# Run on a bastion whose instance role reaches the cluster and little else, steps 8 and 9 would
# report nothing to do, and `terraform destroy` would then fail on RepositoryNotEmptyException and
# BucketNotEmpty -- the failures these two steps exist to prevent.
#
# So this is a refusal, not a warning: steps 8 and 9 are skipped outright rather than run blind,
# and the message says where to run them instead.
ACCOUNT_VISIBLE=1
for probe in "ecr:aws ecr describe-repositories --region $REGION --max-items 1" \
             "s3:aws s3api list-buckets --max-items 1"; do
  api="${probe%%:*}"; cmd="${probe#*:}"
  # ANY failure counts, rather than a list of exception names. A list of AccessDenied,
  # UnauthorizedOperation, ExpiredToken and InvalidClientTokenId misses UnrecognizedClientException,
  # and prints the same false clean this exists to prevent. The probe is a trivial read that every
  # credential meant to run these steps can do, so if it fails at all, for any reason, this
  # credential cannot see.
  err="$($cmd 2>&1 >/dev/null)" && continue
  ACCOUNT_VISIBLE=0
  found "cannot read $api from this credential -- steps 8 and 9 CANNOT run here"
  # grep -m1 . rather than head -1: the CLI's error output starts with a BLANK line.
  note "$(printf '%s' "$err" | grep -m1 . || true)"
done
if [[ "$ACCOUNT_VISIBLE" -eq 0 ]]; then
  note "This is the two-credential split in the header. Steps 1-7 need kubectl and so run inside the"
  note "VPC; steps 8-9 need account writes. On the bastion, bastion_teardown_access = true (the"
  note "default) grants them; without it the bastion's role lacks them. Re-run from a credential that has"
  note "them BEFORE the destroy, or the destroy fails on RepositoryNotEmptyException and BucketNotEmpty:"
  note "  ./scripts/teardown.sh --path $PATH_NAME --cluster $CLUSTER --region $REGION --yes"
fi
repos=""
bare=""
if [[ "$ACCOUNT_VISIBLE" -eq 1 ]]; then
repos="$(aws ecr describe-repositories --region "$REGION" \
  --query "repositories[?starts_with(repositoryName,'${CLUSTER}/')].repositoryName" --output text 2>/dev/null | tr '\t' '\n')"
bare="$(aws ecr describe-repositories --region "$REGION" \
  --query "repositories[?starts_with(repositoryName,'agents/')].repositoryName" --output text 2>/dev/null | tr '\t' '\n')"
fi
if [[ "$ACCOUNT_VISIBLE" -eq 0 ]]; then
  warn "step 8 skipped: no ECR visibility from here"
elif [[ -n "${repos// /}" ]]; then
  while read -r r; do
    [[ -z "$r" ]] && continue
    n="$(aws ecr list-images --region "$REGION" --repository-name "$r" --query 'length(imageIds)' --output text 2>/dev/null)"
    note "$r ($n image(s))"
    run aws ecr delete-repository --region "$REGION" --repository-name "$r" --force
  done <<< "$repos"
else
  did "no ECR repositories named ${CLUSTER}/*"
fi
if [[ -n "${bare// /}" ]]; then
  warn "unprefixed ECR repositories exist -- this script will NOT delete them"
  note "They carry no cluster name, so they may belong to another cluster in this account. Check,"
  note "then delete by hand:  aws ecr delete-repository --region $REGION --force --repository-name <r>"
  while read -r r; do
    [[ -z "$r" ]] && continue
    n="$(aws ecr list-images --region "$REGION" --repository-name "$r" --query 'length(imageIds)' --output text 2>/dev/null)"
    note "$r ($n image(s))"
  done <<< "$bare"
fi

# ---------------------------------------------------------------------------
step "9. The checkpoint and person-data buckets, including versions and delete markers"
# ---------------------------------------------------------------------------
# The bucket is versioned, so `aws s3 rm --recursive` leaves every non-current version and every
# delete marker behind and the bucket still refuses to delete. force_destroy is false on the
# resource deliberately: an apply must never be able to delete an agent's durable state.
#
# This leaves the BUCKET for terraform and only empties it.
# The person-data bucket (enable_person_access, <cluster>-person-data-*) is emptied the same way: it
# holds people's objects, and force_destroy is false on it for the same reason.
buckets=""
[[ "$ACCOUNT_VISIBLE" -eq 1 ]] && buckets="$(aws s3api list-buckets \
  --query "Buckets[?starts_with(Name,'${CLUSTER}-agent-checkpoints') || starts_with(Name,'${CLUSTER}-person-data')].Name" --output text 2>/dev/null)"
[[ -z "${buckets// /}" ]] && buckets="-"
for bucket in $buckets; do
[[ "$bucket" == "-" ]] && bucket=""
if [[ "$ACCOUNT_VISIBLE" -eq 0 ]]; then
  warn "step 9 skipped: no S3 visibility from here. The destroy WILL fail on BucketNotEmpty."
elif [[ -n "$bucket" ]]; then
  # A LISTING THAT FAILS IS NOT AN EMPTY BUCKET. The bastion's role can list the account's buckets
  # but not every bucket's versions, and with the error discarded its pass would report a
  # person-data bucket holding versions as "already empty"; only the account pass after it can
  # empty the bucket. Say so and leave the bucket to the pass that can read it.
  if ! aws s3api list-object-versions --bucket "$bucket" --max-items 1 >/dev/null 2>&1; then
    note "$bucket: cannot list its versions from here; the account pass empties it"
    continue
  fi
  objs="$(aws s3api list-object-versions --bucket "$bucket" \
    --query 'length(Versions[]) || `0`' --output text 2>/dev/null)"
  [[ -z "${objs// /}" ]] && objs=0
  dms="$(aws s3api list-object-versions --bucket "$bucket" \
    --query 'length(DeleteMarkers[]) || `0`' --output text 2>/dev/null)"
  # The query prints an EMPTY string, not 0, when the key is absent (length() of a missing key is
  # an error the CLI reports on stderr). Normalise here rather than in the query.
  [[ -z "${dms// /}" ]] && dms=0
  note "$bucket: ${objs} version(s), ${dms} delete marker(s)"
  if [[ "$APPLY" -eq 1 && ( "$objs" != "0" || "$dms" != "0" ) ]]; then
    # One page at a time, because a bucket with an agent's history in it can exceed a single list.
    del_json="$(mktemp)"
    while :; do
      payload="$(aws s3api list-object-versions --bucket "$bucket" --max-items 500 \
        --query '{Objects: (Versions[].{Key:Key,VersionId:VersionId} || `[]`)[0:500]}' --output json 2>/dev/null)"
      count="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("Objects") or []))' 2>/dev/null || echo 0)"
      [[ "$count" == "0" ]] && break
      printf '%s' "$payload" > "$del_json"
      aws s3api delete-objects --bucket "$bucket" --delete "file://$del_json" >/dev/null 2>&1 || break
    done
    while :; do
      payload="$(aws s3api list-object-versions --bucket "$bucket" --max-items 500 \
        --query '{Objects: (DeleteMarkers[].{Key:Key,VersionId:VersionId} || `[]`)[0:500]}' --output json 2>/dev/null)"
      count="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("Objects") or []))' 2>/dev/null || echo 0)"
      [[ "$count" == "0" ]] && break
      printf '%s' "$payload" > "$del_json"
      aws s3api delete-objects --bucket "$bucket" --delete "file://$del_json" >/dev/null 2>&1 || break
    done
    rm -f "$del_json"
    did "emptied $bucket (the bucket itself is terraform's to delete)"
  elif [[ "$objs" == "0" && "$dms" == "0" ]]; then
    # Not "would empty": there is nothing in it, and "would empty" reads as a dry run rather than as
    # a bucket that was already clean.
    did "$bucket is already empty (the bucket itself is terraform's to delete)"
  else
    note "would empty $bucket, leaving the bucket for terraform"
  fi
else
  did "no checkpoint or person-data bucket named ${CLUSTER}-agent-checkpoints* or ${CLUSTER}-person-data*"
fi
done

if [[ "$IN_CLUSTER_ONLY" -eq 1 ]]; then
  printf '\n%ssteps 0-9 done on this host; 10-11 run where --root was invoked%s\n' "$DIM" "$RESET"
  exit 0
fi

# ---------------------------------------------------------------------------
step "10. terraform destroy"
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_DIR/terraform/$PATH_NAME"
if [[ -n "$DESTROY_TFVARS" && "$SWEEP_ONLY" -ne 1 ]]; then
  # The workspace is printed and must be the default: a selected workspace is sticky and invisible
  # in the command line, so a destroy with the right -var-file can target another cluster's state.
  ws="$(terraform -chdir="$TF_DIR" workspace show 2>/dev/null || echo '?')"
  tfname="$(sed -nE 's/^[[:space:]]*name[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$TF_DIR/$DESTROY_TFVARS" 2>/dev/null | head -1)"
  note "root terraform/$PATH_NAME, workspace $ws, var-file $DESTROY_TFVARS (name = ${tfname:-?})"
  if [[ ! -f "$TF_DIR/$DESTROY_TFVARS" ]]; then
    found "no $DESTROY_TFVARS in terraform/$PATH_NAME; not destroying"
  elif [[ "$ws" != default ]]; then
    found "workspace is $ws, not default; select the workspace yourself and run terraform destroy"
  elif [[ "$tfname" != "$CLUSTER" ]]; then
    found "$DESTROY_TFVARS names '$tfname', not --cluster $CLUSTER; not destroying"
  else
    # THE DESTROY'S OWN OUTPUT IS KEPT. Through run() it would be discarded, so a destroy that fails
    # in seconds would print only "failed (continuing)" and the sweep would then report the whole
    # stack as leftovers. On failure the error is printed before the sweep.
    if [[ "$APPLY" -eq 1 ]]; then
      dlog="$(mktemp -t eks-agents-destroy.XXXXXX)"
      # A destroy that failed on the network is run again once AWS answers: its refresh drops what
      # was already deleted, so a re-run carries on from where the drop cut it off.
      drc=1
      for dtry in 1 2 3 4 5; do
        terraform -chdir="$TF_DIR" destroy -var-file="$DESTROY_TFVARS" -parallelism=30 -auto-approve -input=false -no-color -lock-timeout=120s >"$dlog" 2>&1; drc=$?
        (( drc == 0 )) && break
        is_net_error "$(grep -E -A8 '^Error' "$dlog")" || break
        warn "terraform destroy failed on the network (attempt $dtry of 5)"
        wait_for_aws || break
      done
      if (( drc == 0 )); then
        DESTROY_DONE=1
        did "terraform destroy: $(grep -E '^Destroy complete' "$dlog" | tail -1)"
      else
        warn "terraform destroy failed (continuing to the sweep); its error:"
        grep -E -A8 '^Error' "$dlog" | head -40 | sed 's/^/      /'
        note "full output: $dlog -- fix the cause and rerun with --destroy-with, or destroy by hand then --sweep-only"
      fi
    else
      note "would run: terraform -chdir=$TF_DIR destroy -var-file=$DESTROY_TFVARS -parallelism=30 -auto-approve -input=false -no-color"
    fi
    # THE DESTROY DELETES THE RENDERED FILES, and some are tracked as placeholders
    # (gitops/platform/<path>/terraform-values.yaml, collector-values.yaml). Left deleted, the
    # working tree is dirty and the next rebase or commit trips on it.
    if [[ "$APPLY" -eq 1 ]] && git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
      gone="$(git -C "$REPO_DIR" ls-files --deleted -- "gitops/platform/$PATH_NAME" "gitops/bootstrap/$PATH_NAME")"
      if [[ -n "$gone" ]]; then
        git -C "$REPO_DIR" checkout -- $gone && did "restored the placeholder form of: $(echo $gone)"
      fi
    fi
  fi
else
note "run this yourself, from the root you applied, with the same -var-file, or pass --destroy-with:"
note "  cd terraform/$PATH_NAME && terraform workspace show   # CHECK THIS FIRST"
note "  cd terraform/$PATH_NAME && terraform destroy -var-file=<your.tfvars> -parallelism=30"
note "This script does not run it for you: it cannot know which tfvars or workspace you used, and"
note "guessing at a destroy is worse than asking."
note ""
note "CHECK THE WORKSPACE, not just the tfvars. If you used workspaces to hold more than one cluster"
note "in one root, the selected workspace is sticky and invisible in the command line -- so a"
note "destroy with the right -var-file can still target the other cluster's state. \`workspace show\`"
note "is one line and is the only thing that tells you which state you are about to destroy."
note ""
note "-parallelism=30 is worth setting. The default is 10, and a destroy of this stack spends most"
note "of its wall clock on independent resources -- IAM roles, log groups, subnets, access entries."
note "It does not help the two that dominate the tail, the cluster itself and the NAT gateway, and"
note "it changes no ordering: the dependency graph is what serialises a destroy, not the limit."
fi

# ---------------------------------------------------------------------------
step "11. SWEEP: what is still billing"
# ---------------------------------------------------------------------------
# Run this AFTER terraform destroy. Everything it prints is something that outlived the teardown.
# A clean sweep is the only evidence worth reporting.

# BUT A CLEAN SWEEP IS ONLY EVIDENCE IF THE CREDENTIAL COULD SEE. Every check below swallows stderr
# and treats an empty result as "nothing there", so an `AccessDenied` prints a tick. Steps 1-9 need
# kubectl and therefore run on a host inside the VPC -- on the bastion that host's role can reach
# the cluster and almost nothing else, so the whole AWS-side sweep passes without asking anything.
#
# Run on the bastion, an unguarded sweep would report "no Lambda functions that look like gateway
# tool targets" and "X-Ray Transaction Search is not active" while the function, its execution role
# and the account-wide setting are all still there.
#
# So ask once, before reporting anything, whether this credential can read each API family the
# sweep uses. A denial here is a FAILURE of the sweep, not of the teardown: nothing below is
# evidence until it is fixed.
sweep_blind=0
for probe in \
    "ec2:describe-volumes:aws ec2 describe-volumes --region $REGION --max-items 1" \
    "iam:list-roles:aws iam list-roles --max-items 1" \
    "lambda:list-functions:aws lambda list-functions --region $REGION --max-items 1" \
    "acm:list-certificates:aws acm list-certificates --region $REGION --max-items 1" \
    "cognito-idp:list-user-pools:aws cognito-idp list-user-pools --region $REGION --max-results 1" \
    "route53:list-hosted-zones:aws route53 list-hosted-zones --max-items 1" \
    "s3:list-buckets:aws s3api list-buckets" \
    "logs:describe-log-groups:aws logs describe-log-groups --region $REGION --max-items 1" \
    "ecr:describe-repositories:aws ecr describe-repositories --region $REGION --max-items 1" \
    "elasticache:describe-serverless-caches:aws elasticache describe-serverless-caches --region $REGION --max-items 1" \
    "xray:get-trace-segment-destination:aws xray get-trace-segment-destination --region $REGION" \
    "tagging:get-resources:aws resourcegroupstaggingapi get-resources --region $REGION --resources-per-page 1" \
    ; do
  name="${probe%%:*}"; rest="${probe#*:}"; cmd="${rest#*:}"
  if ! err="$($cmd 2>&1 >/dev/null)"; then
    found "the sweep cannot read $name: $(printf '%s' "$err" | tr '\n' ' ' | head -c 140)"
    sweep_blind=1
  fi
done
if [[ "$sweep_blind" -eq 1 ]]; then
  warn "EVERY CLEAN LINE BELOW IS UNVERIFIED. The checks swallow errors, so a denial reads as a"
  warn "tick. Re-run step 11 with a credential that can read the account:"
  warn "  ./scripts/teardown.sh --path $PATH_NAME --cluster $CLUSTER --region $REGION --sweep-only"
  warn "Steps 1-9 need kubectl and so run inside the VPC; the sweep needs account-wide reads. They"
  warn "are not the same credential, and this script needs both."
else
  did "the sweep's credential can read every API family it checks"
fi

v="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null)"
if [[ -n "$v" && "$v" != "None" ]]; then
  # An existing cluster (create_cluster = false) is the reader's own: the destroy leaves it.
  if [[ "${DESTROY_DONE:-0}" -eq 1 ]]; then
    note "cluster $CLUSTER still exists (vpc $v): this stack did not create it, so the destroy kept it"
  else
    warn "cluster $CLUSTER still exists (vpc $v) -- terraform destroy has not run yet"
  fi
  VPC="$v"
else
  did "cluster $CLUSTER is gone"
  VPC=""
fi

# EBS VOLUMES ARE THE HEADLINE RISK, so this is the check to read first. A volume provisioned by
# the CSI driver carries kubernetes.io/created-for/pvc/* tags and usually KubernetesCluster, and it
# survives the cluster in `available` state with nothing left to reclaim it.
#
# Deliberately NOT a pipeline. Piping the query into `while read` and counting from inside it runs
# the counter in a subshell, so every increment is discarded and the summary reports a clean sweep
# while volumes are still billing.
vol_report="$(aws ec2 describe-volumes --region "$REGION" --filters "Name=status,Values=available" --output json 2>/dev/null   | CLUSTER="$CLUSTER" python3 -c '
import json, os, sys
cluster = os.environ.get("CLUSTER", "")
try:
    vols = (json.load(sys.stdin) or {}).get("Volumes") or []
except Exception:
    vols = []
hits = []
for v in vols:
    tags = {t["Key"]: t["Value"] for t in (v.get("Tags") or [])}
    pvc = tags.get("kubernetes.io/created-for/pvc/name")
    ns = tags.get("kubernetes.io/created-for/pvc/namespace")
    # Either tagged for this cluster, or clearly PVC-provisioned and therefore somebody\x27s orphan.
    if tags.get("KubernetesCluster") == cluster or (pvc and cluster and cluster in (tags.get("KubernetesCluster") or cluster)):
        hits.append((v["VolumeId"], v.get("Size", 0), ns, pvc))
if hits:
    print("HITS", len(hits), sum(h[1] for h in hits))
    for vid, gb, ns, pvc in hits:
        print(f"  {vid}  {gb}GiB  pvc={ns}/{pvc}")
' 2>/dev/null)"

if [[ "$vol_report" == HITS* ]]; then
  n="$(printf '%s' "$vol_report" | head -1 | awk '{print $2}')"
  gb="$(printf '%s' "$vol_report" | head -1 | awk '{print $3}')"
  found "$n unattached EBS volume(s), ${gb} GiB total, provisioned by a PVC and still billing"
  printf '%s\n' "$vol_report" | tail -n +2 | while read -r l; do note "$l"; done
  note "delete each one only after confirming its KubernetesCluster tag names the cluster you are"
  note "tearing down:  aws ec2 delete-volume --region $REGION --volume-id <id>"
else
  did "no unattached EBS volumes provisioned by a PVC"
fi

# A VPC is not always one cluster's. Where two clusters share a VPC,
# this check can name a load balancer that belongs to the OTHER cluster. Reported with the VPC id so
# the ambiguity is visible rather than implied.
if [[ -n "$VPC" ]]; then
  lbs="$(aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[?VpcId=='$VPC'].LoadBalancerName" --output text 2>/dev/null | tr '\t' ' ')"
  if [[ -n "${lbs// /}" ]]; then
    found "load balancers still in $VPC: $lbs"
    note "If another cluster shares this VPC, some of these are its. Check each one's tags before"
    note "deleting:  aws elbv2 describe-tags --region $REGION --resource-arns <arn>"
  else
    did "no load balancers in $VPC"
  fi
fi

# ---------------------------------------------------------------------------
# Ingress
# ---------------------------------------------------------------------------
#
# `terraform destroy` owns all three of these. They are swept anyway because a PARTIAL destroy
# leaves them, and one of them then blocks re-creating the cluster at all.
#
# THE COGNITO DOMAIN PREFIX IS GLOBALLY UNIQUE. An orphaned `<cluster>-ingress` domain does not
# merely linger: the next apply for a cluster of the same name fails on it, and the error names a
# domain rather than a teardown. That is the one worth the API call.
pool_ids="$(aws cognito-idp list-user-pools --region "$REGION" --max-results 60   --query "UserPools[?Name=='${CLUSTER}-ingress'].Id" --output text 2>/dev/null | tr '\t' ' ')"
if [[ -n "${pool_ids// /}" ]]; then
  found "Cognito user pools for this cluster's ingress: $pool_ids"
  note "The DOMAIN is the blocking part -- its prefix is globally unique, so a re-apply for a"
  note "cluster of this name fails while it exists. Delete the domain, then the pool:"
  note "  aws cognito-idp delete-user-pool-domain --region $REGION --domain ${CLUSTER}-ingress --user-pool-id <id>"
  note "  aws cognito-idp delete-user-pool --region $REGION --user-pool-id <id>"
else
  did "no Cognito user pool named ${CLUSTER}-ingress"
fi

# A certificate costs nothing and blocks nothing, but an unused one with a private domain on it is a
# reliable sign ingress was not destroyed -- and a GENERATED one (self_signed_certificate)
# has a private key in Terraform state, so leaving it behind leaves that too.
ingress_certs="$(aws acm list-certificates --region "$REGION" --max-items 200   --query "CertificateSummaryList[].CertificateArn" --output text 2>/dev/null | tr '\t' '\n'   | while read -r arn; do
      [[ -z "$arn" ]] && continue
      if aws acm list-tags-for-certificate --region "$REGION" --certificate-arn "$arn"            --query "Tags[?Key=='Name'].Value" --output text 2>/dev/null | grep -q "$CLUSTER"; then
        printf '%s ' "$arn"
      fi
    done)"
if [[ -n "${ingress_certs// /}" ]]; then
  found "ACM certificates tagged for this cluster: $ingress_certs"
  note "A generated ingress certificate also means a private key in Terraform state."
else
  did "no ACM certificate tagged for this cluster"
fi

# The private hosted zone the agents' names resolve in. It is force_destroy, so terraform takes it
# with its records -- which is also why a leftover zone means the destroy did not reach the module.
zones="$(aws route53 list-hosted-zones --max-items 300   --query "HostedZones[?Config.PrivateZone && contains(Comment, '${CLUSTER}')].Id"   --output text 2>/dev/null | tr '\t' ' ')"
if [[ -n "${zones// /}" ]]; then
  found "private hosted zones for this cluster's ingress: $zones"
  note "Records in them are written by external-dns, so deleting the zone needs them gone first:"
  note "  aws route53 delete-hosted-zone --id <id>   (after emptying it)"
else
  did "no private hosted zone commented for this cluster"
fi

# ONLY MEANINGFUL WHILE THE CLUSTER EXISTS, and the ones most often missed, because none of them is
# visible from inside the cluster and none carries the cluster name in a way a name check matches.
if [[ -n "$VPC" ]]; then
  caps="$(aws eks list-capabilities --cluster-name "$CLUSTER" --region "$REGION" \
    --query 'capabilities[].capabilityName' --output text 2>/dev/null)"
  [[ -n "${caps// /}" ]] && found "EKS capabilities still ACTIVE (these bill): $caps" \
                         || did "no EKS capabilities"

  pia="$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER" --region "$REGION" \
    --query 'associations[].join(`/`,[namespace,serviceAccount])' --output text 2>/dev/null)"
  if [[ -n "${pia// /}" ]]; then
    warn "Pod Identity associations still present: $pia"
    note "An association whose namespace no longer exists is dead config, not a charge. Check each"
    note "against the namespaces you expect to keep before deleting it."
  else
    did "no Pod Identity associations"
  fi

  # A capability's access entry OUTLIVES the capability, so it is still here after step 6 and points
  # at a role that step 6 made deletable. Reported, never deleted: the rest of this list is how
  # humans reach the cluster.
  ae="$(aws eks list-access-entries --cluster-name "$CLUSTER" --region "$REGION" \
    --query 'accessEntries' --output text 2>/dev/null | tr '\t' '\n' | grep -E "role/([^/]+/)*${CLUSTER}-" || true)"
  [[ -n "${ae// /}" ]] && found "access entries left by this stack: $(echo "$ae" | tr '\n' ' ')" \
                       || did "no access entries left by this stack"
fi

# An AgentCore Gateway Lambda target is hand-wired, so its function carries no cluster name and no
# name-prefix check could ever see it. Matched on the words that appear in a gateway tool's name,
# which is a guess rather than a scope -- hence a warning, and no deletion.
fn="$(aws lambda list-functions --region "$REGION" \
  --query "Functions[?contains(FunctionName,'mcp')||contains(FunctionName,'agent')].FunctionName" \
  --output text 2>/dev/null | tr '\t' ' ')"
if [[ -n "${fn// /}" ]]; then
  warn "Lambda function(s) whose name suggests a gateway tool target: $fn"
  note "This repository does not create these. If you wired a Lambda target by hand, it and its"
  note "execution role are yours to remove; if the name is a coincidence, ignore this line."
else
  did "no Lambda functions that look like gateway tool targets"
fi

# EITHER PATTERN, not the /eks-agents/ path AND a ${CLUSTER}-agent- name at once. That conjunction
# would hide the gateway role (${CLUSTER}-agentgateway) and the two capability roles
# (${CLUSTER}-capability-*): each matches one half, and the conjunction wants both. Service-linked
# roles are excluded -- AWS owns those and recreates them on demand, so reporting them as leftovers
# is a false positive a reader has to learn to skip.
# '<name>-', not '<name>', and NOT the /eks-agents/ path: a bare prefix reports cluster demo2's
# roles as demo's, and the path -- shared by every cluster's agent roles and boundary -- reports
# another cluster's boundary as this one's.
# Everything this stack names is <name>-<thing>, agent roles included (<name>-agent-<agent>).
roles="$(aws iam list-roles \
  --query "Roles[?!starts_with(Path,'/aws-service-role/')] | [?starts_with(RoleName,'${CLUSTER}-')].RoleName" \
  --output text 2>/dev/null | tr '\t' ' ')"
[[ -n "${roles// /}" ]] && found "IAM roles still present: $roles" || did "no leftover IAM roles"

pol="$(aws iam list-policies --scope Local \
  --query "Policies[?starts_with(PolicyName,'${CLUSTER}-')].PolicyName" \
  --output text 2>/dev/null | tr '\t' ' ')"
[[ -n "${pol// /}" ]] && found "IAM policies still present: $pol" || did "no leftover IAM policies"

step "IAM Identity Center objects, which outlive the cluster and are organization-wide"
# ---------------------------------------------------------------------------
#
# REPORTED, NEVER DELETED, and that asymmetry is deliberate. With argocd_manage_admin_group on,
# Terraform creates an Identity Center GROUP, one USER per entry in argocd_admin_users, and the
# memberships -- so `terraform destroy` removes them and this sweep has nothing to do. The case this
# catches is the one where the destroy did not run or did not finish.
#
# WHY IT MATTERS MORE THAN THE REST OF THIS LIST. An identity-store user is a sign-in identity in
# your ORGANIZATION, not a resource in this cluster's account-and-region. It costs nothing and it
# does not appear on any bill, so nothing else here would ever surface it -- and it outlives the
# cluster it was created for. That is the opposite of the usual leftover: harmless to the invoice,
# and the only thing on this list with a security consequence.
#
# A group and a user are also the two objects most likely to be SHARED. A name-prefix match is not
# proof that this stack created one, and deleting a colleague's sign-in identity because it starts
# with the cluster's name is not a recovery anybody wants. So this prints them.
#
# THE INSTANCE IS FREQUENTLY IN ANOTHER REGION. An organization has at most one, and it is commonly
# in us-east-1 while the cluster is not -- so this looks in the cluster's region and, failing that,
# in us-east-1, and says which it used. --idc-region overrides both.
idc_region="${IDC_REGION:-$REGION}"
idc_arn=""
idc_store=""
for r in "$idc_region" us-east-1; do
  read -r idc_arn idc_store <<<"$(aws sso-admin list-instances --region "$r" \
    --query 'Instances[0].[InstanceArn,IdentityStoreId]' --output text 2>/dev/null)"
  if [[ -n "$idc_arn" && "$idc_arn" != "None" ]]; then idc_region="$r"; break; fi
  idc_arn=""; idc_store=""
done

if [[ -z "$idc_arn" ]]; then
  did "no Identity Center instance in $idc_region or us-east-1: nothing of this kind to leave behind"
elif [[ -z "$idc_store" || "$idc_store" == "None" ]]; then
  warn "an Identity Center instance exists in $idc_region but its identity store could not be read"
  note "Check the group and users by hand if you ran with argocd_manage_admin_group on."
else
  note "Identity Center instance in $idc_region, identity store $idc_store"
  grp="$(aws identitystore list-groups --region "$idc_region" --identity-store-id "$idc_store" \
    --query "Groups[?starts_with(DisplayName,'${CLUSTER}')].[DisplayName,GroupId]" \
    --output text 2>/dev/null)"
  if [[ -n "${grp// /}" ]]; then
    found "Identity Center group(s) named for this cluster still exist"
    printf '%s\n' "$grp" | while read -r name gid; do
      [[ -z "$name" ]] && continue
      note "group $name ($gid)"
      members="$(aws identitystore list-group-memberships --region "$idc_region" \
        --identity-store-id "$idc_store" --group-id "$gid" \
        --query 'GroupMemberships[].MemberId.UserId' --output text 2>/dev/null)"
      for uid in $members; do
        uname="$(aws identitystore describe-user --region "$idc_region" \
          --identity-store-id "$idc_store" --user-id "$uid" \
          --query UserName --output text 2>/dev/null)"
        note "  member $uname ($uid) -- a sign-in identity in your organization"
      done
    done
    note "These are terraform's when argocd_manage_admin_group is on, so the destroy removes them."
    note "Delete by hand only after checking nobody else uses them:"
    note "  aws identitystore delete-group --region $idc_region --identity-store-id $idc_store --group-id <id>"
    note "  aws identitystore delete-user  --region $idc_region --identity-store-id $idc_store --user-id  <id>"
  else
    did "no Identity Center group named for $CLUSTER"
  fi
fi

# ---------------------------------------------------------------------------
step "Platform secrets (Secrets Manager)"
# WHY FORCE. Secrets Manager keeps a deleted secret for its recovery window -- 7 days here, which is
# right for production use and wrong for a teardown: the name stays taken, and the next
# `terraform apply` with the same cluster name fails with "You can't create this secret because a
# secret with this name is already scheduled for deletion". Terraform destroy schedules; this deletes.
#
# What they are: under platform/, generated passwords for valkey, Grafana and Langfuse, which the
# next apply regenerates, so they are always deleted. Under consent/ and agentcore/, the third-party
# credentials and OAuth client secrets the operator stored with scripts/set-credential.sh, which no
# Terraform owns and which are NOT regenerable: deleting them means storing them again before the
# next apply that names them. So those are reported, with the command that deletes each, and
# deleted only with --delete-operator-secrets.
secret_arns="$(aws secretsmanager list-secrets --region "$REGION" \
  --filters Key=name,Values="$CLUSTER/platform/" \
  --query 'SecretList[].ARN' --output text 2>/dev/null)"
secret_arns="$(echo $secret_arns)"
# TERRAFORM'S, WHILE ITS STATE STILL HOLDS THEM. On a cluster you keep, without --destroy-with, the
# state still lists these secrets; deleting them here makes the next apply read them as deleted, and
# its plan guard refuses until --allow-replace. So they stay until a destroy removes them from the
# state, and the next apply reuses them.
tracked=""
if [[ -n "${STACK_ROOT:-}" && -n "$secret_arns" ]]; then
  tracked="$(terraform -chdir="$STACK_ROOT" state list 2>/dev/null | grep -c 'platform_secrets\[0\]\.aws_secretsmanager_secret\.this' || true)"
fi
if [[ -z "$secret_arns" ]]; then
  did "no platform secrets for $CLUSTER"
elif [[ "${tracked:-0}" != "0" ]]; then
  did "kept $(wc -w <<<"$secret_arns" | tr -d ' ') platform secret(s): $STACK_ROOT's state still holds them, so the next apply reuses them (a destroy removes them)"
else
  for arn in $secret_arns; do
    run aws secretsmanager delete-secret --region "$REGION" --secret-id "$arn" \
      --force-delete-without-recovery
  done
fi
operator_arns="$(aws secretsmanager list-secrets --region "$REGION" \
  --filters Key=name,Values="$CLUSTER/consent/" \
  --query 'SecretList[].ARN' --output text 2>/dev/null) $(aws secretsmanager list-secrets --region "$REGION" \
  --filters Key=name,Values="$CLUSTER/agentcore/" \
  --query 'SecretList[].ARN' --output text 2>/dev/null)"
operator_arns="$(echo $operator_arns)"
if [[ -z "$operator_arns" ]]; then
  did "no operator secrets (consent/, agentcore/) for $CLUSTER"
elif [[ "$DELETE_OPERATOR_SECRETS" -eq 1 ]]; then
  for arn in $operator_arns; do
    run aws secretsmanager delete-secret --region "$REGION" --secret-id "$arn" \
      --force-delete-without-recovery
  done
else
  for arn in $operator_arns; do
    warn "operator secret kept (stored with set-credential.sh, not regenerable): $arn"
    note "delete it: aws secretsmanager delete-secret --region $REGION --secret-id $arn --force-delete-without-recovery"
  done
  note "or run this again with --delete-operator-secrets --yes to delete them all"
fi

# Only an orphan once the cluster is gone. While the cluster exists this log group is its own
# control-plane logging and reporting it as a leftover is a false positive -- which is worth getting
# right, because a sweep whose output has to be second-guessed is a sweep nobody reads.
lg="$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "/aws/eks/${CLUSTER}" \
  --query 'logGroups[].logGroupName' --output text 2>/dev/null)"
if [[ -z "${lg// /}" ]]; then
  did "no leftover log groups"
elif [[ -n "$VPC" ]]; then
  did "log group(s) belong to the cluster, which still exists: $lg"
else
  found "CloudWatch log groups outliving the cluster: $lg"
fi

# The GitOps mirror (scripts/gitops-mirror.sh create --name <cluster>). Not the stack's: Terraform did
# not create it and this script does not delete it, but it holds the rendered values for the account.
# A REMINDER, NOT A LEFTOVER: the User Guide has the reader delete it after this script, so
# counting it would fail every teardown that follows the guide.
cc="$(aws codecommit get-repository --region "$REGION" --repository-name "${CLUSTER}-gitops" --query repositoryMetadata.repositoryName --output text 2>/dev/null)"
[[ -n "${cc// /}" && "$cc" != None ]] && warn "CodeCommit mirror still present, holding this account's rendered values: $cc. Delete it when you no longer need it: ./scripts/gitops-mirror.sh delete --name $CLUSTER --region $REGION" \
  || did "no GitOps mirror named ${CLUSTER}-gitops"

# The image builds' log group (enable_image_build). Terraform owns it, so it outlives a stack only
# when the destroy did not finish.
cbl="$(aws logs describe-log-groups --region "$REGION" --log-group-name-prefix "/aws/codebuild/${CLUSTER}-agent-images" \
  --query 'logGroups[].logGroupName' --output text 2>/dev/null | tr '\t' ' ')"
[[ -n "${cbl// /}" ]] && found "image-build log group still present: $cbl" || did "no leftover image-build log group"
cbp="$(aws codebuild batch-get-projects --region "$REGION" --names "${CLUSTER}-agent-images" --query 'projects[].name' --output text 2>/dev/null)"
[[ -n "${cbp// /}" ]] && found "CodeBuild project still present: $cbp" || did "no leftover CodeBuild project"

# The Strands Evals release gate's results (aws-services, enable_evaluations). The runner creates this
# log group on first use, so Terraform does not own it and destroy leaves it. Named for the cluster.
rg="$(aws logs describe-log-groups --region "$REGION" \
  --log-group-name-prefix "/aws/bedrock-agentcore/evaluations/results/${CLUSTER}-release-gate" \
  --query 'logGroups[].logGroupName' --output text 2>/dev/null | tr '\t' ' ')"
if [[ -z "${rg// /}" ]]; then
  did "no release-gate result log group for $CLUSTER"
else
  for g in $rg; do
    run aws logs delete-log-group --region "$REGION" --log-group-name "$g"
  done
fi

# The example's own log groups, which carry no cluster name at all: the tools Lambda's and the one
# AgentCore Evaluations creates per evaluator.
# SCOPED TO THIS CLUSTER. AgentCore names these after the gateway or evaluator, which carries the
# cluster name with hyphens or, for evaluators, underscores. Matching every bedrock-agentcore group
# reports a parallel stack's as this one's leftovers.
olg="$(aws logs describe-log-groups --region "$REGION" \
  --query "logGroups[?contains(logGroupName,'agents-mcp-tools')||(contains(logGroupName,'bedrock-agentcore')&&(contains(logGroupName,'${CLUSTER}')||contains(logGroupName,'${CLUSTER//-/_}')))].logGroupName" \
  --output text 2>/dev/null | tr '\t' ' ')"
# The ones that carry this cluster's name are this stack's beyond doubt -- the online evaluation's
# results group (/aws/bedrock-agentcore/evaluations/results/<name>_agents-<id>) and the per-evaluator
# groups AgentCore creates -- and outlive terraform destroy, so they are deleted like the
# release-gate group above. The tools Lambda's group carries no cluster name, so it is reported only.
# The release-gate group matches this query too; it is handled above, so it is skipped here to keep
# a dry run from listing it twice.
for g in $olg; do
  [[ " $rg " == *" $g "* ]] && continue
  if [[ "$g" == *bedrock-agentcore* ]]; then
    run aws logs delete-log-group --region "$REGION" --log-group-name "$g"
  fi
done
# Deleted ones are not leftovers; in a dry run they still are, so the report says so.
[[ "$APPLY" -eq 1 ]] && olg="$(printf '%s\n' $olg | grep -v bedrock-agentcore | tr '\n' ' ')"
olg="$(for g in $olg; do [[ " $rg " == *" $g "* ]] || printf '%s ' "$g"; done)"
[[ -n "${olg// /}" ]] && found "log groups from the examples: $olg" || did "no leftover example log groups"

ecr="$(aws ecr describe-repositories --region "$REGION" \
  --query "repositories[?starts_with(repositoryName,'${CLUSTER}/')||starts_with(repositoryName,'agents/')].repositoryName" \
  --output text 2>/dev/null | tr '\t' ' ')"
[[ -n "${ecr// /}" ]] && found "ECR repositories still present: $ecr" || did "no leftover ECR repositories"

# Every bucket this stack names for the cluster: the checkpoint bucket (<cluster>-agent-checkpoints-*)
# the bastion's staging bucket (<cluster>-bastion-staging-*), which a <cluster>-agent prefix missed,
# and the image-build source bucket (<cluster>-image-build-*).
buk="$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'${CLUSTER}-agent-') || starts_with(Name,'${CLUSTER}-bastion-') || starts_with(Name,'${CLUSTER}-person-') || starts_with(Name,'${CLUSTER}-image-build-')].Name" --output text 2>/dev/null)"
[[ -n "${buk// /}" ]] && found "S3 buckets still present: $buk" || did "no leftover S3 buckets"

# A task agent's queues (enable_agent_tasks): <cluster>-<agent>-tasks, -tasks-dlq, -results.
sq="$(aws sqs list-queues --region "$REGION" --queue-name-prefix "${CLUSTER}-" --query 'QueueUrls' --output text 2>/dev/null | tr '\t' ' ')"
[[ -n "${sq// /}" && "$sq" != "None" ]] && found "SQS queues still present: $sq" || did "no leftover SQS queues"

# The IAM OIDC provider for the ingress user pool (enable_person_access). Its URL names the pool,
# not the cluster, so it is found by the stack's eks-agents/cluster tag.
oidcp=""
for arn in $(aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output text 2>/dev/null); do
  [[ "$arn" == *cognito-idp* ]] || continue
  t="$(aws iam list-open-id-connect-provider-tags --open-id-connect-provider-arn "$arn" \
    --query "Tags[?Key=='eks-agents/cluster'].Value" --output text 2>/dev/null)"
  [[ "$t" == "$CLUSTER" ]] && oidcp="$oidcp $arn"
done
[[ -n "${oidcp// /}" ]] && found "IAM OIDC provider(s) for the person-access pool still present:$oidcp" \
                        || did "no leftover IAM OIDC provider for a person-access pool"

# The aws-services path provisions managed services that terraform owns -- so a COMPLETED destroy
# removes them. They are checked anyway because a destroy that fails partway leaves them running,
# and its summary says "Error" rather than listing what survived. These are the expensive ones on
# this path.
if [[ "$PATH_NAME" == "aws-services" ]]; then
  cache="$(aws elasticache describe-serverless-caches --region "$REGION" \
    --query "ServerlessCaches[?starts_with(ServerlessCacheName,'${CLUSTER}')].ServerlessCacheName" --output text 2>/dev/null)"
  [[ -n "${cache// /}" ]] && found "ElastiCache serverless cache(s) still present: $cache" \
                          || did "no leftover ElastiCache serverless cache"

  vb="$(aws s3vectors list-vector-buckets --region "$REGION" \
    --query "vectorBuckets[?starts_with(vectorBucketName,'${CLUSTER}')].vectorBucketName" --output text 2>/dev/null)"
  [[ -n "${vb// /}" ]] && found "S3 Vectors bucket(s) still present: $vb" \
                       || did "no leftover S3 Vectors buckets"

  gw="$(aws bedrock-agentcore-control list-gateways --region "$REGION" \
    --query "items[?starts_with(name,'${CLUSTER}')].name" --output text 2>/dev/null)"
  [[ -n "${gw// /}" ]] && found "AgentCore gateway(s) still present: $gw" \
                       || did "no leftover AgentCore gateways"

  mem="$(aws bedrock-agentcore-control list-memories --region "$REGION" \
    --query "memories[?starts_with(name,'${CLUSTER}')].name" --output text 2>/dev/null)"
  [[ -n "${mem// /}" ]] && found "AgentCore memory store(s) still present: $mem" \
                        || did "no leftover AgentCore memory stores"

  dash="$(aws cloudwatch list-dashboards --region "$REGION" \
    --query "DashboardEntries[?starts_with(DashboardName,'${CLUSTER}')].DashboardName" --output text 2>/dev/null)"
  [[ -n "${dash// /}" ]] && found "CloudWatch dashboard(s) still present: $dash" \
                         || did "no leftover CloudWatch dashboards"

  # Only this stack's engine: modules/egress-agentcore names it <name>_agents with every `-` turned
  # into `_` (policy engine names take no hyphen). Another stack's engine is not a leftover of this one.
  pe="$(aws bedrock-agentcore-control list-policy-engines --region "$REGION" \
    --query "policyEngines[?name=='${CLUSTER//-/_}_agents'].name" --output text 2>/dev/null | tr '\t' ' ')"
  [[ -n "${pe// /}" ]] && found "AgentCore policy engine(s) still present: $pe" \
                       || did "no leftover AgentCore policy engines"

  # ACCOUNT-SCOPED, AND TERRAFORM DOES NOT PUT IT BACK.
  #
  # `aws_xray_trace_segment_destination` is in the observability module, so `terraform destroy`
  # removes it from STATE -- and the account setting stays `CloudWatchLogs / ACTIVE`: after a full
  # destroy the resource is gone from state and `get-trace-segment-destination` still reports
  # ACTIVE. That is worse than not owning it, because state says it was reverted.
  #
  # So this reverts it, with care, because the setting is
  # ACCOUNT-WIDE, so another cluster of this stack in the same account loses its GenAI observability
  # views the moment it flips. The check below is what makes reverting safe -- it looks for any OTHER
  # cluster carrying this stack's tag, and refuses rather than guessing.
  ts="$(aws xray get-trace-segment-destination --region "$REGION" --query 'Status' --output text 2>/dev/null)"
  if [[ "$ts" == "ACTIVE" ]]; then
    # Other clusters of this stack, by tag rather than by name: a stack applied with `name` set to
    # something other than its cluster is invisible to a name match, which is the mistake the tag
    # scan further down exists to catch.
    tagged="$(aws resourcegroupstaggingapi get-resources --region "$REGION"       --tag-filters "Key=app.kubernetes.io/part-of,Values=eks-agents-paved-paths"       --query 'ResourceTagMappingList[].Tags[?Key==`eks-agents/cluster`].Value' --output text 2>/dev/null       | tr '\t' '\n' | sort -u | grep -v "^${CLUSTER}$" | grep -v '^$')"

    # CONFIRM EACH ONE EXISTS. The tagging index lags deletions -- it can name clusters that are
    # already destroyed, and trusting it would leave the account setting on. This is the same trap the tag scan
    # below warns about, so this does what that warning says: describe before believing.
    others=""
    while read -r c; do
      [[ -z "$c" ]] && continue
      if aws eks describe-cluster --name "$c" --region "$REGION" \
           --query 'cluster.name' --output text >/dev/null 2>&1; then
        others+="$c "
      else
        note "tag index still names $c, which no longer exists; ignoring it"
      fi
    done <<< "$tagged"

    if [[ -n "${others// /}" ]]; then
      warn "X-Ray Transaction Search left ACTIVE: another cluster of this stack is in this account"
      note "clusters still tagged here: ${others}"
      note "It is an ACCOUNT setting, so turning it off would take their GenAI observability views"
      note "with it. Turn it off once the last one is gone:"
      note "  aws xray update-trace-segment-destination --region $REGION --destination XRay"
    elif [[ "$REVERT_ACCOUNT" -eq 1 ]]; then
      if aws xray update-trace-segment-destination --region "$REGION" --destination XRay >/dev/null 2>&1; then
        # The call returns `Destination: XRay, Status: PENDING` and stays PENDING for a while, so a
        # re-read straight after looks like it did not take. Report what was asked for, and let the
        # next sweep report the settled value rather than claiming one now.
        did "asked X-Ray to revert to the X-Ray default (account-wide); it settles asynchronously"
        note "terraform destroy does not do this: it drops aws_xray_trace_segment_destination from"
        note "state and leaves the account setting on."
      else
        warn "could not revert X-Ray Transaction Search; it is still ACTIVE"
      fi
    else
      warn "X-Ray Transaction Search is ACTIVE and no other cluster of this stack is in this account"
      note "terraform destroy does NOT revert it: it removes aws_xray_trace_segment_destination"
      note "from state and leaves the account setting on. Re-run with --revert-account-settings,"
      note "or do it by hand:"
      note "  aws xray update-trace-segment-destination --region $REGION --destination XRay"
    fi
  else
    did "X-Ray Transaction Search is not active"
  fi
fi

# ---------------------------------------------------------------------------
# TAG SCAN: the check that catches what every name check above misses.
# ---------------------------------------------------------------------------
# Everything above matches on a NAME. A stack applied with `name` set to something other than the
# cluster's own name, or a resource terraform names for an example, is invisible to all of it --
# so a full stack can sit on a cluster after a name-based sweep reports clean. Terraform tags
# everything it creates, so the tag is the scope the name cannot express.
#
# Printed as a warning, never deleted: this query reaches resources in the account that this script
# has no business removing, and a tag match alone is not proof of ownership.
#
# Filtered on eks-agents/cluster, which the roots set from var.name. The part-of tag below is the
# account-wide view, across every cluster of this stack.
#
# BOTH SPELLINGS, and the second one is not redundant. EC2 rejects a tag key containing `/`:
#
#   InvalidParameterValue: 'eks-agents/path' is not a valid tag key. Tag keys must match pattern
#   ([0-9a-zA-Z\-_+=,.@:]{1,255})
#
# so the bastion instance and its security group carry `eks-agents.cluster` instead, while every IAM
# and EKS resource carries the slashed form. A sweep that queried only `eks-agents/cluster` would
# report nothing left while an instance and a security group were still running.
tagged=""
for key in "eks-agents/cluster" "eks-agents.cluster"; do
  hits="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
    --tag-filters "Key=${key},Values=$CLUSTER" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null | tr '\t' '\n')"
  [[ -n "${hits// /}" ]] && tagged="${tagged}${hits}"$'\n'
done
tagged="$(printf '%s' "$tagged" | grep -c . >/dev/null 2>&1 && printf '%s' "$tagged" | sort -u || true)"
# CONFIRM EACH ARN BEFORE COUNTING IT. The tagging index lags deletions by minutes, so straight after
# a destroy it lists VPC endpoints, NAT gateways, subnets and security groups that answer
# NotFound to a describe. A type this
# can describe is checked and dropped when it is gone; a type it cannot is kept, as a lead.
still_exists() {
  local a="$1" id="${1##*/}" out
  case "$a" in
    *:ec2:*:subnet/*)         out="$(aws ec2 describe-subnets --region "$REGION" --subnet-ids "$id" --query 'Subnets[0].SubnetId' --output text 2>&1)" ;;
    *:ec2:*:security-group/*) out="$(aws ec2 describe-security-groups --region "$REGION" --group-ids "$id" --query 'SecurityGroups[0].GroupId' --output text 2>&1)" ;;
    *:ec2:*:vpc-endpoint/*)   out="$(aws ec2 describe-vpc-endpoints --region "$REGION" --vpc-endpoint-ids "$id" --query 'VpcEndpoints[0].State' --output text 2>&1)" ;;
    *:ec2:*:vpc/*)            out="$(aws ec2 describe-vpcs --region "$REGION" --vpc-ids "$id" --query 'Vpcs[0].VpcId' --output text 2>&1)" ;;
    *:ec2:*:natgateway/*)     out="$(aws ec2 describe-nat-gateways --region "$REGION" --nat-gateway-ids "$id" --query 'NatGateways[0].State' --output text 2>&1)"
                              [[ "$out" == deleted || "$out" == deleting ]] && return 1 ;;
    *:ec2:*:network-interface/*) out="$(aws ec2 describe-network-interfaces --region "$REGION" --network-interface-ids "$id" --query 'NetworkInterfaces[0].Status' --output text 2>&1)" ;;
    *:ec2:*:instance/*)       out="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$id" --query 'Reservations[0].Instances[0].State.Name' --output text 2>&1)"
                              [[ "$out" == terminated || "$out" == shutting-down ]] && return 1 ;;
    *:ec2:*:volume/*)         out="$(aws ec2 describe-volumes --region "$REGION" --volume-ids "$id" --query 'Volumes[0].State' --output text 2>&1)" ;;
    *:ec2:*:security-group-rule/*) out="$(aws ec2 describe-security-group-rules --region "$REGION" --security-group-rule-ids "$id" --query 'SecurityGroupRules[0].GroupId' --output text 2>&1)" ;;
    # The ingress pool. Destroyed by terraform, it stays in the tagging index, and kept as a lead
    # undescribed it would be the sweep's only finding.
    *:cognito-idp:*:userpool/*) out="$(aws cognito-idp describe-user-pool --region "$REGION" --user-pool-id "$id" --query 'UserPool.Id' --output text 2>&1)" ;;
    # Platform secrets. terraform destroy schedules them for deletion (a recovery window), and the
    # index keeps listing them, so straight after a --destroy-with run they would be the sweep's
    # only findings. Scheduled for deletion is gone; the Platform secrets step reports them.
    *:secretsmanager:*:secret:*) out="$(aws secretsmanager describe-secret --region "$REGION" --secret-id "$a" --query 'DeletedDate' --output text 2>&1)"
                              [[ "$out" == *ResourceNotFound* ]] && return 1
                              [[ "$out" != None && -n "$out" && "$out" != *rror* ]] && return 1 ;;
    # The identity-changes topic's key (identity_change_alerts). terraform destroy schedules it for
    # deletion after a waiting period, and the index keeps listing it: scheduled is gone.
    *:kms:*:key/*)            out="$(aws kms describe-key --region "$REGION" --key-id "$id" --query 'KeyMetadata.KeyState' --output text 2>&1)"
                              [[ "$out" == PendingDeletion || "$out" == *NotFound* ]] && return 1 ;;
    *) return 0 ;;
  esac
  [[ "$out" != *NotFound* && "$out" != *"does not exist"* && "$out" != None ]]
}
if [[ -n "${tagged// /}" ]]; then
  live=""; lagging=0
  while read -r a; do
    [[ -z "$a" ]] && continue
    if still_exists "$a"; then live="${live}${a}"$'\n'; else lagging=$((lagging + 1)); fi
  done <<<"$tagged"
  if [[ -n "${live// /}" ]]; then
    found "$(printf '%s' "$live" | grep -c .) resource(s) still tagged eks-agents/cluster or eks-agents.cluster = $CLUSTER"
    printf '%s' "$live" | while read -r a; do [[ -n "$a" ]] && note "$a"; done
  else
    did "nothing left tagged eks-agents/cluster or eks-agents.cluster = $CLUSTER"
  fi
  [[ "$lagging" -gt 0 ]] && note "$lagging more tagged ARN(s) are already deleted; the tagging index has not caught up."
else
  did "nothing left tagged eks-agents/cluster or eks-agents.cluster = $CLUSTER"
fi

# The wider net, the account-wide view. This matches EVERY cluster
# of this stack in the account, so it is informational only and is not counted as a leftover.
#
# AND THE TAGGING INDEX LAGS DELETIONS, which is the thing to know before chasing anything it
# prints. This query can return a VPC endpoint and pod ARNs from a deleted cluster, every one of
# them already gone, the endpoint answering DescribeVpcEndpoints with InvalidVpcEndpointId.NotFound.
# So an ARN here is a lead, not a leftover. Confirm each with a describe before deleting anything,
# and expect pod ARNs from dead clusters.
allstack="$(aws resourcegroupstaggingapi get-resources --region "$REGION" \
  --tag-filters "Key=app.kubernetes.io/part-of,Values=eks-agents-paved-paths" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null | tr '\t' '\n' | grep -c . || true)"
if [[ "${allstack:-0}" != "0" ]]; then
  warn "$allstack resource(s) in $REGION carry this stack's part-of tag, across all clusters"
  note "NOT necessarily live: this index lags deletions, so confirm each with a describe first."
  note "It also spans every cluster of this stack in the account, so scope it yourself:"
  note "  aws resourcegroupstaggingapi get-resources --region $REGION \\"
  note "    --tag-filters Key=app.kubernetes.io/part-of,Values=eks-agents-paved-paths"
fi

printf '\n'
if [[ -e "$NET_FLAG" ]]; then
  printf '%sThe network to AWS dropped during this run.%s Every call that failed on it waited and ran again,\n' "$YELLOW" "$RESET"
  printf 'so the result above stands; if the drop outlasted a wait, run the teardown again.\n'
  rm -f "$NET_FLAG"
fi
if [[ "$leftovers" -eq 0 ]]; then
  printf '%sSweep clean: nothing found for %s.%s\n' "$GREEN" "$CLUSTER" "$RESET"
else
  printf '%s%d class(es) of resource still exist.%s Each line above is something this teardown did\n' "$RED" "$leftovers" "$RESET"
  printf 'not remove. Most carry a monthly charge -- EBS volumes and load balancers especially. An IAM\n'
  printf 'policy or an empty bucket does not, so read the list rather than the count.\n'
fi
[[ "$APPLY" -eq 0 ]] && printf '%sThis was a DRY RUN.%s\n' "$YELLOW" "$RESET"
# A KEPT CLUSTER, NO DESTROY. The state still lists what this run removed outside Terraform -- the EKS
# Capabilities and the ECR repositories among them -- so the next apply reads them as deleted, and its
# plan guard refuses until told the deletions are intended.
if [[ "$APPLY" -eq 1 && "$GOING_AWAY" -eq 0 && -z "${DESTROY_TFVARS:-}" && -n "${STACK_ROOT:-}" ]]; then
  printf '\nThe cluster is kept. To install the platform on it again, apply with --allow-replace, because\n'
  printf 'this run removed resources that %s still lists:\n' "$STACK_ROOT"
  printf '  ./scripts/apply.sh --root %s -var-file=<your variables file> --allow-replace\n' "$STACK_ROOT"
  printf 'The ECR repositories were deleted with their images, so build the images again before you\n'
  printf 'bootstrap and apply your agents:\n'
  printf '  ./scripts/build-images.sh --root %s\n' "$STACK_ROOT"
  printf '  ./scripts/bootstrap-gitops.sh --path <your path> --sync\n'
fi
_step_close
if [[ ${#STEP_TIMES[@]} -gt 0 ]]; then
  printf '\n%sSlowest steps:%s\n' "$DIM" "$RESET"
  printf '%s\n' "${STEP_TIMES[@]}" | sort -t'|' -k1,1nr | head -5 \
    | while IFS='|' read -r d n; do printf '  %4dm%02ds  %s\n' $((d / 60)) $((d % 60)) "$n"; done
fi
exit "$leftovers"
