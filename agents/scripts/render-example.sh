#!/usr/bin/env bash
#
# Fill an example's placeholders from the values Terraform already rendered.
#
#   ./scripts/render-example.sh gitops/examples/mcp-server/mcp-server.yaml | kubectl apply -f -
#   EXPOSE_ROUTE=research ./scripts/render-example.sh gitops/examples/reasoning-execution-split/reasoning.yaml
#
# WHY THIS EXISTS. The charts under gitops/ take `terraform-values.yaml` as a values file, so
# nothing in them is ever hand-edited. The EXAMPLES are raw manifests, so their account id, region,
# cluster name, OIDC issuer and image URLs are placeholders -- and every one of those five is
# already in that same rendered file or derivable from it. Editing them by hand is therefore
# avoidable work, and it is work that goes wrong quietly: a substitution that drops the `https:`
# scheme from CLUSTER_OIDC_ISSUER leaves the MCP server unable to fetch its JWKS, and the only
# symptom is `401 unauthenticated` on every tools call, which reads as an MCP wiring fault.
#
# WHAT IT DOES NOT SUBSTITUTE, deliberately: anything only you can know. Your OIDC provider's
# endpoints and client secret, a guardrail ARN, a per-session name. Those stay as REPLACE and the
# script says which it left.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${1:-}"
PATH_NAME="${2:-open-source}"

[[ -z "$FILE" ]] && { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[[ -f "$FILE" ]] || { echo "no such file: $FILE" >&2; exit 2; }

VALUES="$ROOT/gitops/platform/$PATH_NAME/terraform-values.yaml"
[[ -f "$VALUES" ]] || { echo "no rendered values at $VALUES -- run terraform apply first" >&2; exit 2; }

# Read the TOP-LEVEL keys by parsing the YAML. A text match goes wrong two ways: a greedy
# `s/.*: *//` eats the `https:` in the issuer URL; and a regex for `region:` matches a NESTED, empty
# `region` above the top-level one -- `read` then collapses the empty field and shifts the rest, so
# images are named `<acct>.dkr.ecr.<cluster>.amazonaws.com/https://oidc...`. One value per line, so
# an empty one cannot shift the others.
{ read -r ACCOUNT; read -r REGION; read -r CLUSTER; read -r OIDC; read -r DOMAIN; read -r GATEWAY_ON; read -r PERSON_ISSUER; read -r PERSON_CLIENTS; read -r PERSON_AGENTS; read -r PERSON_AUDIENCE; read -r PERSON_ACTOR_ISSUER; read -r PERSON_ACTOR_CLIENTS; } <<<"$(python3 - "$VALUES" <<'PY2'
import sys, yaml
v = yaml.safe_load(open(sys.argv[1], encoding="utf-8")) or {}
for key in ("accountId", "region", "cluster", "oidcIssuerUrl"):
    val = v.get(key)
    print(val if isinstance(val, str) and val.strip() else "UNSET")
# The ingress domain, for the route hostname of an example; empty when there is no ingress.
print(((v.get("ingress") or {}).get("domainName") or "").strip())
# Whether the platform has a gateway, which decides the image of an agent.
print("true" if (v.get("gateway") or {}).get("enabled") else "false")
# Acting for a person (enable_person_access): the issuer and the clients a tool verifies a person
# token against; "-" when off, so an empty value cannot shift the lines after it.
pa = v.get("personAccess") or {}
print((pa.get("issuer") or "-") if pa.get("enabled") else "-")
print(",".join(pa.get("clientIds") or []) or "-" if pa.get("enabled") else "-")
# The agents that may act for a person, as the workload subjects a tool sees its caller as.
ns = ((v.get("namespaces") or {}).get("reasoning") or "agents").strip()
print(",".join("system:serviceaccount:%s:%s" % (ns, a) for a in (pa.get("agents") or [])) or "-" if pa.get("enabled") else "-")
# One delegated token (person_access_delegated_token): its audience, and the issuer of its actor.
te = (pa.get("tokenExchange") or {}) if pa.get("enabled") else {}
print((te.get("audience") or "-") if te.get("enabled") else "-")
print((te.get("actorIssuer") or "-") if te.get("enabled") else "-")
# Which Cognito client is which agent (AWS services path), as client=subject pairs.
print(",".join("%s=%s" % (c, a) for c, a in sorted((te.get("actorClients") or {}).items())) or "-" if te.get("enabled") else "-")
PY2
)"

for v in ACCOUNT REGION CLUSTER OIDC; do
  [[ "${!v}" == "UNSET" ]] && { echo "could not read $v from $VALUES" >&2; exit 1; }
