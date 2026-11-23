#!/usr/bin/env bash
#
# Hand the cluster to Argo CD: the three bootstrap objects, in order, and optionally the first sync.
#
#   ./scripts/bootstrap-gitops.sh --path aws-services            # apply the three objects
#   ./scripts/bootstrap-gitops.sh --path aws-services --sync     # ...and run the root's first sync
#   ./scripts/bootstrap-gitops.sh --path aws-services --sync --roll-agents   # ...then recreate stale agent pods
#   ./scripts/bootstrap-gitops.sh --path aws-services --sync --prune         # ...and delete components turned off
#   ./scripts/run-stack.sh --root terraform/aws-services -- ./scripts/bootstrap-gitops.sh --path aws-services --sync
#
# Run it where kubectl reaches the cluster: on a private-endpoint cluster, the bastion.
#
# WHAT IT AUTOMATES. gitops/bootstrap/<path>/README.md: cluster-secret, appproject, root-app, in that
# order, using the *.local.yaml files `terraform apply` rendered when they exist (the placeholders
# otherwise, which the script refuses to apply with REPO_URL still in them). The root Application is
# created with no automated sync on purpose; --sync is the explicit "I have looked, go": it starts
# one sync of the root, then waits until every Application is Synced and Healthy (or 20 minutes),
# printing the ones that are not and the message Argo CD gives for each.
#
# TURNING A COMPONENT OFF. Its variable adds its file to the root's exclude glob, but the root syncs
# with prune off, so the child Application it excluded -- and everything that child installed --
# keeps running: ingress_idp = cognito leaves the Secrets Store CSI driver's DaemonSets on every
# node after its file is excluded. Without --prune the script names each
# Application the root would prune; --prune deletes them, and their finalizers delete what they
# installed. Off by default, because a wrong exclude glob would otherwise remove a component.
set -euo pipefail

# A MOMENT'S REFUSAL IS RETRIED. The API server can answer 429 (TooManyRequests, "etcdserver:
# throttle") or drop a connection for a few seconds, most often right after a burst of creates such
# as this script's own. Under set -e one such answer ended the bootstrap with nothing wrong, so every
# kubectl call here, and in the libraries sourced below, is tried up to five times when its error is
# only that. Any other error is reported at once, as before.
kubectl() {
  local err rc i
  err="$(mktemp)"
  for i in 1 2 3 4 5; do
    if command kubectl "$@" 2>"$err"; then rc=0; else rc=$?; fi
    if (( rc != 0 && i < 5 )) && grep -qiE 'TooManyRequests|too many requests|etcdserver: (throttle|request timed out|leader changed)|connection reset by peer|TLS handshake timeout|i/o timeout|the server is currently unable to handle' "$err"; then
      sleep $(( i * 3 )); continue
    fi
    cat "$err" >&2; rm -f "$err"; return "$rc"
  done
}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH_NAME="" SYNC=0 ROLL=0 PRUNE=false WAIT="${WAIT:-1200}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) PATH_NAME="$2"; shift 2 ;;
    --sync) SYNC=1; shift ;;
    --roll-agents) ROLL=1; shift ;;
    --prune) PRUNE=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$PATH_NAME" =~ ^(open-source|aws-services)$ ]] || { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
B="$ROOT/gitops/bootstrap/$PATH_NAME"
pick() { [[ -f "$B/$1.local.yaml" ]] && echo "$B/$1.local.yaml" || echo "$B/$1.yaml"; }

kubectl get ns argocd >/dev/null 2>&1 || { echo "no argocd namespace: is the ARGOCD capability ACTIVE?" >&2; exit 2; }

# The root Application, with the account's values folded in (scripts/lib/root-app.sh): Git carries
# the platform, this object carries everything specific to the stack.
REPO_ROOT="$ROOT"
# shellcheck source=lib/root-app.sh
source "$ROOT/scripts/lib/root-app.sh"
WORKDIR="$(mktemp -d)"; trap 'rm -rf "$WORKDIR"' EXIT

