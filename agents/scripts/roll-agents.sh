#!/usr/bin/env bash
#
# Recreate each agent's pod whose Sandbox has changed since the pod started.
#
#   ./scripts/roll-agents.sh                  # every Agent on the default runtime, in every namespace
#   ./scripts/roll-agents.sh research         # only these agents (in any namespace)
#   ./scripts/bootstrap-gitops.sh --path aws-services --sync --roll-agents   # after a sync
#
# Run it where kubectl reaches the cluster: on a private-endpoint cluster, the bastion.
#
# WHY THIS EXISTS. On the default runtime an Agent composes a Sandbox, and the Agent Sandbox
# controller does not replace a running pod when the Sandbox's pod template changes. So every layer
# that hands agents something new -- the gateway's endpoints, the collector's, the session cache's,
# the memory ids, an MCP token, a new image -- reaches the pod only when the pod is next created.
# Following the User Guide layer by layer, that means recreating a pod by hand after almost every
# layer. An agent with `runtime: deployment` rolls on its own and is left alone here.
#
# WHAT "CHANGED" MEANS. The Sandbox's pod template is compared with the running pod: each
# container's image, every env var the template sets by value, the volumes it names, and whether it
# mounts the service account token. Only what the TEMPLATE says is compared, because admission adds
# to the pod (EKS Pod Identity injects AWS_* variables and a token volume), and a pod that has more
# than its template is not stale.
#
# WAIT FOR THE SANDBOX TO SETTLE FIRST. kro updates the Sandbox in more than one pass after an Agent
# or values change; a pod recreated between passes starts with the half-updated spec. The Sandboxes
# are taken as settled once none of their resourceVersions has moved for SETTLE seconds (default 20).

set -euo pipefail
# shellcheck source=lib/unstick.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/unstick.sh"
trap unstick_release EXIT
SETTLE="${SETTLE:-20}"
WAIT="${WAIT:-300}"
ONLY=("$@")

agents="$(kubectl get agents.agents.eks.amazonaws.com -A -o json | python3 -c '
import json, sys
for a in json.load(sys.stdin)["items"]:
    if (a.get("spec") or {}).get("runtime", "sandbox") != "deployment":
        print(a["metadata"]["namespace"], a["metadata"]["name"])')"
[[ -n "$agents" ]] || { echo "no Agent on the default runtime"; exit 0; }

stale_reason() {  # namespace name -> prints a reason when the running pod is behind its Sandbox
  local ns="$1" name="$2" sb pod
  sb="$(kubectl -n "$ns" get sandbox "$name" -o json 2>/dev/null)" || { echo "no Sandbox yet"; return; }
  pod="$(kubectl -n "$ns" get pods -l "eks-agents/agent=$name" -o json | python3 -c '
import json, sys
items = [p for p in json.load(sys.stdin)["items"] if not p["metadata"].get("deletionTimestamp")]
print(json.dumps(items[0]) if items else "")')"
  [[ -n "$pod" ]] || { echo "no pod"; return; }
  SB="$sb" POD="$pod" python3 - <<'PY'
import json, os
INJECTED_ENV = {"AWS_CONTAINER_CREDENTIALS_FULL_URI", "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE",
                "AWS_STS_REGIONAL_ENDPOINTS", "AWS_DEFAULT_REGION", "AWS_REGION", "AWS_ROLE_ARN",
                "AWS_WEB_IDENTITY_TOKEN_FILE"}
INJECTED_VOLUMES = {"eks-pod-identity-token", "aws-iam-token"}
t = json.loads(os.environ["SB"])["spec"]["podTemplate"]["spec"]
p = json.loads(os.environ["POD"])["spec"]
why = []
pc = {c["name"]: c for c in p.get("containers", [])}
for c in t.get("containers", []):
    live = pc.get(c["name"])
    if live is None:
        why.append(f"container {c['name']} missing"); continue
    if c.get("image") != live.get("image"):
        why.append(f"{c['name']} image {live.get('image', '').rsplit('/', 1)[-1]} -> {c.get('image', '').rsplit('/', 1)[-1]}")
    # An empty value is stored without a `value` key, so "" and absent compare equal.
    lenv = {e["name"]: e.get("value") or "" for e in live.get("env", []) or [] if "valueFrom" not in e}
    for e in c.get("env", []) or []:
        if "valueFrom" in e:
            continue
        want = e.get("value") or ""
        if e["name"] not in lenv:
            if want:
                why.append(f"env {e['name']} added")
        elif lenv[e["name"]] != want:
            why.append(f"env {e['name']} changed")
    # A VARIABLE THE POD HAS AND THE SANDBOX DOESN'T SET is as stale as one the Sandbox added: turning a component off
    # removes its variables, and a pod that keeps them still acts on them. Admission adds a few of
    # its own (EKS Pod Identity, the SDK's Region), which no Sandbox sets, so those don't count.
    tnames = {e["name"] for e in c.get("env", []) or []}
    for name in sorted(n for n, v in lenv.items() if v and n not in tnames and n not in INJECTED_ENV):
        why.append(f"env {name} removed")
tv = {v["name"] for v in t.get("volumes", []) or []}
pv = {v["name"] for v in p.get("volumes", []) or []}
for v in sorted(tv - pv):
    why.append(f"volume {v} added")
for v in sorted(pv - tv):
    if v not in INJECTED_VOLUMES and not v.startswith("kube-api-access-"):
        why.append(f"volume {v} removed")
if t.get("automountServiceAccountToken") is not None and t["automountServiceAccountToken"] != p.get("automountServiceAccountToken"):
    why.append("service account token mount changed")
print("; ".join(why[:4]) + (f" (+{len(why) - 4} more)" if len(why) > 4 else ""))
PY
}

