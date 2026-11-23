#!/usr/bin/env bash
#
# Install the platform layer without Argo CD, from the same Applications Argo would reconcile.
#
#   ./scripts/install-platform.sh --path open-source [prefix ...]
#   ./scripts/install-platform.sh --path open-source 20- 29- 30-   # just those (a gated one too)
#   ./scripts/install-platform.sh --path open-source --dry-run     # print the commands
#
# WHY THIS EXISTS. The ARGOCD EKS Capability authenticates people through IAM Identity Center and its
# API requires the instance ARN, so an organization without an Identity Center instance cannot
# create it. `argocd_idc_instance_arn` then stays empty, no Argo CD is created, and NOTHING from
# gitops/ arrives -- which on this path is the gateway, the mesh, the admission policy, the egress
# boundary and the agent resource definition. The cluster comes up and is not an agent platform.
#
# Without this script the alternative is translating fourteen Application manifests into helm
# invocations by hand. The four translation rules the Application format makes easiest to get wrong
# are encoded below, each with the symptom you get for missing it.
#
# This reads the Applications rather than restating them, so the chart versions and values cannot
# drift from what Argo CD would have applied. It is the supported fallback, not a parallel
# implementation.
#
# WHAT IT DOES NOT DO. It does not watch for drift, prune removed resources, or give you a sync
# status. If you have Identity Center, use Argo CD.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH_NAME=""
DRY_RUN=0
PREFIXES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)    PATH_NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         PREFIXES+=("$1"); shift ;;
  esac
done

[[ -z "$PATH_NAME" ]] && { echo "--path open-source|aws-services is required" >&2; exit 2; }
SRC="$ROOT/gitops/platform/$PATH_NAME"
[[ -d "$SRC" ]] || { echo "no such path: $SRC" >&2; exit 2; }

for t in helm kubectl python3 git; do
  command -v "$t" >/dev/null 2>&1 || { echo "$t is required" >&2; exit 2; }
done
python3 -c "import yaml" 2>/dev/null || { echo "python3 needs PyYAML (dnf install -y python3-pyyaml)" >&2; exit 2; }

# ---------------------------------------------------------------------------
# THE ACK CRDs, BEFORE THE AGENT RESOURCE DEFINITION THAT NEEDS THEM
# ---------------------------------------------------------------------------
#
# The `Agent` resource definition composes an ACK `Role` and a `PodIdentityAssociation`, and kro
# validates EVERY kind a graph composes when it accepts the graph. So with the ACK group absent the
# whole ResourceGraphDefinition is rejected, the `Agent` kind is never registered, and the error
# names a schema:
#
#   GraphAccepted=False  cannot resolve group version "iam.services.k8s.aws/v1alpha1":
#                        schema not found
#
# which reads as a kro fault and is not one. Checked HERE, before anything is installed, so the
# message arrives once and names the right component instead of surfacing later as a broken Agent.
#
# AN ACTIVE CAPABILITY DOES NOT MEAN ITS CRDs ARE THERE. The capability's controller manager applies
# them to your cluster after the capability is created, so a capability can report `ACTIVE`, with
# `health.issues` empty and its access entry and `AmazonEKSACKPolicy` in place, before any
# `services.k8s.aws` CRD is registered. Count the CRDs rather than trusting the status.
#
# WAIT, THEN WARN -- do not abort. The absence breaks the Agent resource definition and nothing
# else: the gateway, the mesh, memory and observability all install and work. Aborting the whole
# platform install for it would be a worse outcome than saying so clearly and continuing.
ack_crd_count() { kubectl get crd -o name 2>/dev/null | grep -c 'services\.k8s\.aws$'; }

# Not on --dry-run: printing the commands needs no cluster, and the wait would last its full three
# minutes on a cluster with no ACK capability.
if [[ $DRY_RUN -eq 0 ]] && kubectl version --request-timeout=10s >/dev/null 2>&1; then
  if [[ "$(ack_crd_count)" -eq 0 ]]; then
    printf 'waiting up to 180s for the ACK capability to register its CRDs'
    for _ in $(seq 1 18); do
      sleep 10
      printf '.'
      [[ "$(ack_crd_count)" -gt 0 ]] && break
    done
    printf '\n'
  fi
  if [[ "$(ack_crd_count)" -eq 0 ]]; then
    cat >&2 <<'WARN'

