#!/usr/bin/env bash
#
# Security scan: ASH (awslabs/automated-security-helper), plus Checkov on what is applied.
#
#   ./scripts/security-scan.sh            # scan the committed tree (HEAD)
#   ASH_BIN=/path/to/ash ./scripts/security-scan.sh
#
# Two parts, because one scanner cannot see the thing that matters most:
#
#   1. ASH (awslabs/automated-security-helper) at the commit that repository pins, with .ash/.ash.yaml,
#      failing at HIGH. It runs over an EXPORT of HEAD (git archive), not the working tree, so a
#      gitignored tfvars, state file or virtualenv is never scanned and nothing is written here.
#   2. Checkov on the RENDERED manifests. ASH's own Checkov step renders Helm charts itself, which
#      fails on these charts (a temporary file it renders into is gone before its CycloneDX
#      output reads it), and it cannot see inside the Agent ResourceGraphDefinition at all -- the
#      agent's pod is a template in a kro resource, not a manifest. So the charts are rendered here
#      with realistic values, and the agent's pod is lifted out of the graph and scanned as a Pod.
#
# Checkov findings are reported, not gated: several are known false positives on this stack (a kro
# `${...}` expression read as a literal, ApplicationNetworkPolicy not recognised as a network
# policy).
#
# Needs: python3.10+, helm, git. On first use it installs ASH into $WORK/venv-ash (a few minutes).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${SECURITY_SCAN_WORK:-${TMPDIR:-/tmp}/eks-agents-security-scan}"
ASH_COMMIT=af1206aff596f1288ad066828058b3011de2a998   # the pinned ASH commit
PY="${PYTHON_BIN:-python3}"
mkdir -p "$WORK"
fails=0

# --- 1. ASH --------------------------------------------------------------------------------------
ASH="${ASH_BIN:-$WORK/venv-ash/bin/ash}"
if [[ ! -x "$ASH" ]]; then
  echo "installing ASH $ASH_COMMIT into $WORK/venv-ash"
  "$PY" -m venv "$WORK/venv-ash" && "$WORK/venv-ash/bin/pip" -q install \
    "automated-security-helper @ git+https://github.com/awslabs/automated-security-helper.git@$ASH_COMMIT" \
    || { echo "could not install ASH"; exit 2; }
fi

rm -rf "$WORK/src" "$WORK/ash-out" && mkdir -p "$WORK/src"
# This directory's tree, which is not the repository's root in sample-eks-docs.
git -C "$ROOT" archive "HEAD:$(git -C "$ROOT" rev-parse --show-prefix)" | tar -x -C "$WORK/src"
echo "== ASH over HEAD ($(git -C "$ROOT" rev-parse --short HEAD))"
(cd "$WORK/src" && "$ASH" --mode local --source-dir "$WORK/src" --output-dir "$WORK/ash-out" \
   --config .ash/.ash.yaml >"$WORK/ash.log" 2>&1)
ash_rc=$?
grep -E "^(bandit|checkov|detect-secrets|grype|npm-audit|opengrep|semgrep|syft) " "$WORK/ash-out/reports/ash.summary.txt" 2>/dev/null
if [[ $ash_rc -ne 0 ]]; then
  echo "!! ASH found actionable findings (or failed): $WORK/ash-out/reports/ash.summary.md"
  fails=$((fails + 1))
else
  echo "ASH: no actionable findings at HIGH"
fi
echo "   (checkov ERROR inside ASH is the Helm-rendering crash described above; part 2 covers it)"

# --- 2. Checkov on rendered manifests ------------------------------------------------------------
CHECKOV="${CHECKOV_BIN:-$(command -v checkov || ls "$HOME/.local/share/uv/tools/checkov/bin/checkov" 2>/dev/null)}"
if [[ -z "$CHECKOV" ]]; then
  echo "!! checkov not found (ASH installs it with uv on first run; or: pip install checkov)"
  exit $((fails + 1))
fi
R="$WORK/rendered" && rm -rf "$R" && mkdir -p "$R"
cat > "$WORK/values.yaml" <<'YAML'
accountId: "111122223333"
region: us-west-2
cluster: scan
path: open-source
oidcIssuerUrl: https://oidc.example.com
storage: {checkpointBucket: scan-checkpoints}
agentResource: {enabled: true, rolePath: /eks-agents/, permissionsBoundaryArn: "arn:aws:iam::111122223333:policy/eks-agents/scan-agent-boundary"}
capabilities: {kro: {roleName: scan-capability-kro}, ack: {roleName: scan-capability-ack}}
nodeClass: {roleName: scan-node, subnetIds: [subnet-EXAMPLE], securityGroupIds: [sg-EXAMPLE]}
registry: {"agents/evals": "111122223333.dkr.ecr.us-west-2.amazonaws.com/scan/agents/evals"}
evals:
  enabled: true
  namespace: agent-evals
  serviceAccount: agent-evals
  backend: langfuse
  judge: {baseUrl: "http://egress.agentgateway-system.svc.cluster.local:8080/judge/agent-evals", model: judge, audience: agentgateway, roleArn: "arn:aws:iam::111122223333:role/eks-agents/scan-evals-judge"}
  agentcore: {logGroup: "", region: "", resultsName: ""}
experiment: {agents: {research: {cases: [{name: a, input: b}]}}}
YAML
for c in gitops/base gitops/charts/agentgateway-config gitops/charts/agent-evals gitops/charts/platform-secrets; do
  helm template scan "$ROOT/$c" -f "$ROOT/$c/values.yaml" -f "$WORK/values.yaml" >"$R/$(basename "$c").yaml" 2>"$R/$(basename "$c").err" \
    || echo "   (render of $c skipped: $(head -c 160 "$R/$(basename "$c").err"))"
done
"$PY" - "$R" <<'PY'
import sys, yaml
R = sys.argv[1]
pods = []
for d in yaml.safe_load_all(open(f"{R}/base.yaml")):
    if d and d.get("kind") == "ResourceGraphDefinition":
        for r in d["spec"]["resources"]:
            t = r["template"]
            if t.get("kind") == "Sandbox":
                pt = t["spec"]["podTemplate"]
                pods.append({"apiVersion": "v1", "kind": "Pod",
                             "metadata": {"name": f"agent-{r['id']}", "namespace": "agents", **(pt.get("metadata") or {})},
                             "spec": pt["spec"]})
yaml.safe_dump_all(pods, open(f"{R}/agent-pod.yaml", "w"))
PY
echo "== Checkov over rendered manifests and the agent's pod (reported, not gated)"
"$CHECKOV" -d "$R" --framework kubernetes --compact --quiet -o cli 2>/dev/null \
  | grep -E "^Check:|FAILED for resource" | paste - - | sed -E 's/\t+/ /; s/ +FAILED for resource:/ ->/' | sort | uniq
echo "== Checkov over terraform/ (reported, not gated)"
"$CHECKOV" -d "$ROOT/terraform" --framework terraform --compact --quiet -o cli 2>/dev/null \
  | grep -E "^Check:" | sort | uniq -c | sort -rn

exit "$fails"