# ONE WAIT FOR EVERY SANDBOX, NOT ONE PER AGENT. Settling each agent in turn costs at least SETTLE
# seconds per agent, so a roll that recreates nothing would grow with the number of agents. kro updates every agent's Sandbox from the same sync,
# so they settle together: watch all their resourceVersions at once until none has moved for SETTLE
# seconds, up to 180 s. An agent with runtime: tasks has no Sandbox and adds nothing to wait for.
settle_all() {
  local last="" now quiet=0 waited=0
  while (( quiet < SETTLE && waited < 180 )); do
    now="$(kubectl get sandboxes.agents.x-k8s.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}={.metadata.resourceVersion} {end}' 2>/dev/null || true)"
    if [[ "$now" == "$last" ]]; then quiet=$((quiet + 5)); else quiet=0; fi
    last="$now"; sleep 5; waited=$((waited + 5))
  done
}

settle_all
# RECREATE THE STALE PODS TOGETHER, NOT ONE AFTER ANOTHER. One at a time, each agent waits for its
# old pod's graceful deletion and its new pod's start before the next begins. The Sandbox controller
# recreates each pod independently, so delete every stale one first and then wait for them together.
# Waiting for them together, each further agent adds little to the total.
rolled=0 current=0 failed=0 stale=()
while read -r ns name; do
  if [[ ${#ONLY[@]} -gt 0 ]] && ! printf '%s\n' "${ONLY[@]}" | grep -qx "$name"; then continue; fi
  reason="$(stale_reason "$ns" "$name")"
  if [[ -z "$reason" ]]; then
    echo "  $ns/$name: current"; current=$((current + 1)); continue
  fi
  if [[ "$reason" == "no Sandbox yet" ]]; then echo "  $ns/$name: $reason, skipped"; continue; fi
  echo "  $ns/$name: recreating ($reason)"
  [[ "$reason" == "no pod" ]] || kubectl -n "$ns" delete pod -l "eks-agents/agent=$name" --wait=false >/dev/null
  stale+=("$ns/$name")
done <<<"$agents"
t=$(date +%s)
pending=(${stale[@]+"${stale[@]}"})
while (( ${#pending[@]} > 0 && $(date +%s) - t < WAIT )); do
  left=()
  for a in "${pending[@]}"; do
    ns="${a%/*}" name="${a#*/}"
    # Ready, and not the old pod on its way out: the old one is Ready until it is gone.
    if [[ "$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.metadata.deletionTimestamp}|{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == "|True" ]]; then
      echo "  $a: Ready after $(( $(date +%s) - t ))s"; rolled=$((rolled + 1))
    else
      left+=("$a")
    fi
  done
  pending=(${left[@]+"${left[@]}"})
  (( ${#pending[@]} > 0 )) && { unstick_tick; sleep 3; }
done
# ONE AGENT THAT DOES NOT COME UP DOES NOT STOP THE REST: an example agent on the gateway image
# crash-loops after the gateway is turned off, and without this would leave every later agent
# unrolled. It is reported, with the reason, and counted in the exit status.
for a in ${pending[@]+"${pending[@]}"}; do
  ns="${a%/*}" name="${a#*/}"
  why="$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)"
  echo "  $a: NOT Ready after $(( $(date +%s) - t ))s${why:+ ($why)}; see kubectl -n $ns logs $name"
  failed=$((failed + 1))
done
echo "agents recreated: $rolled, already current: $current$( [ "$failed" -gt 0 ] && echo ", not Ready: $failed")"
exit "$failed"
