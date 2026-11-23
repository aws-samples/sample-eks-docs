#!/usr/bin/env bash
#
# Store a third-party credential where the egress gateway reads it, without the value touching
# shell history, a file, or Terraform state.
#
#   ./scripts/set-credential.sh --cluster <name> --region <region> token <key>
#   ./scripts/set-credential.sh --cluster <name> --region <region> oauth-client <key>
#   ./scripts/set-credential.sh --path aws-services --cluster <name> --region <region> token <key>
#   ./scripts/set-credential.sh --path aws-services --cluster <name> --region <region> oauth-client <key>
#
#   --path aws-services: the secrets AgentCore Identity's credential providers read, created if
#   absent. token -> <cluster>/agentcore/<key> as {"token": "..."} (api_key_providers.<key>:
#   secret_id = that name, json_key = "token"); oauth-client -> <cluster>/consent/<key>-oauth-client
#   as {"client_secret": "..."} (oauth2_providers.<key>.secret_id). No syncer: AgentCore reads them.
#
#   token <key>         a personal access token / API key for third_party_credentials.<key>.
#                       Written as {"token": "..."} to <cluster>/agentgateway/<key>, then the
#                       gateway's secrets syncer is restarted so the gateway picks it up.
#   oauth-client <key>  the OAuth client secret for oauth_consent.<key> (a GitHub App's, say).
#                       Written bare to <cluster>/consent/<key>-oauth-client, created if absent;
#                       prints the ARN to set as oauth_consent.<key>.client_secret_arn.
#
# Both read the value from a hidden prompt (or stdin when not a terminal). Both check its shape for
# the providers this knows -- GitHub's token prefixes and its 40-hex client secrets -- because the
# two are easy to swap, and a client secret stored as a token fails only at the first call, as a 401
# from GitHub that looks like the gateway's fault.
#
# The syncer restart needs kubectl against the cluster (the bastion, on a private endpoint). Without
# it the value is stored and the command to finish is printed.
set -uo pipefail
CLUSTER="" REGION="${AWS_REGION:-}" PATH_NAME=open-source
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster) CLUSTER="$2"; shift 2 ;;
    --region)  REGION="$2"; shift 2 ;;
    --path)    PATH_NAME="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done
KIND="${1:-}" KEY="${2:-}"
[[ -n "$CLUSTER" && -n "$REGION" && -n "$KIND" && -n "$KEY" ]] || { sed -n '5,6p' "$0" | sed 's/^# //'; exit 2; }
# THE VALUE IS NEVER AN ARGUMENT. The last argument is the key's NAME (github, githubpat); the value
# is asked for at a hidden prompt. A token passed here is in the shell's history already, so say so.
case "$KEY" in github_pat_*|ghp_*|gho_*|ghu_*|ghs_*|ghr_*|xox?-*)
  echo "refused: the last argument is the key NAME (e.g. github), and that looks like the token itself." >&2
  echo "  It is now in your shell history: remove that entry, or regenerate the token." >&2
  echo "  Run again with the name; the value is asked for at a hidden prompt." >&2
  exit 2 ;;