done

ECR="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com/${CLUSTER}"

# THE AGENTS' IMAGE FOLLOWS THE GATEWAY. The examples name agents/reasoning, the gateway image, which
# refuses to start with no gateway endpoint ("No model endpoint is set"). With gateway.enabled false
# the render names agents/reasoning-direct instead, which calls Amazon Bedrock with the agent's own
# role: otherwise an example's agents crash-loop on a cluster whose gateway is turned off.
IMAGE_SED='s#/agents/reasoning:#/agents/reasoning:#'
[[ "$GATEWAY_ON" == false ]] && IMAGE_SED='s#/agents/reasoning:#/agents/reasoning-direct:#g'
# IMAGE_TAG=v2: the tag the examples' agents/ images are rendered with. The examples name :v1, and ECR
# tags are immutable, so after a rebuild (build-images.sh --tag v2) every apply would need a hand edit.
TAG_SED='s#^##'
# Extended syntax (the sed below runs with -E), and no \b, which macOS sed lacks.
[[ -n "${IMAGE_TAG:-}" ]] && TAG_SED="s#(/agents/[a-z-]+):v1([^0-9]|\$)#\\1:${IMAGE_TAG}\\2#g"

# EXPOSE_ROUTE=research[,other]: put the named Agents behind ingress (expose: route) instead
# of the example's own `expose`. The examples ship cluster-only, because ingress is optional, so
# without this an example behind ingress needs a hand edit. The gate, hostname and
# identity provider still come from the chart's values, so nothing else changes.
route_exposed() {
  if [[ -z "${EXPOSE_ROUTE:-}" ]]; then cat; return; fi
  awk -v names=",${EXPOSE_ROUTE}," '
    /^---/ { kind=""; name="" }
    /^kind:/ { kind=$2 }
    /^  name:/ && name == "" { name=$2 }
    kind == "Agent" && /^  expose:/ && index(names, "," name ",") { sub(/expose: *[a-z]+/, "expose: route") }
    { print }'
}

# THE MCP SERVER'S OWN TOKEN CHECK, by path (gitops/examples/mcp-server/mcp-server.yaml). Off only
# behind the in-cluster gateway, which authenticates the agent and forwards no token; on
# aws-services agents call the server directly, so the check is the whole gate and stays on.
MCP_TOKEN_CHECK=true
[[ "$PATH_NAME" == "open-source" ]] && MCP_TOKEN_CHECK=false
# AND WHO REACHES IT. The server runs in `mcp-servers`, unsandboxed, on both paths. Open source: the
# in-cluster gateway over the mesh, so the agent-namespace rule (`# mcp-direct`) is dropped. AWS
# services: the agents directly, so the gateway's rule and the namespace's mesh label
# (`# mcp-gateway`) are dropped -- AgentCore Gateway is outside the cluster.
MCP_NAMESPACE=mcp-servers
MCP_SANDBOX_SED="/# mcp-direct/d"
[[ "$PATH_NAME" == "aws-services" ]] && MCP_SANDBOX_SED="/# mcp-gateway/d"

# A GUARDRAIL IS THE ONE PLACEHOLDER WITH A SAFE DEFAULT: the field is optional on an Agent. With
# GUARDRAIL_ARN set it is filled in; without it the line is dropped and said so on stderr, rather
# than left as `guardrail/REPLACE` for the apply to reject.
if [[ -n "${GUARDRAIL_ARN:-}" ]]; then
  # Extended syntax: the sed below runs with -E, where \( is a literal parenthesis.
  GUARDRAIL_SED="s#^([[:space:]]*guardrailArn:).*guardrail/REPLACE.*#\\1 ${GUARDRAIL_ARN}#"
else
  GUARDRAIL_SED="/^[[:space:]]*guardrailArn:.*guardrail\/REPLACE/d"
  grep -qE '^[[:space:]]*guardrailArn:.*guardrail/REPLACE' "$FILE" \
    && echo "guardrailArn left out: set GUARDRAIL_ARN=<arn> to attach a guardrail" >&2
fi

