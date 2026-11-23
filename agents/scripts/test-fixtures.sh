#!/usr/bin/env bash
#
# The account-side fixtures an aws-services test run needs and the platform deliberately does not
# create, because in a real deployment they are the team's own.
#
#   ./scripts/test-fixtures.sh create --name agents-test --region us-west-2   # prints tfvars lines
#   ./scripts/test-fixtures.sh delete --name agents-test --region us-west-2
#
#   - the Lambda tool backend in agents/mcp-lambda, as <name>-mcp-tools, with its execution role
#     -> lambda_targets.ordertools
#   - a Secrets Manager secret <name>/internal-search-api-key holding a placeholder key
#     -> api_key_providers.internal-search, which the public MCP and OpenAPI targets present
#
# WHY THIS EXISTS. They are test fixtures, not operator decisions, so they are a script rather than
# steps to follow from the READMEs. Everything is tagged eks-agents/test-fixture=<name>.
# For the external OIDC provider and the GitOps mirror, see test-oidc-provider.sh and
# gitops-mirror.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION="${1:-}"; shift || true
NAME="" REGION="${AWS_REGION:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$NAME" && -n "$REGION" && "$ACTION" =~ ^(create|delete)$ ]] || { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
aws_() { aws --region "$REGION" "$@"; }
FN="$NAME-mcp-tools"
ROLE="$NAME-mcp-tools"
SECRET="$NAME/internal-search-api-key"
TAG="eks-agents/test-fixture=$NAME"

case "$ACTION" in
create)
  ACCT="$(aws_ sts get-caller-identity --query Account --output text)"
  if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$ROLE" --tags "Key=eks-agents/test-fixture,Value=$NAME" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    aws iam attach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
    sleep 10   # a new role is not assumable by Lambda for a few seconds
  fi
  ZIP="$(mktemp -d)/fn.zip"
  (cd "$ROOT/apps/mcp-lambda" && zip -q "$ZIP" handler.py)
  if aws_ lambda get-function --function-name "$FN" >/dev/null 2>&1; then
    aws_ lambda update-function-code --function-name "$FN" --zip-file "fileb://$ZIP" >/dev/null
  else
    for _ in 1 2 3 4 5 6; do
      aws_ lambda create-function --function-name "$FN" --runtime python3.13 --handler handler.handler \
        --zip-file "fileb://$ZIP" --role "arn:aws:iam::$ACCT:role/$ROLE" --tags "eks-agents/test-fixture=$NAME" \
        >/dev/null 2>&1 && break
      sleep 10
    done
  fi
  rm -rf "$(dirname "$ZIP")"
  FN_ARN="$(aws_ lambda get-function --function-name "$FN" --query Configuration.FunctionArn --output text)"
  aws_ secretsmanager describe-secret --secret-id "$SECRET" >/dev/null 2>&1 || \
    aws_ secretsmanager create-secret --name "$SECRET" --tags "Key=eks-agents/test-fixture,Value=$NAME" \
      --secret-string "{\"api_key\":\"placeholder-$(python3 -c 'import secrets; print(secrets.token_hex(8))')\"}" >/dev/null
  cat <<EOF
api_key_providers = {
  internal-search = { secret_id = "$SECRET", json_key = "api_key" }
}
lambda_targets = {
  ordertools = {
    description  = "Order lookup and clock, as MCP tools."
    function_arn = "$FN_ARN"
    tool_schema = [
      {
        name        = "lookup_order"
        description = "Look up an order's status, items and ETA by order id."
        properties  = [{ name = "order_id", type = "string", description = "The order id, e.g. ORD-12345.", required = true }]
      },
      { name = "get_time", description = "The current UTC time." },
    ]
  }
}
EOF
  ;;
delete)
  aws_ lambda delete-function --function-name "$FN" 2>/dev/null && echo "deleted function $FN" || true
  aws_ logs delete-log-group --log-group-name "/aws/lambda/$FN" 2>/dev/null || true
  if aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    aws iam detach-role-policy --role-name "$ROLE" --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole || true
    aws iam delete-role --role-name "$ROLE" && echo "deleted role $ROLE"
  fi
  aws_ secretsmanager delete-secret --secret-id "$SECRET" --force-delete-without-recovery >/dev/null 2>&1 \
    && echo "deleted secret $SECRET" || true
  ;;
esac
