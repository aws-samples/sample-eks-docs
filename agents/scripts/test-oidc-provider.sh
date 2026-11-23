#!/usr/bin/env bash
#
# A throwaway external OpenID Connect provider, for exercising ingress_idp = "oidc" (federated)
# and "oidc-direct" without a corporate identity provider.
#
#   ./scripts/test-oidc-provider.sh create --name agents-test --region us-west-2 [--env file]
#       -> prints an ingress_oidc block for your tfvars, and writes the test person's
#          credentials to the env file (mode 600) as INGRESS_USER / _PASSWORD / _EXPECT
#   ./scripts/test-oidc-provider.sh callbacks --name agents-test --region us-west-2 --root terraform/<path>
#       -> registers the ingress redirect URIs (the idp_redirect_uris output) with the provider
#   ./scripts/test-oidc-provider.sh delete --name agents-test --region us-west-2 [--env file]
#
# WHY THIS EXISTS. Both OIDC modes need a provider OUTSIDE the ingress component's own pool: a
# second Cognito pool, a hosted-UI domain, a confidential app
# client, a user with a permanent password, the client secret in Secrets Manager, then the redirect
# URIs once ingress existed. That is a test fixture, so it is a script. The provider is a
# Cognito user pool acting as a generic OIDC issuer -- ingress does not know or care.
#
# Everything it creates is named <name>-ext-idp and tagged eks-agents/test-fixture=<name>, and
# `delete` removes all of it. The client secret goes to Secrets Manager (<name>/ext-idp-client-secret)
# because that is what ingress_oidc.client_secret_arn reads; it is never printed.
set -euo pipefail
ACTION="${1:-}"; shift || true
NAME="" REGION="${AWS_REGION:-}" ENV_FILE="./ingress-test-user.env" TF_ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --env) ENV_FILE="$2"; shift 2 ;;
    --root) TF_ROOT="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$NAME" && -n "$REGION" && "$ACTION" =~ ^(create|callbacks|delete)$ ]] || {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

POOL_NAME="$NAME-ext-idp"
DOMAIN="$(printf '%s' "$NAME-ext-idp" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | cut -c1-63)"
SECRET_ID="$NAME/ext-idp-client-secret"
aws_() { aws --region "$REGION" "$@"; }
pool_id() { aws_ cognito-idp list-user-pools --max-results 60 --query "UserPools[?Name=='$POOL_NAME'].Id | [0]" --output text; }

case "$ACTION" in
create)
  [[ "$(pool_id)" == None ]] || { echo "pool $POOL_NAME already exists ($(pool_id)); delete it first" >&2; exit 2; }
  POOL="$(aws_ cognito-idp create-user-pool --pool-name "$POOL_NAME" \
            --auto-verified-attributes email --username-attributes email \
            --admin-create-user-config AllowAdminCreateUserOnly=true \
            --user-pool-tags "eks-agents/test-fixture=$NAME" --query UserPool.Id --output text)"
  aws_ cognito-idp create-user-pool-domain --user-pool-id "$POOL" --domain "$DOMAIN" >/dev/null
  # Placeholder callback until ingress exists; `callbacks` replaces it.
  read -r CLIENT SECRET < <(aws_ cognito-idp create-user-pool-client --user-pool-id "$POOL" \
      --client-name "$NAME-ingress" --generate-secret \
      --allowed-o-auth-flows code --allowed-o-auth-flows-user-pool-client \
      --allowed-o-auth-scopes openid email profile --supported-identity-providers COGNITO \
      --callback-urls "https://localhost/oauth2/idpresponse" \
      --query 'UserPoolClient.[ClientId,ClientSecret]' --output text)
  IN="$(mktemp)"; chmod 600 "$IN"
  FDT_SECRET="$SECRET" python3 - "$SECRET_ID" "$NAME" > "$IN" <<'PY'
import json, os, sys
print(json.dumps({"Name": sys.argv[1], "SecretString": os.environ["FDT_SECRET"],
                  "Tags": [{"Key": "eks-agents/test-fixture", "Value": sys.argv[2]}]}))
