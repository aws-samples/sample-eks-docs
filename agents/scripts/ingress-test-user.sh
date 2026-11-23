#!/usr/bin/env bash
#
# Create or delete a throwaway person in the ingress Cognito pool, for exercise.sh's signin phase.
#
#   ./scripts/ingress-test-user.sh create --root terraform/open-source   # writes ./ingress-test-user.env
#   source ./ingress-test-user.env                                      # INGRESS_USER, _PASSWORD, _EXPECT
#   ./scripts/ingress-test-user.sh delete --root terraform/open-source
#
# WHY THIS EXISTS. Proving the sign-in needs a person in the pool: admin-create-user, a generated
# password and a second call to make it permanent. That is a test fixture, not an operator
# decision, so it is a script -- for the pool's OWN users only
# (ingress_idp = "cognito"). With "oidc" or "oidc-direct" the person lives in your provider, and
# this script refuses rather than creating a pool user nobody can sign in as.
#
# The user is named eks-agents-signin-test-<random>, has a random 24-character password, and is
# deleted by `delete`. The env file is mode 600 and gitignored; the password never appears on a
# command line.
set -euo pipefail
ACTION="${1:-}"; shift || true
TF_ROOT=""
ENV_FILE="./ingress-test-user.env"
# --var-suffix _2 names a second person INGRESS_USER_2 / _PASSWORD_2 / _EXPECT_2, for the people phase.
SUFFIX=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) TF_ROOT="$2"; shift 2 ;;
    --env)  ENV_FILE="$2"; shift 2 ;;
    --var-suffix) SUFFIX="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ "$ACTION" == create || "$ACTION" == delete ]] && [[ -n "$TF_ROOT" ]] || {
  echo "usage: $0 create|delete --root <terraform root> [--env file] [--var-suffix _2]" >&2; exit 2; }

POOL="$(terraform -chdir="$TF_ROOT" output -json ingress | python3 -c 'import json,sys; print((json.load(sys.stdin) or {}).get("cognito_user_pool_id",""))')"
[[ -n "$POOL" ]] || { echo "no ingress with a Cognito pool in $TF_ROOT's outputs" >&2; exit 2; }
REGION="${POOL%%_*}"

if [[ "$ACTION" == delete ]]; then
  [[ -f "$ENV_FILE" ]] || { echo "no $ENV_FILE; nothing recorded to delete" >&2; exit 0; }
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  v="INGRESS_USER$SUFFIX"
  aws cognito-idp admin-delete-user --region "$REGION" --user-pool-id "$POOL" --username "${!v}"
  rm -f "$ENV_FILE"
  echo "deleted ${!v} from $POOL"
  exit 0
fi

# Providers a person signs in through. NOT the pool's `eks-agents` provider: with
# person_access_delegated_token that is the cluster's issuer, registered for the gateway's token
# exchange, and no person signs in through it (terraform/modules/person-delegation).
IDPS="$(aws cognito-idp list-identity-providers --region "$REGION" --user-pool-id "$POOL" \
  --query "length(Providers[?ProviderName!='eks-agents'])" --output text)"
if [[ "$IDPS" != 0 ]]; then
  echo "pool $POOL federates a provider (ingress_idp is oidc): a person signs in there, not as a pool user." >&2
  echo "Create the test person in that provider and set INGRESS_USER / INGRESS_PASSWORD yourself." >&2
  exit 2
fi

USER="eks-agents-signin-test-$(python3 -c 'import secrets; print(secrets.token_hex(4))')"
EMAIL="$USER@example.com"
PASS="$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("Aa1!"+"".join(secrets.choice(a) for _ in range(20)))')"
aws cognito-idp admin-create-user --region "$REGION" --user-pool-id "$POOL" --username "$USER" \
  --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
  --message-action SUPPRESS >/dev/null
# Permanent, or the first sign-in is a forced password change the hosted UI handles and a test does not.
IN="$(mktemp)"; chmod 600 "$IN"
FDT_PASS="$PASS" python3 - "$POOL" "$USER" > "$IN" <<'PY2'
import json, os, sys
print(json.dumps({"UserPoolId": sys.argv[1], "Username": sys.argv[2], "Password": os.environ["FDT_PASS"], "Permanent": True}))
PY2
aws cognito-idp admin-set-user-password --region "$REGION" --cli-input-json "file://$IN"
rm -f "$IN"
umask 077
cat > "$ENV_FILE" <<EOF
export INGRESS_USER$SUFFIX='$USER'
export INGRESS_PASSWORD$SUFFIX='$PASS'
export INGRESS_EXPECT$SUFFIX='$EMAIL'
EOF
echo "created $USER in $POOL; credentials in $ENV_FILE (mode 600)"