!! NO ACK CRDs ON THIS CLUSTER, so the `Agent` resource definition will not be accepted.

   kro validates every kind a graph composes, so the whole ResourceGraphDefinition is rejected and
   the `Agent` kind is never created. Everything else on this path still installs and works.

   This is the ACK capability, not kro. Check it:
     aws eks list-capabilities --cluster-name <cluster> --region <region>
     aws eks describe-capability --cluster-name <cluster> --capability-name <cluster>-ack --region <region>
     kubectl get crd -o name | grep -c 'services.k8s.aws'

   There is nothing to configure -- the capability's configuration schema accepts an argoCd block
   and nothing else, so no service list exists to pass. Your options are to wait longer, to delete
   and recreate the capability, or to declare agents in Terraform instead of as `Agent` resources:
   set `agents` in your tfvars, which sets agentResource.enabled to false and needs no ACK at all.

   https://docs.aws.amazon.com/eks/latest/userguide/agents-capabilities-setup.html has the full symptom.

WARN
  else
    echo "ACK CRDs registered: $(ack_crd_count) in the services.k8s.aws group"
  fi
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# THE APPLICATIONS ARGO CD WOULD CREATE, RENDERED. gitops/platform/<path> is a Helm chart whose
# templates are the platform's Applications; the root Application gives it the stack's values
# (scripts/lib/root-app.sh). Rendering it with the same values gives exactly the Applications Argo CD
# would create, with a layer that is off already left out, so this reads those rather than restating
# them. The repository and prefix it names (repo.url, repo.path) are what marks a source as this tree.
REPO_ROOT="$ROOT"
# shellcheck source=lib/root-app.sh
source "$ROOT/scripts/lib/root-app.sh"
RA="$ROOT/gitops/bootstrap/$PATH_NAME/root-app.local.yaml"
[[ -f "$RA" ]] || { echo "no $RA: run terraform apply first" >&2; exit 2; }
! grep -q 'REPO_URL\|REPO_REVISION\|PLATFORM_EXCLUDED' "$RA" \
  || { echo "$RA still carries a placeholder: run terraform apply" >&2; exit 2; }
python3 -c '
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if d and d.get("kind") == "Application":
        open(sys.argv[2], "w", encoding="utf-8").write(d["spec"]["source"]["helm"]["values"])
' "$(root_app "$PATH_NAME" "$WORK")" "$WORK/root-values.yaml"
helm template eks-agents-platform "$SRC" -f "$WORK/root-values.yaml" --output-dir "$WORK/rendered" >/dev/null \
  || { echo "could not render the platform chart in $SRC" >&2; exit 2; }
RENDERED="$WORK/rendered/$(awk '/^name:/{print $2; exit}' "$SRC/Chart.yaml")/templates"
OUR_REPO="$(python3 -c 'import sys,yaml; v=yaml.safe_load(open(sys.argv[1])); print(v["repo"]["url"]); print(v["repo"]["path"])' "$WORK/root-values.yaml")"


# EVERY FILE IS READ AS UTF-8 EXPLICITLY. Python's open() uses the LOCALE's encoding, and a host
# with no LANG set -- which is what `aws ssm send-command` gives you on Amazon Linux -- resolves that
# to ASCII. YAML files in this repository contain an em dash, so reading them under the locale's
# encoding fails with `UnicodeDecodeError` on the bastion, where this fallback runs, while working
# on a laptop.

# The translation.
python3 - "$RENDERED" "$WORK" "$OUR_REPO" "${PREFIXES[@]:-}" <<'PY'
import os, sys, yaml

src, work = sys.argv[1], sys.argv[2]
our_url, our_prefix = (sys.argv[3].split("\n") + [""])[:2]
prefixes = [p for p in sys.argv[4:] if p]