PY
  SECRET_ARN="$(aws_ secretsmanager create-secret --cli-input-json "file://$IN" --query ARN --output text)"
  rm -f "$IN"; unset SECRET

  USER_EMAIL="signin-test-$(python3 -c 'import secrets; print(secrets.token_hex(3))')@example.com"
  PASS="$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("Aa1!"+"".join(secrets.choice(a) for _ in range(20)))')"
  aws_ cognito-idp admin-create-user --user-pool-id "$POOL" --username "$USER_EMAIL" \
    --user-attributes Name=email,Value="$USER_EMAIL" Name=email_verified,Value=true --message-action SUPPRESS >/dev/null
  IN="$(mktemp)"; chmod 600 "$IN"
  FDT_PASS="$PASS" python3 - "$POOL" "$USER_EMAIL" > "$IN" <<'PY'
import json, os, sys
print(json.dumps({"UserPoolId": sys.argv[1], "Username": sys.argv[2], "Password": os.environ["FDT_PASS"], "Permanent": True}))
PY
  aws_ cognito-idp admin-set-user-password --cli-input-json "file://$IN"; rm -f "$IN"
  umask 077
  printf "export INGRESS_USER='%s'\nexport INGRESS_PASSWORD='%s'\nexport INGRESS_EXPECT='%s'\n" \
    "$USER_EMAIL" "$PASS" "$USER_EMAIL" > "$ENV_FILE"
  ISS="https://cognito-idp.$REGION.amazonaws.com/$POOL"
  HOST="https://$DOMAIN.auth.$REGION.amazoncognito.com"
  cat <<EOF
# provider $POOL ($POOL_NAME); test person in $ENV_FILE
ingress_oidc = {
  issuer                 = "$ISS"
  authorization_endpoint = "$HOST/oauth2/authorize"
  token_endpoint         = "$HOST/oauth2/token"
  user_info_endpoint     = "$HOST/oauth2/userInfo"
  jwks_uri               = "$ISS/.well-known/jwks.json"
  client_id              = "$CLIENT"
  client_secret_arn      = "$SECRET_ARN"
}
EOF
  ;;
callbacks)
  [[ -n "$TF_ROOT" ]] || { echo "--root is required" >&2; exit 2; }
  POOL="$(pool_id)"; [[ "$POOL" != None ]] || { echo "no pool $POOL_NAME" >&2; exit 2; }
  CLIENT="$(aws_ cognito-idp list-user-pool-clients --user-pool-id "$POOL" --query 'UserPoolClients[0].ClientId' --output text)"
  # A while-read loop, not mapfile: macOS ships bash 3.2, which has none.
  URIS=()
  while IFS= read -r u; do [[ -n "$u" ]] && URIS+=("$u"); done < <(terraform -chdir="$TF_ROOT" output -json ingress \
    | python3 -c 'import json,sys; [print(u) for u in (json.load(sys.stdin) or {}).get("idp_redirect_uris", [])]')
  [[ ${#URIS[@]} -gt 0 ]] || { echo "ingress reports no idp_redirect_uris: is ingress_idp oidc or oidc-direct?" >&2; exit 2; }
  # update-user-pool-client REPLACES every setting it is not given, so restate the OAuth ones.
  aws_ cognito-idp update-user-pool-client --user-pool-id "$POOL" --client-id "$CLIENT" \
    --allowed-o-auth-flows code --allowed-o-auth-flows-user-pool-client \
    --allowed-o-auth-scopes openid email profile --supported-identity-providers COGNITO \
    --callback-urls "${URIS[@]}" >/dev/null
  printf 'registered %s redirect URI(s) on %s:\n' "${#URIS[@]}" "$CLIENT"; printf '  %s\n' "${URIS[@]}"
  ;;
delete)
  POOL="$(pool_id)"
  if [[ "$POOL" != None ]]; then
    aws_ cognito-idp delete-user-pool-domain --user-pool-id "$POOL" --domain "$DOMAIN" 2>/dev/null || true
    aws_ cognito-idp delete-user-pool --user-pool-id "$POOL"
    echo "deleted pool $POOL"
  fi
  aws_ secretsmanager delete-secret --secret-id "$SECRET_ID" --force-delete-without-recovery >/dev/null 2>&1 \
    && echo "deleted secret $SECRET_ID" || true
  rm -f "$ENV_FILE"
  ;;
esac