[[ "$PERSON_ISSUER" == "-" ]] && PERSON_ISSUER=""
[[ "$PERSON_CLIENTS" == "-" ]] && PERSON_CLIENTS=""
[[ "$PERSON_AGENTS" == "-" ]] && PERSON_AGENTS=""
[[ "$PERSON_AUDIENCE" == "-" ]] && PERSON_AUDIENCE=""
[[ "$PERSON_ACTOR_ISSUER" == "-" ]] && PERSON_ACTOR_ISSUER=""
[[ "$PERSON_ACTOR_CLIENTS" == "-" ]] && PERSON_ACTOR_CLIENTS=""
sed \
  -e "s#value: \"\"   \# person-token-issuer#value: \"${PERSON_ISSUER}\"   \# person-token-issuer#" \
  -e "s#value: \"\"   \# person-token-client-ids#value: \"${PERSON_CLIENTS}\"   \# person-token-client-ids#" \
  -e "s#value: \"\"   \# person-access-agents#value: \"${PERSON_AGENTS}\"   \# person-access-agents#" \
  -e "s#value: \"\"   \# person-delegated-audience#value: \"${PERSON_AUDIENCE}\"   \# person-delegated-audience#" \
  -e "s#value: \"\"   \# person-actor-issuer#value: \"${PERSON_ACTOR_ISSUER}\"   \# person-actor-issuer#" \
  -e "s#value: \"\"   \# person-actor-clients#value: \"${PERSON_ACTOR_CLIENTS}\"   \# person-actor-clients#" \
  -e "s#value: \"true\"   \# mcp-require-token#value: \"${MCP_TOKEN_CHECK}\"   \# mcp-require-token#" \
  -e "s#namespace: mcp-servers   \# mcp-namespace#namespace: ${MCP_NAMESPACE}   \# mcp-namespace#" \
  ${MCP_SANDBOX_SED:+-e "$MCP_SANDBOX_SED"} \
  -e "s#OIDC_ISSUER_NOT_SET#${OIDC}#g" \
  -E -e "s#https://oidc\.eks\.[a-z0-9-]*\.amazonaws\.com/id/EXAMPLE([^A-Za-z0-9_]|$)#${OIDC}\1#g" \
  ${DOMAIN:+-e "s#agents.internal.example.com#${DOMAIN}#g"} \
  -e "s#CLUSTER_NOT_SET#${CLUSTER}#g" \
  -e "s#REPLACE_ECR_URL#${ECR}#g" \
  -e "s#ACCOUNT\.dkr\.ecr\.REGION\.amazonaws\.com/agents/#${ECR}/agents/#g" \
  -e "s#ACCOUNT\.dkr\.ecr\.REGION\.amazonaws\.com#${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com#g" \
  -e "s#arn:aws:bedrock:REGION:ACCOUNT_ID:#arn:aws:bedrock:${REGION}:${ACCOUNT}:#g" \
  -e "s#arn:aws:bedrock:REGION::#arn:aws:bedrock:${REGION}::#g" \
  -E -e "s#(arn:aws:[a-z0-9-]+:[a-z0-9-]*):(ACCOUNT_ID|ACCOUNT):#\\1:${ACCOUNT}:#g" \
  -e "$GUARDRAIL_SED" \
  -e "$IMAGE_SED" \
  -e "$TAG_SED" \
  "$FILE" | route_exposed
# The -E line is the general form, for an ARN whose Region is LITERAL (a cross-region inference
# profile names its Regions explicitly) and for the bare ACCOUNT spelling. Without it, both are
# left in place AND not reported, because the leftover check below matches neither: an Agent is
# applied with a model ARN and a guardrail ARN naming the account "ACCOUNT_ID".

# Anything left is yours. Reported on stderr so stdout stays pipeable into kubectl.
#
# Comment lines are excluded: several of them say the word REPLACE while EXPLAINING a field this
# script fills, so reporting them tells you to edit something already done.
left="$(grep -nE "REPLACE|NOT_SET|ACCOUNT_ID|:ACCOUNT:|ACCOUNT\\.dkr" <(sed \
  -e "s#OIDC_ISSUER_NOT_SET##g;s#CLUSTER_NOT_SET##g;s#REPLACE_ECR_URL##g" \
  -e "s#ACCOUNT\.dkr\.ecr\.REGION\.amazonaws\.com##g" \
  -e "s#arn:aws:bedrock:REGION:ACCOUNT_ID:##g" \
  -E -e "s#arn:aws:[a-z0-9-]+:[a-z0-9-]*:(ACCOUNT_ID|ACCOUNT):##g" -e "/guardrailArn:.*guardrail\/REPLACE/d" "$FILE") \
  | grep -vE ':\s*#' || true)"
if [[ -n "$left" ]]; then
  {
    echo
    echo "Still yours to fill in $FILE -- this script cannot know them:"
    printf '%s\n' "$left" | sed 's/^/  /'
  } >&2
fi