# DOTFILES ARE SKIPPED, because `kubectl apply -f <dir>` and Argo CD both skip them and this script
# exists to do what Argo CD would. Without the guard it parses whatever a filesystem left behind: a
# macOS archive extracted on Linux leaves an AppleDouble `._00-base.yaml` beside every file, and
# those are binary, so parsing them fails with a `UnicodeDecodeError` that names no file. An editor backup or a resource fork is a plausible thing to find in a directory; a file that
# is not applied should not be parsed either.
files = sorted(f for f in os.listdir(src)
               if f.endswith(".yaml") and not f.startswith(".")
               and not f.endswith("-values.yaml"))

# AND SKIP WHAT ARGO CD WOULD SKIP, read from the rendered root Application rather than from a
# second list here.

if prefixes:
    files = [f for f in files if any(f.startswith(p) for p in prefixes)]

# EVERY COMMAND'S STATUS IS CHECKED. Running the releases in order without accumulating their
# statuses lets the exit status of the LAST command decide the verdict, which reports "Platform
# installed" while the base chart -- the one carrying the admission policy, the egress boundary and
# the agent resource definition -- is not installed at all.
out = ["#!/bin/bash", "set -uo pipefail", "FAILED=()", "CURRENT_APP=?", "",
       'run() { echo "+ $*"; if ! "$@"; then FAILED+=("$CURRENT_APP");',
       # PRINT THE FAILURE WHERE IT HAPPENS, not only in the summary. The summary is at the end of a
       # fifteen-minute log, and an operator reading the tail of that log -- or a harness piping it
       # through `tail` -- sees the closing "Platform installed" and misses that the FIRST release
       # failed. In that case the base chart, which carries the admission policy, the egress
       # boundary and the agent resource definition, can be absent for an hour while every later chart
       # reports fine, and the first symptom is an Agent resource whose kind does not exist.
       '    echo; echo "!! RELEASE FAILED: $CURRENT_APP -- everything after this may depend on it" >&2; echo; fi; }', ""]
seq = 0

# IN ARGO CD'S ORDER: by sync wave, then by file name, then by position in the file. Argo CD orders
# Applications by wave, not by file name, and the two differ where it matters: the base chart is
# 00-base.yaml at wave -10, while the CRDs its Agent resource definition composes against (the
# Gateway API's, the AWS load balancer's, Agent Sandbox's) are in later files at earlier waves.
# Installing by file name would put the base chart first, which trips its CRD guard and leaves kro
# to reject the Agent kind for a Sandbox CRD that does not exist yet. A wave is read off the Application; none counts as 0, as in
# Argo CD.
ordered = []
for fi, f in enumerate(files):
    # MULTI-DOCUMENT APPLICATIONS ARE NORMAL. 20-istio.yaml carries four, one per chart, and
    # safe_load raises "expected a single document in the stream" on it.
    docs = [d for d in yaml.safe_load_all(open(os.path.join(src, f), encoding="utf-8"))
            if d and d.get("kind") == "Application"]
    for di, d in enumerate(docs):
        wave = int(((d.get("metadata") or {}).get("annotations") or {}).get("argocd.argoproj.io/sync-wave", "0"))
        ordered.append((wave, fi, di, f, d))
ordered.sort(key=lambda t: t[:3])

# GATES ARE SKIPPED, AS ARGO CD SKIPS THEM. An Application with no automated sync is a gate: Argo CD
# renders it and applies nothing until a person syncs it. Installing every Application regardless
# would make a fallback install put up components the managed path never would -- Langfuse,
# CloudNativePG, the pgvector tier -- and a chart whose guard refuses to render without an image ON
# PURPOSE would fail every run as a FAILED RELEASE that readers learn to ignore. A failure that is
# expected is one nobody reads. Naming a file explicitly is the deliberate act that syncs a gate, so
# a gated Application in a named prefix still installs.
def _automated(d):
    return ((d.get("spec") or {}).get("syncPolicy") or {}).get("automated") is not None
gated = [(f, d["metadata"]["name"]) for _, _, _, f, d in ordered if not _automated(d)]
if gated and not prefixes:
    ordered = [t for t in ordered if _automated(t[4])]
    print("# not installed, gated (no automated sync) as Argo CD would leave them: "
          + " ".join(f"{n} ({f})" for f, n in gated)
          + ". Name a file's prefix to install one deliberately.", file=sys.stderr)