for f in "$(pick cluster-secret)" "$(pick appproject)" "$(root_app "$PATH_NAME" "$WORKDIR")"; do
  if grep -q 'REPO_URL\|REPO_REVISION\|PLATFORM_EXCLUDED\|REPLACE' "$f"; then
    echo "$f still carries a placeholder (REPO_URL, REPO_REVISION, PLATFORM_EXCLUDED or REPLACE): run terraform apply first" >&2; exit 2
  fi
  # An empty repoURL is the same failure without the placeholder: gitops_repo_url was empty at apply.
  if grep -qE '^[[:space:]]*repoURL:[[:space:]]*("")?[[:space:]]*$' "$f"; then
    echo "$f has an empty repoURL: set gitops_repo_url and apply again" >&2; exit 2
  fi
  kubectl apply -f "$f"
done
[[ "$SYNC" -eq 1 ]] || { echo "applied; the root Application waits for its first sync (rerun with --sync)"; exit 0; }

# Pods the Auto Mode sandbox scheduling gap leaves Pending would hold their Application at
# Progressing until the wait ran out; scripts/lib/unstick.sh gets them scheduled while it waits.
# shellcheck source=lib/unstick.sh
source "$ROOT/scripts/lib/unstick.sh"
trap 'unstick_release; rm -rf "$WORKDIR"' EXIT

# awk, not PyYAML: the bastion's python has no yaml module.
ROOT_APP="$(awk '/^metadata:/{m=1;next} m && /^  name:/{print $2; exit}' "$(pick root-app)")"
REV="$(awk '/^ *targetRevision:/{print $2; exit}' "$(pick root-app)")"
REV="${REV:-HEAD}"
# A RE-RUN MUST NOT PASS ON THE PREVIOUS SYNC'S RESULT. After a component is turned on, the children
# it adds do not exist until the root's sync has run against the new commit, and the ones already
# there are Synced and Healthy -- so a wait that looks only at the children passes in a second with
# the new ones never created. Refresh the root so it resolves
# the commit just pushed, wait for THIS sync operation to finish, then wait on exactly the children
# that sync says the root owns.
kubectl -n argocd annotate applications.argoproj.io "$ROOT_APP" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
sleep 5
before="$(kubectl -n argocd get applications.argoproj.io "$ROOT_APP" -o jsonpath='{.status.operationState.startedAt}' 2>/dev/null)"
kubectl -n argocd patch applications.argoproj.io "$ROOT_APP" --type merge \
  -p "{\"operation\":{\"initiatedBy\":{\"username\":\"bootstrap-gitops\"},\"sync\":{\"revision\":\"$REV\",\"prune\":$PRUNE}}}" >/dev/null
echo "sync of $ROOT_APP at $REV started; waiting up to ${WAIT}s for every Application to be Synced and Healthy"

start=$(date +%s)
while :; do
  op="$(kubectl -n argocd get applications.argoproj.io "$ROOT_APP" -o jsonpath='{.status.operationState.startedAt}|{.status.operationState.phase}' 2>/dev/null)"
  [[ "${op%%|*}" != "$before" && ( "${op#*|}" == Succeeded || "${op#*|}" == Failed || "${op#*|}" == Error ) ]] && break
  (( $(date +%s) - start >= WAIT )) && { echo "the root's sync did not finish in ${WAIT}s ($op)" >&2; exit 1; }
  sleep 3