esac
[[ "$KEY" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "the last argument is the key NAME, lowercase letters, digits and dashes (e.g. github); the value is asked for at a hidden prompt" >&2; exit 2; }

if [[ -t 0 ]]; then read -r -s -p "value for $KIND $KEY (hidden): " VALUE; echo; else read -r VALUE; fi
VALUE="${VALUE//[$'\r\n ']/}"
[[ -n "$VALUE" ]] || { echo "empty value" >&2; exit 2; }

# The value goes to the CLI through a private temporary file, written byte-exact: an argument would
# show in `ps`, and the CLI's stdin path stores a trailing newline, which inside a token is
# a broken Authorization header.
umask 077
TMPV="$(mktemp "${TMPDIR:-/tmp}/set-credential.XXXXXX")"
trap 'rm -f "$TMPV"' EXIT
write_value() { python3 -c 'import sys; open(sys.argv[1], "w").write(sys.argv[2])' "$TMPV" "$1"; }

looks_client_secret() { [[ ${#1} -eq 40 && "$1" =~ ^[0-9a-f]+$ ]]; }
case "$KIND" in
  token)
    if looks_client_secret "$VALUE"; then
      echo "refused: that is 40 hex characters, the shape of an OAuth/GitHub App CLIENT SECRET, not a token." >&2
      echo "  for oauth_consent use:  $0 --cluster $CLUSTER --region $REGION oauth-client $KEY" >&2
      exit 1
    fi
    case "$VALUE" in
      github_pat_*|ghp_*|ghs_*|ghu_*|xoxb-*|xoxp-*) ;;
      *) echo "note: not a GitHub or Slack token prefix; storing it as given" >&2 ;;
    esac
    if [[ "$PATH_NAME" == "aws-services" ]]; then
      SECRET="$CLUSTER/agentcore/$KEY"
      write_value "$(python3 -c 'import json,sys; print(json.dumps({"token": sys.argv[1]}), end="")' "$VALUE")"
      if aws secretsmanager describe-secret --region "$REGION" --secret-id "$SECRET" >/dev/null 2>&1; then
        aws secretsmanager put-secret-value --region "$REGION" --secret-id "$SECRET" \
          --secret-string "file://$TMPV" --query VersionId --output text >/dev/null || exit 1
      else
        aws secretsmanager create-secret --region "$REGION" --name "$SECRET" \
          --description "API key for api_key_providers.$KEY on $CLUSTER (AgentCore Identity). Deleted by scripts/teardown.sh." \
          --secret-string "file://$TMPV" --query ARN --output text >/dev/null || exit 1
      fi
      echo "stored in $SECRET. Set:  api_key_providers.$KEY = { secret_id = \"$SECRET\", json_key = \"token\" }"
      exit 0
    fi
    SECRET="$CLUSTER/agentgateway/$KEY"
    aws secretsmanager describe-secret --region "$REGION" --secret-id "$SECRET" >/dev/null 2>&1 \
      || { echo "no secret $SECRET: declare third_party_credentials.$KEY and apply first" >&2; exit 1; }
    write_value "$(python3 -c 'import json,sys; print(json.dumps({"token": sys.argv[1]}), end="")' "$VALUE")"
    aws secretsmanager put-secret-value --region "$REGION" --secret-id "$SECRET" \
      --secret-string "file://$TMPV" --query VersionId --output text >/dev/null \
      && echo "stored in $SECRET" || exit 1
    if kubectl -n agentgateway-system get deploy platform-secrets-syncer >/dev/null 2>&1; then
      kubectl -n agentgateway-system rollout restart deploy/platform-secrets-syncer >/dev/null \
        && kubectl -n agentgateway-system rollout status deploy/platform-secrets-syncer --timeout=180s
    else
      echo "kubectl cannot reach the cluster from here. Finish from the bastion, or -- with no bastion --"
      echo "re-apply from this machine's current address (cluster_endpoint_public_access_cidrs), then:"
      echo "  kubectl -n agentgateway-system rollout restart deploy/platform-secrets-syncer"
    fi
    ;;
  oauth-client)
    case "$VALUE" in github_pat_*|ghp_*|ghu_*|ghs_*)
      echo "refused: that is a GitHub TOKEN, not an OAuth client secret (Generate a new client secret on the app's page)" >&2; exit 1 ;;
    esac
    SECRET="$CLUSTER/consent/$KEY-oauth-client"
    # AgentCore Identity's GitHub provider reads the secret as JSON with a client_secret key.
    [[ "$PATH_NAME" == "aws-services" ]] && VALUE="$(python3 -c 'import json,sys; print(json.dumps({"client_secret": sys.argv[1]}), end="")' "$VALUE")"
    if aws secretsmanager describe-secret --region "$REGION" --secret-id "$SECRET" >/dev/null 2>&1; then
      write_value "$VALUE"
      aws secretsmanager put-secret-value --region "$REGION" --secret-id "$SECRET" \
        --secret-string "file://$TMPV" --query VersionId --output text >/dev/null || exit 1
    else
      write_value "$VALUE"
      aws secretsmanager create-secret --region "$REGION" --name "$SECRET" \
        --description "OAuth client secret for oauth_consent.$KEY on $CLUSTER. Deleted by scripts/teardown.sh." \
        --secret-string "file://$TMPV" --query ARN --output text >/dev/null || exit 1
    fi
    echo "stored in $SECRET. Set:"
    echo "  oauth_consent.$KEY.client_secret_arn = \"$(aws secretsmanager describe-secret --region "$REGION" --secret-id "$SECRET" --query ARN --output text)\""
    ;;
  *) echo "kind must be token or oauth-client" >&2; exit 2 ;;
esac