for _, _, _, f, doc in ordered:
    docs = [doc]
    for doc in docs:
        spec = doc["spec"]
        app = doc["metadata"]["name"]
        ns = spec["destination"].get("namespace", "default")
        sources = spec.get("sources") or ([spec["source"]] if "source" in spec else [])
        out.append(f"echo '== {app} -> {ns} =='")
        out.append(f"CURRENT_APP={app}")
        for s in sources:
            helm = s.get("helm") or {}
            vfile = ""

            # valueFiles ARE RELATIVE TO THE CHART, not to the repo root. `-f values.yaml` fails
            # with "open values.yaml: no such file or directory" from wherever you ran this.
            # A path in this tree is repository-relative, with this directory's prefix (repo.path).
            if s.get("path") and s.get("repoURL") == our_url and our_prefix and s["path"].startswith(our_prefix):
                s["path"] = s["path"][len(our_prefix):]
            chartdir = os.path.join("REPO", s["path"]) if s.get("path") else None
            for v in helm.get("valueFiles") or []:
                if v.startswith("$values/"):
                    v = v.replace("$values/", "REPO/")
                elif not v.startswith("/") and chartdir:
                    v = os.path.normpath(os.path.join(chartdir, v))
                vfile += f" -f {v}"

            # INLINE VALUES LAST, which is Argo CD's precedence: it applies values/valuesObject over
            # the valueFiles. Passed first, a key set in both would resolve to the FILE here and to
            # the inline value under Argo CD, so the fallback would install something the
            # Application does not describe.
            #
            # VALUES COME AS `valuesObject` AS OFTEN AS `values`. Missing the object form installs
            # Istio without `profile: ambient`, which looks like a successful install of the wrong
            # thing.
            body = helm.get("values")
            obj = helm.get("valuesObject")
            if body or obj:
                seq += 1
                name = f"{app}-{seq}.values.yaml"
                open(os.path.join(work, name), "w", encoding="utf-8").write(
                    body if body else yaml.safe_dump(obj, default_flow_style=False))
                vfile += f" -f {work}/{name}"

            # THE RELEASE NAME IS THE APPLICATION'S NAME. Argo CD uses it unless releaseName is set,
            # and the charts here depend on it: the base chart's network policy names Services like
            # `agent-session-state-valkey-primary`, which only exist if the valkey release is called
            # `agent-session-state`. Installing it as `valkey` gives `valkey-primary`, the policy
            # matches nothing, and session state fails to resolve.
            rel = helm.get("releaseName") or app

            if s.get("chart"):
                repo, chart, rev = s["repoURL"], s["chart"], s["targetRevision"]
                if repo.startswith("http"):
                    ref, extra = chart, f" --repo {repo}"
                else:
                    # OCI. Bitnami's https index still LISTS charts it will not serve --
                    # `invalid_reference: invalid tag` -- so the Applications pin OCI coordinates and
                    # this has to pass them through as oci:// rather than as --repo.
                    ref, extra = f"oci://{repo}/{chart}", ""
                out.append(f"run helm upgrade --install {rel} {ref}{extra} --version {rev} "
                           f"-n {ns} --create-namespace{vfile} --wait --timeout 15m")
            elif s.get("path") and s.get("repoURL") == our_url:
                # CRDS THE CHART RENDERS GO IN FIRST. The base chart carries the gateway.k8s.aws CRDs
                # with ingress on (44-aws-gateway-api-crds.yaml), and Helm maps every object of a
                # release before it applies any, so the release fails on its own
                # LoadBalancerConfiguration ("resource mapping not found") unless the CRDs already
                # exist. Argo CD orders them by sync wave instead.
                out.append(f"run sh -c 'crds=$(helm template {rel} REPO/{s['path']} -n {ns}{vfile} "
                           f"| python3 REPO/scripts/lib/chart_crds.py); [ -z \"$crds\" ] || "
                           f"{{ printf \"%s\\n\" \"$crds\" | kubectl apply --server-side -f - && "
                           f"kubectl wait --for condition=established crd -l app.kubernetes.io/part-of=eks-agents-paved-paths --timeout=120s; }}'")
                out.append(f"run helm upgrade --install {rel} REPO/{s['path']} "
                           f"-n {ns} --create-namespace{vfile} --wait --timeout 15m")
            elif s.get("path"):
                out.append(f'G=$(mktemp -d); git clone --depth 1 --branch {s["targetRevision"]} '
                           f'{s["repoURL"]} $G >/dev/null 2>&1')
                tail = s["path"].rstrip("/")
                # A KUSTOMIZE DIRECTORY NEEDS -k, NOT -f. Argo CD detects a kustomization.yaml and
                # runs kustomize itself; `kubectl apply -f <dir>` instead tries to apply that file
                # as a manifest and fails with
                #
                #   resource mapping not found ... no matches for kind "Kustomization" in version
                #   "kustomize.config.k8s.io/v1beta1" / ensure CRDs are installed first
                #
                # which reads like a missing CRD and is a missing flag. The AWS Gateway API CRDs
                # fail to install this way, and the message sends the diagnosis toward CRD
                # ordering.
                kustomized = 'test -f "$G/%s/kustomization.yaml"' % s["path"].strip("/")
                if tail.endswith("helm") or tail.endswith("chart"):
                    out.append(f"run helm upgrade --install {rel} $G/{s['path']} "
                               f"-n {ns} --create-namespace{vfile} --wait --timeout 15m")
                else:
                    out.append(f'if {kustomized}; then')
                    out.append(f"  run kubectl apply -k $G/{s['path']}")
                    out.append('else')
                    out.append(f"  run kubectl apply -f $G/{s['path']}")
                    out.append('fi')
                out.append('rm -rf "$G"')
        out.append("")