done
echo "  $(( $(date +%s) - start ))s root sync ${op#*|}: $(kubectl -n argocd get applications.argoproj.io "$ROOT_APP" -o jsonpath='{.status.operationState.message}')"
# The sync result lists an Application it pruned, or would have, with status Pruned / PruneSkipped:
# those are turned off, and waiting for them to be Healthy waited out the full timeout.
owned="$(kubectl -n argocd get applications.argoproj.io "$ROOT_APP" -o jsonpath='{range .status.operationState.syncResult.resources[?(@.kind=="Application")]}{.name}|{.status}{"\n"}{end}')"
want="$(printf '%s\n' "$owned" | awk -F'|' '$1!="" && $2!="Pruned" && $2!="PruneSkipped" {print $1}' | sort)"
pruned="$(printf '%s\n' "$owned" | awk -F'|' '$2=="Pruned" {print $1}' | sort)"
stale="$(printf '%s\n' "$owned" | awk -F'|' '$2=="PruneSkipped" {print $1}' | sort)"
echo "  the root owns: $(echo $want)"
[[ -n "$pruned" ]] && echo "  pruned (turned off): $(echo $pruned)"
[[ -n "$stale" ]] && echo "  turned off but still running: $(echo $stale) -- rerun with --prune to delete them and what they installed"
# AND REFRESH EVERY CHILD. A child that reads values from this repository polls Git on its own
# schedule (about three minutes), so after a push it is Synced against the PREVIOUS commit and a
# wait without this refresh passes with the new values undelivered: eks-agents-base still at the
# previous commit, and the agents missing whatever the new values added.
for a in $want; do
  kubectl -n argocd annotate applications.argoproj.io "$a" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
done
sleep 10

# Each Deployment, StatefulSet and DaemonSet an Application owns that is not ready, as
# "namespace/name ready/desired reason", the reason being the first waiting reason of its pods
# (ImagePullBackOff, CrashLoopBackOff, ...) or "no pod scheduled".
not_ready_workloads() {
  kubectl -n argocd get applications.argoproj.io "$1" -o jsonpath='{range .status.resources[*]}{.kind}|{.namespace}|{.name}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' '$1=="Deployment" || $1=="StatefulSet" || $1=="DaemonSet"' \
    | while IFS='|' read -r kind ns name; do
        if [[ "$kind" == DaemonSet ]]; then
          r="$(kubectl -n "$ns" get daemonset "$name" -o jsonpath='{.status.numberReady}/{.status.desiredNumberScheduled}' 2>/dev/null)"
        else
          r="$(kubectl -n "$ns" get "$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')" "$name" -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)"
        fi
        [[ -z "$r" ]] && continue
        ready="${r%/*}"; desired="${r#*/}"
        [[ "${ready:-0}" == "${desired:-0}" ]] && continue
        why="$(kubectl -n "$ns" get pods -o jsonpath='{range .items[*]}{.metadata.name}|{.status.containerStatuses[*].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
          | awk -F'|' -v p="$name-" 'index($1, p) == 1 && $2 != "" {print $2; exit}')"
        echo "$ns/$name ${ready:-0}/${desired:-0} ${why:-no pod scheduled}"
      done
}

# A DESTINATION WITH NO VALUE YET. Declaring a third_party_credentials entry creates its Secrets
# Manager secret empty: the value comes afterwards, from set-credential.sh or from an approval in the
# consent receiver, which this same sync deploys. Until then the gateway's secret syncer can't mount
# that secret, its new pod waits in ContainerCreating, and platform-secrets stays Progressing. That
# is the expected state between the two steps, not a fault to wait out, so the wait doesn't count
# it: each such secret is named once, with the command that gives it a value. The syncer pod that
# was already running keeps serving the destinations that have one.
awaiting_values() {  # -> "secret name" per line, for syncer pods that fail to mount a valueless secret
  kubectl get events -A --field-selector reason=FailedMount -o jsonpath='{range .items[*]}{.involvedObject.namespace}|{.involvedObject.name}|{.message}{"\n"}{end}' 2>/dev/null \
    | awk -F'|' 'index($2, "platform-secrets-syncer-") == 1 && $3 ~ /find the specified secret value/' \
    | while IFS='|' read -r ns pod msg; do
        kubectl -n "$ns" get pod "$pod" >/dev/null 2>&1 || continue   # an event for a pod that's gone
        printf '%s\n' "$msg" | sed -n 's/.*Failed fetching secret \([^:]*\):.*/\1/p'
      done | sort -u
}
awaiting_note() {  # $1: newline-separated secret names
  printf '%s\n' "$1" | while read -r sm; do
    [[ -n "$sm" ]] || continue
    c="${sm%%/*}" k="${sm##*/}"
    echo "  $sm has no value yet, so the gateway's secret syncer waits for it. Set it with one of:"
    echo "    ./scripts/set-credential.sh --cluster $c --region ${AWS_REGION:-<region>} token $k"
    echo "    ./scripts/consent.sh --cluster $c --region ${AWS_REGION:-<region>} $k   (with oauth_consent.$k)"
  done
}
awaiting=""

