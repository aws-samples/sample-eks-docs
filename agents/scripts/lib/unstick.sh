# shellcheck shell=bash
#
# Get pods past the EKS Auto Mode sandbox scheduling gap while a script waits for them.
#
#   source "$ROOT/scripts/lib/unstick.sh"
#   trap unstick_release EXIT
#   while waiting; do ...; unstick_tick; sleep 10; done
#
# THE GAP. On a node that holds sandboxed pods, the scheduler counts more memory against the node
# than its pods' requests plus RuntimeClass overhead. Auto Mode's provisioner counts the specs, sees
# room, nominates that node, and launches nothing, so the next pod sits Pending on "Insufficient
# memory" for minutes, in any layer: the ADOT collector, the MCP server, an example's test caller,
# the release gate or the chat UI. scripts/lib/check_sandbox_placement.py keeps sandboxed pods on
# the agents' own pool, off the general-purpose nodes; this handles a pod still caught. The
# RuntimeClass belongs to EKS, so the gap cannot be closed here.
#
# THE WORKAROUND, which exercise.sh's own probes also use: cordon the node Auto Mode keeps
# nominating. The provisioner then places the pod elsewhere and launches a node if it must. A cordon
# evicts nothing; it only stops new pods landing there, and each node is uncordoned as soon as no
# stuck pod is nominated to it, and in any case by unstick_release. Only a pod Pending for
# UNSTICK_AFTER seconds (default 120) on "Insufficient memory" with a Nominated event is acted on.
# UNSTICK=0 turns it off.

UNSTICK_AFTER="${UNSTICK_AFTER:-120}"
#
# PORTABLE TO bash 3.2 AND BSD date, because with cluster_endpoint_public_access these scripts run
# on a workstation as well as the bastion, and macOS ships bash 3.2: an associative array
# (declare -A) and GNU `date -d` both fail there, and would stop bootstrap-gitops.sh at its first
# tick. The state is one "node pod pod..." line per cordoned node.
_UNSTICK_STATE=""

_unstick_note() { printf '      %s\n' "$1" >&2; }

# Seconds since the epoch for an RFC 3339 UTC timestamp, with GNU or BSD date.
_unstick_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || echo 0
}
_unstick_pods_for() { printf '%s\n' "$_UNSTICK_STATE" | awk -v n="$1" '$1==n {$1=""; sub(/^ /,""); print; exit}'; }
_unstick_has() { printf '%s\n' "$_UNSTICK_STATE" | awk -v n="$1" '$1==n {f=1} END {exit !f}'; }
_unstick_set() { # node, pods
  _UNSTICK_STATE="$(printf '%s\n' "$_UNSTICK_STATE" | awk -v n="$1" '$1!=n && NF')"
  _UNSTICK_STATE="$(printf '%s\n%s %s' "$_UNSTICK_STATE" "$1" "$2" | awk 'NF')"
}
_unstick_del() { _UNSTICK_STATE="$(printf '%s\n' "$_UNSTICK_STATE" | awk -v n="$1" '$1!=n && NF')"; }
_unstick_nodes() { printf '%s\n' "$_UNSTICK_STATE" | awk 'NF {print $1}'; }

unstick_tick() {
  [[ "${UNSTICK:-1}" == 0 ]] && return 0
  local now ns pod created bound age ev node cur pending=" "
  now="$(date +%s)"
  while IFS='|' read -r ns pod created bound; do
    [[ -n "$pod" && -z "$bound" ]] || continue
    pending="$pending$ns/$pod "
    age=$(( now - $(_unstick_epoch "$created") ))
    (( age >= UNSTICK_AFTER )) || continue
    ev="$(kubectl -n "$ns" get events --field-selector "involvedObject.name=$pod" \
           -o jsonpath='{range .items[*]}{.reason}|{.message}{"\n"}{end}' 2>/dev/null)"
    printf '%s' "$ev" | grep -q 'Insufficient memory' || continue
    node="$(printf '%s\n' "$ev" | grep '^Nominated|' | tail -1 | grep -o 'node/[^ ,]*' | cut -d/ -f2)"
    [[ -n "$node" ]] || continue
    if ! _unstick_has "$node"; then
      _unstick_note "$ns/$pod Pending ${age}s: Auto Mode nominates $node and the scheduler refuses it for memory; cordoning $node"
      kubectl cordon "$node" >/dev/null 2>&1 || continue
      _unstick_set "$node" ""
    fi
    cur="$(_unstick_pods_for "$node")"
    [[ " $cur " == *" $ns/$pod "* ]] || _unstick_set "$node" "$cur $ns/$pod"
  done < <(kubectl get pods -A --field-selector status.phase=Pending \
             -o jsonpath='{range .items[*]}{.metadata.namespace}|{.metadata.name}|{.metadata.creationTimestamp}|{.spec.nodeName}{"\n"}{end}' 2>/dev/null)
  local n p still
  for n in $(_unstick_nodes); do
    still=""
    for p in $(_unstick_pods_for "$n"); do [[ "$pending" == *" $p "* ]] && still="$still $p"; done
    if [[ -z "$still" ]]; then
      kubectl uncordon "$n" >/dev/null 2>&1; _unstick_note "uncordoned $n: the pods it was cordoned for are scheduled"
      _unstick_del "$n"
    else
      _unstick_set "$n" "$still"
    fi
  done
}

unstick_release() {
  local n
  for n in $(_unstick_nodes); do kubectl uncordon "$n" >/dev/null 2>&1; _unstick_note "uncordoned $n"; done
  _UNSTICK_STATE=""
}