out += ['',
        'if [[ ${#FAILED[@]} -gt 0 ]]; then',
        '  echo; echo "FAILED RELEASES:" >&2',
        '  for f in "${FAILED[@]}"; do echo "  $f" >&2; done',
        '  exit 1',
        'fi']
open(os.path.join(work, "run.sh"), "w", encoding="utf-8").write("\n".join(out) + "\n")
print(f"{len(files)} application file(s)")
PY
[[ $? -eq 0 ]] || exit 1

sed -i.bak "s#REPO/#$ROOT/#g" "$WORK/run.sh" && rm -f "$WORK/run.sh.bak"

if [[ $DRY_RUN -eq 1 ]]; then
  # INCLUDE THE CONDITIONALS. Filtered to the command lines alone, the output would show
  # `kubectl apply -f <dir>` for a directory that carries a kustomization.yaml, hiding the `if`
  # that picks `-k` -- so --dry-run would print a command that fails with "no matches for kind
  # Kustomization" while the real run does the right thing. A dry run a reader cannot trust is worse
  # than none.
  grep -E "^(run helm|run kubectl|run sh|echo|G=|if |else$|fi$|  run )" "$WORK/run.sh" | sed -E 's/^( *)run /\1/'
  exit 0
fi

# --create-namespace AND A CHART THAT TEMPLATES ITS OWN NAMESPACE COLLIDE. Helm refuses to adopt a
# namespace it did not create -- "invalid ownership metadata; label validation error: missing key
# app.kubernetes.io/managed-by" -- and the failure arrives after the CRDs are already installed, so a
# retry hits a different error. Argo CD's ServerSideApply adopts it instead, which is why this only
# bites here. If a release fails that way, delete the namespace and re-run this script.
bash "$WORK/run.sh"
rc=$?

echo
if [[ $rc -eq 0 ]]; then
  echo "Platform installed. Next: apply an Agent (see gitops/examples) and run"
  echo "  ./scripts/exercise.sh --path $PATH_NAME"
  echo
  echo "Note that several components wait on a secret this repository deliberately does not create;"
  echo "\`terraform output next_steps\` lists them and why."
else
  echo "A release failed. The commands are in $WORK/run.sh -- re-run the one that failed by hand to"
  echo "see its full output, since --wait hides it behind a timeout." >&2
fi
exit $rc