last=""
# Checked every 5 s, so the wait ends within 5 s of the last Application turning Healthy.
# The repairs below run once a minute, on their own clock.
last_tick=$(( $(date +%s) - 60 ))
while :; do
  tick=0; (( $(date +%s) - last_tick >= 60 )) && { tick=1; last_tick=$(date +%s); }
  table="$(kubectl -n argocd get applications.argoproj.io -o jsonpath='{range .items[*]}{.metadata.name}|{.status.sync.status}|{.status.health.status}|{.status.conditions[0].message}{"\n"}{end}' 2>/dev/null)"
  # The root itself is excluded: it has no automated sync by design, and reports OutOfSync once its
  # children's live objects carry fields Argo CD adds. Its children are what this waits for.
  bad="$(printf '%s\n' "$table" | awk -F'|' -v r="$ROOT_APP" 'NF>1 && $1!=r && ($2!="Synced" || $3!="Healthy")')"
  # A child the root owns that does not exist yet is pending, not absent from the count.
  for a in $want; do printf '%s\n' "$table" | grep -q "^$a|" || bad="$bad"$'\n'"$a|Missing|Missing|not created yet"; done
  bad="$(printf '%s\n' "$bad" | sed '/^$/d')"
  # platform-secrets Progressing only because a destination has no value yet: see awaiting_values.
  if printf '%s\n' "$bad" | grep -q '^platform-secrets|Synced|Progressing'; then
    aw="$(awaiting_values || true)"
    others="$(not_ready_workloads platform-secrets | grep -v '/platform-secrets-syncer ' || true)"
    if [[ -n "$aw" && -z "$others" ]]; then
      [[ "$aw" != "$awaiting" ]] && { awaiting="$aw"; awaiting_note "$aw"; }
      bad="$(printf '%s\n' "$bad" | grep -v '^platform-secrets|' || true)"
    fi
  fi
  n="$(printf '%s\n' "$table" | grep -c '|' || true)"
  if [[ -z "$bad" && "$n" -gt 1 ]]; then
    if [[ -n "$awaiting" ]]; then
      echo "all $n Applications Synced and Healthy after $(( $(date +%s) - start ))s, except the gateway's secret syncer, which waits for:"
      printf '%s\n' "$awaiting" | sed 's/^/    /'
    else
      echo "all $n Applications Synced and Healthy after $(( $(date +%s) - start ))s"
    fi
    # --roll-agents: a sync that changed what agents are given reaches a Sandbox pod only when the pod
    # is next created. scripts/roll-agents.sh recreates the ones whose Sandbox moved on.
    unstick_release
    [[ "$ROLL" -eq 1 ]] && exec "$ROOT/scripts/roll-agents.sh"
    exit 0
  fi
  unstick_tick
  if (( $(date +%s) - start >= WAIT )); then
    echo "after ${WAIT}s, not Synced+Healthy:" >&2
    printf '%s\n' "$bad" | awk -F'|' '{printf "  %-34s %-10s %-12s %s\n", $1, $2, $3, substr($4,1,160)}' >&2
    printf '%s\n' "$bad" | cut -d'|' -f1 | while read -r a; do
      [[ -n "$a" ]] && not_ready_workloads "$a" | sed "s/^/    not ready: /" >&2
    done
    exit 1
  fi
  # A FAILED SYNC ARGO CD WILL NOT RE-RUN ON ITS OWN either: automated sync does not retry the same
  # revision after a failure unless the Application has a retry policy, and a dependency that
  # arrived later (a namespace from the base chart) does not count as a change. Re-sync each such
  # Application once a minute while waiting.
  if (( tick )); then
    kubectl -n argocd get applications.argoproj.io -o jsonpath='{range .items[*]}{.metadata.name}|{.status.operationState.phase}|{.status.sync.status}{"\n"}{end}' 2>/dev/null \
      | awk -F'|' -v r="$ROOT_APP" '$1!=r && ($2=="Failed" || $2=="Error") && $3!="Synced" {print $1}' \
      | while read -r a; do
          [[ -n "$a" ]] && kubectl -n argocd patch applications.argoproj.io "$a" --type merge \
            -p '{"operation":{"initiatedBy":{"username":"bootstrap-gitops"},"sync":{"prune":false}}}' >/dev/null 2>&1 \
            && echo "  re-synced $a (its last sync failed)"
        done
  fi
  # A RENDER FAILURE ARGO CD WILL NOT RETRY ON ITS OWN. An Application whose chart could not render
  # -- the base chart before the CRDs it checks for have synced, typically -- keeps that failed
  # render until it is hard-refreshed, even after the cause is gone. Refresh each such Application once
  # a minute while waiting.
  if (( tick )); then
    printf '%s\n' "$bad" | awk -F'|' '$4 ~ /Failed to load target state|ComparisonError|failed to generate manifest/ {print $1}' \
      | while read -r a; do
          [[ -n "$a" ]] && kubectl -n argocd annotate applications.argoproj.io "$a" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 \
            && echo "  hard-refreshed $a (stale failed render)"
        done
  fi
  # A STALE PROGRESSING HEALTH. istio-base (CRDs and a webhook, no resource that reports health) can
  # read Synced/Progressing for minutes after its sync with every resource healthy; a normal
  # refresh turns it Healthy at once. The Application's status does not carry each
  # resource's health (the capability's Argo CD keeps it out of the status), so read the workloads
  # themselves: name the Deployment, StatefulSet or DaemonSet that is not ready and why, and refresh
  # only an Application whose workloads are all ready. Once a minute while waiting.
  if (( tick )); then
    printf '%s\n' "$bad" | awk -F'|' '$2=="Synced" && $3=="Progressing" {print $1}' \
      | while read -r a; do
          [[ -z "$a" ]] && continue
          nr="$(not_ready_workloads "$a")"
          if [[ -n "$nr" ]]; then
            printf '%s\n' "$nr" | sed "s/^/  $a waiting on /"
          else
            kubectl -n argocd annotate applications.argoproj.io "$a" argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 \
              && echo "  refreshed $a (Progressing with every workload ready)"
          fi
        done
  fi
  # A PRUNED APPLICATION STUCK DELETING. When a component is turned off, the base chart can prune its
  # namespace in the same sync, and the component's own Application, already marked for deletion,
  # keeps an automated sync retrying into the namespace that's gone ("namespaces ... not found").
  # Argo CD's resources finalizer waits behind that operation, so the Application never goes. Its
  # objects went with the namespace, so ending the operation lets the deletion finish.
  if (( tick )); then
    for a in $pruned; do
      if [[ -n "$(kubectl -n argocd get applications.argoproj.io "$a" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" \
            && -n "$(kubectl -n argocd get applications.argoproj.io "$a" -o jsonpath='{.operation}' 2>/dev/null)" ]]; then
        kubectl -n argocd patch applications.argoproj.io "$a" --type json -p '[{"op":"remove","path":"/operation"}]' >/dev/null 2>&1 \
          && echo "  ended $a's retrying sync so its deletion can finish (turned off)"
      fi
    done
  fi
  # PODS THE MESH STILL REDIRECTS, AFTER THE MESH IS GONE. Ambient mode redirects an enrolled pod's
  # traffic to ztunnel with rules istio-cni wrote into the pod's own network namespace when it
  # started. Turning the mesh off removes ztunnel and istio-cni but not those rules, so a pod that
  # was enrolled keeps sending everything to a ztunnel that no longer exists: the gateway's
  # controller can't reach the API server and crash-loops, and the data plane never turns ready. A
  # new pod starts without them, so each such pod is deleted once istio-system is gone, and its
  # controller replaces it.
  if (( tick )) && ! kubectl get namespace istio-system >/dev/null 2>&1; then
    kubectl get pods -A -o jsonpath='{range .items[?(@.metadata.annotations.ambient\.istio\.io/redirection=="enabled")]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | while IFS='|' read -r ns n; do
          [[ -n "$n" ]] || continue
          kubectl -n "$ns" delete pod "$n" --wait=false >/dev/null 2>&1 \
            && echo "  restarted $ns/$n: it still redirected its traffic to the mesh, which is turned off"
        done
  fi
  # A FINALIZER WHOSE CONTROLLER WAS TURNED OFF. Turning off agents as tasks prunes KEDA and, in the
  # same sync, the base chart's ClusterTriggerAuthentication, which still carries KEDA's finalizer.
  # With the operator gone nothing removes it, and eks-agents-base waits "for deletion of
  # keda.sh/ClusterTriggerAuthentication" for good. KEDA's objects marked for deletion lose that
  # finalizer once KEDA's operator is gone, whether this sync or an earlier one pruned it.
  if (( tick )) && ! kubectl -n keda get deployment keda-operator >/dev/null 2>&1 \
       && kubectl get crd clustertriggerauthentications.keda.sh >/dev/null 2>&1; then
    for kind in clustertriggerauthentications triggerauthentications scaledjobs scaledobjects; do
      kubectl get "$kind.keda.sh" -A -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.namespace}{"|"}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | while IFS='|' read -r ns n; do
            [[ -n "$n" ]] || continue
            kubectl ${ns:+-n "$ns"} patch "$kind.keda.sh" "$n" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 \
              && echo "  released $kind.keda.sh/$n: KEDA, which held its finalizer, is turned off"
          done
    done
  fi
  # A NETWORK POLICY WHOSE CONTROLLER WAS TURNED OFF. Turning the boundary off prunes the
  # amazon-vpc-cni ConfigMap that switches EKS's network policy controller on, and in the same sync
  # every ClusterNetworkPolicy and ApplicationNetworkPolicy, each carrying the controller's
  # networking.k8s.aws finalizer. With the controller off nothing removes it, and eks-agents-base
  # stays OutOfSync and Progressing for good. A policy marked for deletion loses that finalizer
  # once the controller is off; the garbage collector then removes the PolicyEndpoints it owns.
  if (( tick )) && [[ "$(kubectl -n kube-system get configmap amazon-vpc-cni -o jsonpath='{.data.enable-network-policy-controller}' 2>/dev/null)" != "true" ]]; then
    for kind in clusternetworkpolicies.networking.k8s.aws applicationnetworkpolicies.networking.k8s.aws networkpolicies.networking.k8s.io; do
      kubectl get "$kind" -A -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.metadata.finalizers}{"\n"}{end}' 2>/dev/null \
        | while IFS='|' read -r ns n fin; do
            [[ -n "$n" && "$fin" == *networking.k8s.aws/* ]] || continue
            kubectl ${ns:+-n "$ns"} patch "$kind" "$n" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 \
              && echo "  released ${kind%%.*}/$n: the network policy controller, which held its finalizer, is turned off"
          done
    done
  fi
  now="$(printf '%s\n' "$bad" | cut -d'|' -f1-3 | tr '\n' ' ')"
  [[ "$now" != "$last" ]] && { echo "  $(( $(date +%s) - start ))s pending: $(printf '%s\n' "$bad" | cut -d'|' -f1 | tr '\n' ' ')"; last="$now"; }
  sleep 5
done
