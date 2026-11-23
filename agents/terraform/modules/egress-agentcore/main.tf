# The AWS-managed egress path: AgentCore Gateway, its targets, its credential providers and a
# policy engine.
#
# Read this before adopting it. AgentCore Gateway brokers credentials and searches a tool catalogue
# in a managed service, with no proxy fleet to run, scale or upgrade. Nothing in AWS forces an
# agent's traffic to reach it. So on this path:
#
#   - The gateway is the tool and credential broker an agent calls. It is reached because the agent
#     is configured to reach it, or because the mesh redirects it there.
#   - The in-cluster egress boundary is still the ClusterNetworkPolicy in gitops/base/templates: DNS
#     and the gateway endpoint, nothing else. That is what makes the gateway unavoidable here, and
#     it refuses on its own whatever the agent attempts.
#   - Istio ambient capture, in gitops/platform/aws-services/, is the layer that makes arrival
#     enforced rather than agreed, for a team that wants an unmodified agent to run under the same
#     controls as one it governs.
#
# The agents page of the EKS User Guide sets out what each gateway can enforce. The short version:
# this one brokers a consented credential and searches a large tool catalogue; the self-managed one
# does token budgets, prompt and response checks, argument-level tool checks and response masking
# in the cluster's own data path. They are not swappable without changing what a platform team can
# enforce.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {

  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  tags = merge(var.tags, {
    "app.kubernetes.io/part-of" = "eks-agents-paved-paths"
    ManagedBy                   = "terraform/modules/egress-agentcore"
  })

  # Three different name rules across the AgentCore resources this module creates, which is worth
  # naming once here rather than discovering one apply at a time.
  #   gateway        alphanumerics and single dashes, no underscores
  #   policy engine  letters, digits and underscores, no dashes
  #   policy         the same as the policy engine
  gateway_name = "${var.name}-agents"

  # The gateway's workload identity, which AgentCore creates in the account's default directory
  # under the gateway's name, and the default token vault that holds the credential providers.
  token_vault_arn = "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:token-vault/default"
  gateway_workload_identity_arns = [
    "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default",
    "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default/workload-identity/${local.gateway_name}-*",
  ]
  underscore_name = replace("${var.name}_agents", "-", "_")

  # POLICY NAMES ARE UNIQUE IN THE ACCOUNT AND REGION, not within a policy engine (CreatePolicy:
  # "Must be unique within the account"). A bare name such as forbid_unlisted_principals would make
  # a second stack's apply fail with "Policy with the same name already exists" while its own engine
  # is empty, so every name carries this stack's name. A name past the 48-character limit keeps its
  # first 39 characters and gains a hash of the whole, so two long names stay distinct.
  policy_prefix = "${can(regex("^[A-Za-z]", var.name)) ? "" : "p_"}${replace(var.name, "-", "_")}_"
  policy_names = { for k in distinct(concat(keys(var.cedar_policies), keys(var.dogwood_policies), keys(var.guardrail_policies))) :
    k => (length("${local.policy_prefix}${replace(k, "-", "_")}") <= 48
      ? "${local.policy_prefix}${replace(k, "-", "_")}"
    : "${substr("${local.policy_prefix}${replace(k, "-", "_")}", 0, 39)}_${substr(sha1("${local.policy_prefix}${k}"), 0, 8)}")
  }
}

# ---------------------------------------------------------------------------
# The gateway's execution role
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "gateway_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    # Confused-deputy guard: this role may only be assumed on behalf of AgentCore resources in
    # this account. Without it, an AgentCore resource in any account could induce the service to
    # assume this role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    # NO aws:SourceArn CONDITION, and the reason is specific rather than an oversight.
    #
    # Creating an inference target makes AgentCore discover the target's models, and that call
    # arrives from a service-owned role in an AWS-managed account rather than as this service
    # principal with the gateway as its source. It carries no aws:SourceArn, and an ArnLike test
    # against a missing key does not match, so the assume is denied and the target goes to FAILED
    # with:
    #
    #   Failed to assume the gateway execution role to discover models for target <id>.
    #   Confirm the role's trust policy grants sts:AssumeRole to bedrock-agentcore.
    #   User: arn:aws:sts::<aws-account>:assumed-role/<service-owned role>/...
    #   is not authorized to perform: sts:AssumeRole
    #
    # The gateway itself is created successfully first, so this surfaces only once a target is
    # added -- and terraform apply fails partway, leaving a gateway with a FAILED target.
    #
    # aws:SourceAccount still bounds this to AgentCore acting for this account, which is the
    # control that matters for a confused deputy. Add a SourceArn condition back only if you have
    # confirmed every AgentCore call path sends one.
  }
}

resource "aws_iam_role" "gateway" {
  name               = "${var.name}-agentcore-gateway"
  assume_role_policy = data.aws_iam_policy_document.gateway_assume_role.json
  description        = "Execution role for AgentCore Gateway ${var.name}. Reaches the gateway's own targets and the credential providers, not an agent's data."
  tags               = local.tags
}

data "aws_iam_policy_document" "gateway" {
  dynamic "statement" {
    for_each = length(var.lambda_target_arns) > 0 ? [1] : []

    content {
      sid       = "InvokeLambdaTargets"
      effect    = "Allow"
      actions   = ["lambda:InvokeFunction"]
      resources = var.lambda_target_arns
    }
  }

  # Reading the credential providers is how the gateway attaches a caller's credential on the way
  # out. The agent never holds it, which is the property this path is bought for.
  #
  # Scoped to this gateway's own workload identity and to the providers this module creates, by
  # name, in the account's default token vault. Each Get on a provider also authorizes the token
  # vault, the workload identity directory and the workload identity, so all of them are named. A
  # provider created outside this module isn't readable by the gateway until it is named here.
  statement {
    sid    = "MintOwnWorkloadAccessToken"
    effect = "Allow"

    actions = [
      "bedrock-agentcore:GetWorkloadAccessToken",
      "bedrock-agentcore:GetWorkloadAccessTokenForJWT",
    ]

    resources = local.gateway_workload_identity_arns
  }

  dynamic "statement" {
    for_each = length(var.api_key_providers) > 0 ? [1] : []

    content {
      sid       = "ReadOwnApiKeyProviders"
      effect    = "Allow"
      actions   = ["bedrock-agentcore:GetResourceApiKey"]
      resources = concat(local.gateway_workload_identity_arns, [local.token_vault_arn], [for k in keys(var.api_key_providers) : "${local.token_vault_arn}/apikeycredentialprovider/${k}"])
    }
  }

  dynamic "statement" {
    for_each = length(var.oauth2_providers) > 0 ? [1] : []

    content {
      sid       = "ReadOwnOAuth2Providers"
      effect    = "Allow"
      actions   = ["bedrock-agentcore:GetResourceOauth2Token"]
      resources = concat(local.gateway_workload_identity_arns, [local.token_vault_arn], [for k in keys(var.oauth2_providers) : "${local.token_vault_arn}/oauth2credentialprovider/${k}"])
    }
  }

  # READING ITS OWN POLICY ENGINE, which CreateGateway validates before it will create anything.
  #
  # Without this the gateway cannot be created at all when a policy engine is attached -- not
  # "policies are not enforced", the whole resource fails:
  #
  #   ValidationException: Access denied while calling GetPolicyEngine on Policy Engine:
  #   arn:...:policy-engine/..._agents-xxxx with Gateway role: arn:...:role/...-agentcore-gateway.
  #   Confirm this role has bedrock-agentcore:GetPolicyEngine permissions and retry your request
  #
  # So without it, enable_policy_engine = true is unusable.
  #
  # Scoped to the engine this module creates rather than "*": the gateway has no business reading
  # another engine's policies, and the ARN is known here.

  # A TEMPORAL POLICY NEEDS ONE MORE GRANT, and it is not optional once a policy session is in play.
  #
  # Temporal policies are written in Dogwood, a strict superset of Cedar, and decide on what has
  # already happened in a session rather than on the current request alone. To do that the gateway
  # propagates the caller's session identity by minting a Workload Access Token, so its role needs
  # GetWorkloadAccessToken. Without it the tool call fails at the mint step with AccessDenied --
  # after the policy has been written, validated and attached, so it reads as a policy problem.
  dynamic "statement" {
    for_each = var.enable_policy_engine && var.enable_temporal_policies ? [1] : []

    content {
      sid    = "PolicySessionWorkloadIdentity"
      effect = "Allow"

      actions = ["bedrock-agentcore:GetWorkloadAccessToken"]

      resources = [
        "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default",
        "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:workload-identity-directory/default/workload-identity/${local.gateway_name}-*",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.enable_policy_engine ? [1] : []

    content {
      sid    = "UseOwnPolicyEngine"
      effect = "Allow"

      # ALL THREE ACTIONS, not two.
      #
      # These are checked at CreateGateway time, not at call time: the service assumes this role to
      # prove the engine is usable before it will create the gateway. Granting a subset, or scoping to the wrong object, fails
      # in a different way each time:
      #
      #   GetPolicyEngine missing     ValidationException: Access denied while calling
      #                               GetPolicyEngine on Policy Engine: ...
      #   AuthorizeAction missing     AccessDeniedException: ... not authorized to perform:
      #                               bedrock-agentcore:AuthorizeAction on resource:
      #                               arn:...:policy-engine/..._agents-xxxx
      #   AuthorizeAction scoped to   AccessDeniedException: ... on resource:
      #   the engine only             arn:...:gateway/<name>-xxxxxxxxxx
      #
      # That third line is the trap: AuthorizeAction is authorized against the GATEWAY, and the
      # gateway's ARN carries a service-generated suffix that does not exist until the gateway is
      # created. Scoping to the exact ARN is therefore circular, so this names the gateway by
      # prefix -- the name is set by this module, only the suffix is the service's.
      #
      # PartiallyAuthorizeActions is the one that lists which tools a caller may invoke, and
      # omitting it is the quietest of the failures. The service documentation is explicit
      # about the consequence: attaching a policy engine to an existing gateway returns an
      # InternalServerException, and every tool invocation is denied by default EVEN WITH permit
      # policies configured. In practice the attach can instead fail with "Access denied while
      # calling GetPolicyEngine", which names a grant that is present and sends you to re-check it.
      actions = [
        "bedrock-agentcore:GetPolicyEngine",
        "bedrock-agentcore:AuthorizeAction",
        "bedrock-agentcore:PartiallyAuthorizeActions",
      ]

      resources = [
        aws_bedrockagentcore_policy_engine.this[0].policy_engine_arn,
        "arn:${local.partition}:bedrock-agentcore:${local.region}:${local.account_id}:gateway/${local.gateway_name}-*",
      ]
    }
  }

  statement {
    sid     = "ReadCredentialSecrets"
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    # Two kinds of secret. `bedrock-agentcore*` is what AgentCore names a secret it creates and holds
    # itself. The providers in this module are EXTERNAL -- the key stays in the organization's own
    # secret -- so the gateway reads THAT secret at call time, and it is named whatever the operator
    # named it. With only the first pattern, every api_key-backed MCP server and OpenAPI target
    # answers tools/list and then fails each tools/call with "An internal error occurred"; the
    # gateway's own log says "Access denied when retrieving the provided secret".
    resources = concat(
      ["arn:${local.partition}:secretsmanager:${local.region}:${local.account_id}:secret:bedrock-agentcore*"],
      [for k, v in data.aws_secretsmanager_secret.external_credential : v.arn],
    )
  }

  dynamic "statement" {
    for_each = var.credential_kms_key_arn != null ? [1] : []

    content {
      sid       = "DecryptCredentialSecrets"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.credential_kms_key_arn]
    }
  }

  # THE GATEWAY'S OWN ENCRYPTION KEY, AND Encrypt IS THE ACTION THAT MATTERS.
  #
  # A customer-managed key is accepted at create whether or not this role can use it, and the first
  # operation that proves otherwise is a WRITE. Both an update and a DELETE encrypt, so a gateway
  # whose role cannot encrypt with its own key cannot be changed or removed:
  #
  #   ValidationException: Failed to encrypt data with the Gateway encryption key,
  #   User: arn:aws:sts::<acct>:assumed-role/<name>-agentcore-gateway/...
  #
  # With kms:Decrypt and kms:GenerateDataKey granted but not kms:Encrypt, DeleteGateway returns that
  # error and the gateway cannot be destroyed until the grant is added. Deleting the role before the
  # gateway produces the same dead end from the other direction, which is why scripts/teardown.sh
  # removes the gateway first.
  #
  # ReEncrypt* covers a key rotation re-wrapping what is already stored.
  dynamic "statement" {
    for_each = var.gateway_kms_key_arn != null ? [1] : []

    content {
      sid    = "UseGatewayEncryptionKey"
      effect = "Allow"

      actions = [
        "kms:Encrypt",
        "kms:Decrypt",
        "kms:GenerateDataKey",
        "kms:DescribeKey",
        "kms:ReEncryptFrom",
        "kms:ReEncryptTo",
      ]

      resources = [var.gateway_kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = length(var.inference_model_arns) > 0 ? [1] : []

    content {
      sid    = "InvokeModelsForAgentsAndToolSearch"
      effect = "Allow"

      # InvokeModel alone is not enough once this gateway fronts an inference target: the
      # OpenAI-compatible dialect lands on Converse, and a streamed response needs the stream
      # variant. ApplyGuardrail covers a caller that names a Bedrock guardrail on a passthrough
      # route. The gateway's own checks are guardrail_policies (InvokeGuardrailChecks, below).
      actions = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
        "bedrock:Converse",
        "bedrock:ConverseStream",
        "bedrock:ApplyGuardrail",
      ]

      resources = var.inference_model_arns
    }
  }

  # The bedrock-mantle connector talks to a DIFFERENT service namespace from bedrock:, and its
  # permissions are not implied by bedrock:InvokeModel.
  #
  # bedrock-mantle is the OpenAI-compatible surface the inference connector fronts. Creating the
  # target makes the gateway list the provider's models, which is bedrock-mantle:ListModels against
  # a project resource -- not an action on a model ARN. Without it the target reaches FAILED with:
  #
  #   Inference list-models call to https://bedrock-mantle.<region>.api.aws/v1/models failed with
  #   HTTP 403: not authorized to perform: bedrock-mantle:ListModels on resource:
  #   arn:aws:bedrock-mantle:<region>:<account>:project/default
  #
  # Scoped to this account's projects rather than "*", so the grant stays bounded.
  dynamic "statement" {
    for_each = length([for t in var.inference_targets : t if startswith(t.connector_id, "bedrock-mantle")]) > 0 ? [1] : []

    content {
      sid    = "UseBedrockMantleForInference"
      effect = "Allow"

      # Both actions are required: target creation needs ListModels, and each completion needs
      # CreateInference. The chat-completions,
      # responses and messages shapes all land on CreateInference -- there is no per-shape action.
      actions = [
        "bedrock-mantle:ListModels",
        "bedrock-mantle:CreateInference",
      ]

      resources = [
        "arn:${local.partition}:bedrock-mantle:${local.region}:${local.account_id}:project/*",
      ]
    }
  }

  # The guardrail checks AgentCore Policy runs for guardrail_policies. It calls Bedrock Guardrails
  # with forward access session credentials derived from this role, so the permission belongs here.
  # InvokeGuardrailChecks takes its checks inline and names no guardrail resource, so it has no
  # resource to scope to.
  dynamic "statement" {
    for_each = var.enable_policy_engine && length(var.guardrail_policies) > 0 ? [1] : []

    content {
      sid       = "RunPolicyGuardrailChecks"
      effect    = "Allow"
      actions   = ["bedrock:InvokeGuardrailChecks"]
      resources = ["*"]
    }
  }

  statement {
    sid       = "NeverAlterIdentity"
    effect    = "Deny"
    actions   = ["iam:*", "eks:*", "organizations:*"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "gateway" {
  name   = "agentcore-gateway"
  role   = aws_iam_role.gateway.id
  policy = data.aws_iam_policy_document.gateway.json
}

# ---------------------------------------------------------------------------
# Policy engine
# ---------------------------------------------------------------------------

# AgentCore Policy is the authoring surface on this path, in place of AgentgatewayPolicy on the
# other one. It is Cedar. The agents-gateway page of the EKS User Guide covers both.
resource "aws_bedrockagentcore_policy_engine" "this" {
  count = var.enable_policy_engine ? 1 : 0

  name               = local.underscore_name
  description        = "Cedar policy engine for agents on cluster ${var.cluster_name}."
  encryption_key_arn = var.policy_kms_key_arn

  tags = local.tags
}

resource "aws_bedrockagentcore_policy" "this" {
  for_each = var.enable_policy_engine ? var.cedar_policies : {}

  policy_engine_id = aws_bedrockagentcore_policy_engine.this[0].policy_engine_id

  # AgentCore policy names take letters, digits and underscores only, so a map key written in
  # kebab-case is converted here rather than constraining how the input is written, and each is
  # prefixed with this stack's name (local.policy_names).
  name        = local.policy_names[each.key]
  description = each.value.description

  # FAIL_ON_ANY_FINDINGS, so a policy that does not parse or references an unknown entity fails at
  # apply rather than at the first request it was meant to refuse. IGNORE_ALL_FINDINGS would create
  # the policy anyway, which is the worst outcome available: an enforcement point holding a rule
  # that silently matches nothing.
  validation_mode = coalesce(each.value.validation_mode, var.policy_validation_mode)

  definition {
    cedar {
      # {{gateway_arn}} IS SUBSTITUTED HERE, and that substitution is what makes a correct policy
      # writable at all.
      #
      # Cedar requires a SPECIFIC gateway ARN whenever a policy names specific actions -- a type
      # check (`resource is AgentCore::Gateway`) is only allowed for policies covering any action.
      # The gateway's ARN carries a service-generated suffix that does not exist until the gateway
      # is created, so a statement cannot be written with it in advance.
      #
      # That is not a circular dependency. The policy is a SEPARATE resource from the gateway: only the gateway
      # depends on the engine, so the order engine -> gateway -> policy is acyclic and a policy can
      # reference the finished gateway. The token keeps the statements in Git free of any value that
      # differs per deployment, which is the same reason terraform-values.yaml exists.
      statement = replace(each.value.statement, "{{gateway_arn}}", aws_bedrockagentcore_gateway.this.gateway_arn)
    }
  }

  # EVERY TARGET FIRST. An action name in a policy is validated against the gateway's LIVE tool
  # schema, so `action in AgentCore::Action::"<target>"` is only recognized once that target exists.
  # Referencing the gateway alone makes the policy and the targets independent in the graph, and
  # terraform then creates them concurrently -- which fails the policy about half the time with a
  # message that reads like a typo rather than a race:
  #
  #   unrecognized action AgentCore::Action::"ordertools" ... did you mean
  #   AgentCore::Action::"bedrock"?
  #
  # Without the dependency, the policy fails CREATE_FAILED while the target it names reaches READY
  # moments later, so a re-apply with nothing changed succeeds. Named here rather than left to a
  # re-apply, because a policy that is missing is a tool call that is refused.
  depends_on = [
    aws_bedrockagentcore_gateway_target.inference,
    aws_bedrockagentcore_gateway_target.lambda,
    aws_bedrockagentcore_gateway_target.mcp_server,
    aws_bedrockagentcore_gateway_target.open_api,
  ]
}

# TEMPORAL POLICIES, applied through the CLI because the provider cannot. aws_bedrockagentcore_policy
# exposes only definition.cedar, and a temporal statement there is rejected (`unexpected token
# 'temporal'`); the service takes it through definition.policy. Left as an output for a platform
# team to apply by hand, each would be a policy in Git that nothing enforced. So each one is
# created on apply, waited on until ACTIVE -- the service accepts some invalid statements and then
# fails them asynchronously, which is the case worth failing the apply for -- replaced when its
# statement or mode changes, and deleted on destroy. Needs the aws CLI on the host running terraform.
# The guardrail policies take the same path, ACTIVE, with IGNORE_ALL_FINDINGS (see guardrail_policies).
locals {
  cli_policies = merge(
    { for k, v in var.dogwood_policies : k => merge(v, { validation = "FAIL_ON_ANY_FINDINGS", enforcement = var.dogwood_enforcement_mode }) },
    { for k, v in var.guardrail_policies : k => merge(v, { validation = "IGNORE_ALL_FINDINGS", enforcement = "ACTIVE" }) },
  )
}

resource "terraform_data" "dogwood_policy" {
  for_each = var.enable_policy_engine ? local.cli_policies : {}

  triggers_replace = {
    engine    = aws_bedrockagentcore_policy_engine.this[0].policy_engine_id
    name      = local.policy_names[each.key]
    region    = local.region
    mode      = each.value.enforcement
    statement = replace(each.value.statement, "{{gateway_arn}}", aws_bedrockagentcore_gateway.this.gateway_arn)
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      ENGINE    = self.triggers_replace.engine
      NAME      = self.triggers_replace.name
      REGION    = self.triggers_replace.region
      MODE      = self.triggers_replace.mode
      STATEMENT = self.triggers_replace.statement
      DESC      = each.value.description
      VALIDATE  = each.value.validation
    }
    command = <<-SH
      set -euo pipefail
      def="$(python3 -c 'import json,os; print(json.dumps({"policy": {"statement": os.environ["STATEMENT"]}}))')"
      id="$(aws bedrock-agentcore-control create-policy --region "$REGION" --policy-engine-id "$ENGINE"               --name "$NAME" --description "$DESC" --validation-mode "$VALIDATE"               --enforcement-mode "$MODE" --definition "$def" --query policyId --output text)"
      for _ in $(seq 1 60); do
        st="$(aws bedrock-agentcore-control get-policy --region "$REGION" --policy-engine-id "$ENGINE"                 --policy-id "$id" --query status --output text)"
        case "$st" in
          ACTIVE) echo "policy $NAME ($id) ACTIVE, $MODE"; exit 0 ;;
          *FAILED*) aws bedrock-agentcore-control get-policy --region "$REGION" --policy-engine-id "$ENGINE"                       --policy-id "$id" --query statusReasons --output json >&2; exit 1 ;;
        esac
        sleep 5
      done
      echo "policy $NAME ($id) still $st after 300s" >&2; exit 1
    SH
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    environment = {
      ENGINE = self.triggers_replace.engine
      NAME   = self.triggers_replace.name
      REGION = self.triggers_replace.region
    }
    # By name, because the id is not known at plan time. A policy already gone is not an error.
    command = <<-SH
      id="$(aws bedrock-agentcore-control list-policies --region "$REGION" --policy-engine-id "$ENGINE" \
              --query "policies[?name=='$NAME'].policyId | [0]" --output text 2>/dev/null || true)"
      [ -z "$id" ] || [ "$id" = None ] && exit 0
      aws bedrock-agentcore-control delete-policy --region "$REGION" --policy-engine-id "$ENGINE" --policy-id "$id"
      # The delete is asynchronous, and a replacement creates the new policy under the same name
      # right after this returns, which the service refuses while the old one still exists. Wait
      # until it is gone.
      for _ in $(seq 1 60); do
        left="$(aws bedrock-agentcore-control list-policies --region "$REGION" --policy-engine-id "$ENGINE" \
                  --query "policies[?name=='$NAME'].policyId | [0]" --output text 2>/dev/null || true)"
        [ -z "$left" ] || [ "$left" = None ] && exit 0
        sleep 5
      done
      echo "policy $NAME ($id) still present 300s after delete" >&2; exit 1
    SH
  }

  # After the Cedar policies and every target, for the same reason they wait on the targets.
  depends_on = [aws_bedrockagentcore_policy.this]
}

# ---------------------------------------------------------------------------
# The gateway
# ---------------------------------------------------------------------------

resource "aws_bedrockagentcore_gateway" "this" {
  # A gateway name takes alphanumerics and single dashes, unlike the policy and memory names next
  # to it, which take underscores and no dashes. The three rules differ; local.* holds each form.
  name          = local.gateway_name
  description   = "Tool and credential broker for agents on cluster ${var.cluster_name}."
  role_arn      = aws_iam_role.gateway.arn
  protocol_type = "MCP"

  # CUSTOM_JWT. The gateway decides which callers may invoke it on a token, and that token is the
  # agent's own projected service account token, validated against the cluster's OIDC
  # issuer. That is how per-agent routing and policy work with no mesh and no certificate authority
  # to run.
  authorizer_type = "CUSTOM_JWT"

  authorizer_configuration {
    custom_jwt_authorizer {
      discovery_url = "${var.oidc_issuer_url}/.well-known/openid-configuration"

      allowed_audience = var.allowed_audiences

      # A real OAuth client_id, for a caller that has one. null rather than [] when there is none:
      # the API rejects an empty list with "Member must have length greater than or equal to 1",
      # so the attribute has to be absent rather than present and empty.
      allowed_clients = length(var.allowed_oauth_client_ids) > 0 ? var.allowed_oauth_client_ids : null

      # PER-AGENT SCOPING GOES ON `sub`, NOT ON allowed_clients.
      #
      # allowed_clients is validated against the token's `client_id` claim, which an OAuth
      # application has and a Kubernetes projected service account token does not. Setting it to a
      # service account subject therefore matches nothing, and the gateway refuses EVERY request on
      # EVERY path with:
      #
      #   403 insufficient_scope - The request requires higher privileges than provided by the
      #   access token
      #
      # which reads like a missing scope rather than a claim that was never going to match.
      # It is identical on /mcp and /inference/v1, with a token the cluster issued and the gateway
      # READY.
      #
      # A service account token carries `sub` as system:serviceaccount:<namespace>:<name>, so that
      # is what identifies an agent. Matching it one subject at a time keeps the separation the
      # audience alone does not give: a namespace prefix would admit any service account a tenant
      # creates in that namespace.
      # ONE CLAIM PER SUBJECT, each an exact EQUALS over a STRING.
      #
      # The obvious shape -- one claim carrying the whole list under CONTAINS_ANY -- cannot work,
      # and it fails in a way that looks like anything but the real cause. The API will only accept
      # CONTAINS_ANY alongside `inbound_token_claim_value_type = "STRING_ARRAY"`, which declares
      # that the CLAIM ITSELF is an array. In a Kubernetes projected service account token `sub` is
      # a plain string, so the declared type never matches the token and the gateway refuses every
      # request from every agent:
      #
      #   401 {"error":{"message":"Invalid Bearer token","type":"authentication_error"}}
      #
      # That holds with a gateway reporting READY, the correct audience, and a token whose `sub` is
      # character-for-character one of the listed subjects. Dropping to a single subject -- which
      # switches this to EQUALS over a STRING -- admits the same token immediately: /mcp goes from
      # 401 to a 200 answering tools/list. So the gateway being created
      # successfully says nothing about whether it will admit anybody, and CONTAINS_ANY is not
      # usable against `sub` at all.
      #
      # Emitting one claim per subject keeps the exact per-agent match. A namespace prefix under
      # CONTAINS would also work against a string claim, but it admits any service account a tenant
      # creates in that namespace, which is the separation this is here to provide.
      # EXACTLY ONE SUBJECT. This is a hard limit of the gateway, not a simplification here, and
      # it is worth knowing before designing around it. How the gateway treats each shape:
      #
      #   EQUALS + STRING                 admits that one subject. Works.
      #   CONTAINS_ANY + STRING_ARRAY     created successfully, then refused EVERY token with
      #                                   401 "Invalid Bearer token" -- STRING_ARRAY declares the
      #                                   CLAIM is an array, and `sub` in a projected service
      #                                   account token is a string, so it matches nothing.
      #   CONTAINS + STRING               rejected: "operator CONTAINS must be configured with a
      #                                   STRING_ARRAY inbound token claim value type".
      #   one claim per subject           rejected: "Custom claim name can't be 'sub' since it's
      #                                   duplicate in the claim rule list".
      #
      # So there is no list form, no prefix form and no second rule. A gateway can name one agent
      # subject or none. var.allowed_agent_subjects validates its own length for that reason, and
      # per-agent separation for more than one agent has to come from the egress network policy
      # (which namespaces can reach the gateway at all) plus the policy engine, which is what it is
      # for. The agents-gateway page of the EKS User Guide covers the limit.
      dynamic "custom_claim" {
        for_each = length(var.allowed_agent_subjects) == 1 ? [1] : []

        content {
          inbound_token_claim_name       = "sub"
          inbound_token_claim_value_type = "STRING"

          authorizing_claim_match_value {
            claim_match_operator = "EQUALS"

            claim_match_value {
              match_value_string = var.allowed_agent_subjects[0]
            }
          }
        }
      }
    }
  }

  protocol_configuration {
    mcp {
      instructions = var.mcp_instructions

      # The MCP versions the gateway negotiates. UNSET IS 2025-03-26 ONLY, and that disables every
      # authorization-code (3LO) target: the gateway returns its consent URL by URL elicitation,
      # which needs 2025-11-25, and a call refuses with "Cannot initiate authorization code grant
      # flow. URL elicitation requires MCP version 2025-11-25 or newer" -- reported to the agent only
      # as "An internal error occurred". The older versions stay listed for clients that negotiate
      # them.
      supported_versions = var.mcp_supported_versions

      # SEMANTIC tool search is the thing this gateway adds that the self-managed one does not: an
      # agent finds the right tool without carrying every definition in its prompt. It is the
      # reason to put a large tool catalogue behind this path.
      search_type = var.mcp_search_type
    }
  }

  dynamic "policy_engine_configuration" {
    for_each = var.enable_policy_engine ? [1] : []

    content {
      arn = aws_bedrockagentcore_policy_engine.this[0].policy_engine_arn

      # ENFORCE, not a shadow mode. A policy engine in audit mode on an agent platform is a policy
      # engine that records the call it was there to refuse.
      mode = var.policy_engine_mode
    }
  }

  kms_key_arn = var.gateway_kms_key_arn
  tags        = local.tags

  # The propagation wait, not just the role policy. CreateGateway with a policy engine attached
  # checks the role's AuthorizeAction grant itself, and on a
  # net-new stack it can run before IAM has propagated the grant: AccessDeniedException on a grant
  # that is present -- the same race the targets wait for.
  depends_on = [aws_iam_role_policy.gateway, time_sleep.iam_propagation]
}

# ---------------------------------------------------------------------------
# IAM propagation, before any target is created
# ---------------------------------------------------------------------------

# `depends_on` IS NOT ENOUGH on a net-new cluster.
#
# The inference target's creation makes the GATEWAY SERVICE assume this role and call
# bedrock-mantle:ListModels. Terraform can create the role policy 0s before the target, and the
# service is still refused:
#
#   Cause: While waiting, unexpected state 'FAILED' ... Failed to discover models from inference
#   provider ... HTTP 403: User: arn:aws:sts::<acct>:assumed-role/<name>-agentcore-gateway/
#   inference-iam-auth-session is not authorized to perform: bedrock-mantle:ListModels
#
# The grant is present and correct in IAM at that moment. What fails is IAM's
# own propagation to the service doing the evaluation, and the target's FAILED state is TERMINAL:
# the apply does not retry, and a second apply succeeds purely because time has passed. That makes
# it an apply that fails roughly once per fresh account and then "fixes itself", which is the worst
# shape for a template someone else runs.
resource "time_sleep" "iam_propagation" {
  depends_on = [aws_iam_role_policy.gateway]

  # Twenty seconds, not two. IAM is eventually consistent with no published bound, and the cost of
  # being wrong here is a failed apply with a misleading error rather than a slower one.
  create_duration = "20s"
}

# ---------------------------------------------------------------------------
# Credential providers
# ---------------------------------------------------------------------------

# A service that issues only a static key. The gateway holds it and attaches it per caller, so the
# agent never sees it. Terraform creates the provider; the key value is set out of band, which is

# The operator's own secrets behind the EXTERNAL providers below, resolved to ARNs so the gateway's
# role can be granted read on exactly these. secret_id may be a name or an ARN; the data source
# accepts either.
data "aws_secretsmanager_secret" "external_credential" {
  for_each = merge(
    { for k, v in var.api_key_providers : "apikey-${k}" => v.secret_id },
    { for k, v in var.oauth2_providers : "oauth2-${k}" => v.secret_id },
  )

  arn  = startswith(each.value, "arn:") ? each.value : null
  name = startswith(each.value, "arn:") ? null : each.value
}

# why api_key is not an input here.
resource "aws_bedrockagentcore_api_key_credential_provider" "this" {
  for_each = var.api_key_providers

  name = each.key

  # EXTERNAL, so the key lives in a Secrets Manager secret the organization already rotates and
  # audits rather than in one AgentCore creates and holds for you. Passing the key as a Terraform
  # input would put it in state, and an API key in a state file is the thing this layer exists to
  # remove from the pod.
  api_key_secret_source = "EXTERNAL"

  api_key_secret_config {
    secret_id = each.value.secret_id
    json_key  = each.value.json_key
  }

  tags = local.tags
}

# A service that requires the person's own consent, which is how GitHub, Slack, Google and
# Atlassian work. The person approves once in a browser and the gateway holds the resulting token
# per user.
#
# On this path the platform team supplies the piece that receives that approval and completes its
# session binding: the consent receiver (gitops/charts/consent-receiver, agentcore_consent), whose
# /complete/<key> a target names as credential.default_return_url. An agent running with nobody
# present still needs that first approval to have happened, so plan it as a separate step. See
# the agents-third-party-credentials page of the EKS User Guide.
resource "aws_bedrockagentcore_oauth2_credential_provider" "this" {
  for_each = var.oauth2_providers

  name                       = each.key
  credential_provider_vendor = each.value.vendor

  oauth2_provider_config {
    dynamic "github_oauth2_provider_config" {
      for_each = each.value.vendor == "GithubOauth2" ? [1] : []

      content {
        client_id            = each.value.client_id
        client_secret_source = "EXTERNAL"

        client_secret_config {
          secret_id = each.value.secret_id
          json_key  = each.value.json_key
        }
      }
    }

    dynamic "slack_oauth2_provider_config" {
      for_each = each.value.vendor == "SlackOauth2" ? [1] : []

      content {
        client_id            = each.value.client_id
        client_secret_source = "EXTERNAL"

        client_secret_config {
          secret_id = each.value.secret_id
          json_key  = each.value.json_key
        }
      }
    }

    dynamic "google_oauth2_provider_config" {
      for_each = each.value.vendor == "GoogleOauth2" ? [1] : []

      content {
        client_id            = each.value.client_id
        client_secret_source = "EXTERNAL"

        client_secret_config {
          secret_id = each.value.secret_id
          json_key  = each.value.json_key
        }
      }
    }

    dynamic "atlassian_oauth2_provider_config" {
      for_each = each.value.vendor == "AtlassianOauth2" ? [1] : []

      content {
        client_id            = each.value.client_id
        client_secret_source = "EXTERNAL"

        client_secret_config {
          secret_id = each.value.secret_id
          json_key  = each.value.json_key
        }
      }
    }

    dynamic "microsoft_oauth2_provider_config" {
      for_each = each.value.vendor == "MicrosoftOauth2" ? [1] : []

      content {
        client_id            = each.value.client_id
        tenant_id            = each.value.tenant_id
        client_secret_source = "EXTERNAL"

        client_secret_config {
          secret_id = each.value.secret_id
          json_key  = each.value.json_key
        }
      }
    }

    dynamic "custom_oauth2_provider_config" {
      for_each = each.value.vendor == "CustomOauth2" ? [1] : []

      content {
        client_id            = each.value.client_id
        client_secret_source = "EXTERNAL"

        client_secret_config {
          secret_id = each.value.secret_id
          json_key  = each.value.json_key
        }

        oauth_discovery {
          discovery_url = each.value.discovery_url
        }
      }
    }
  }

  tags = local.tags
}

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------

# A remote MCP server an agent reaches through the gateway. The credential binding is per target
# and per caller: this is the "credential binding per destination" control on the agents-gateway
# page of the EKS User Guide, and it is the one object that has to exist once per external service
# rather than once per agent.
resource "aws_bedrockagentcore_gateway_target" "mcp_server" {
  for_each = var.mcp_server_targets

  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  name               = each.key
  description        = each.value.description

  target_configuration {
    mcp {
      mcp_server {
        endpoint = each.value.endpoint

        # DEFAULT, not DYNAMIC. DYNAMIC has the gateway list whatever the upstream offers at call
        # time, so an agent's tool catalogue changes whenever the upstream changes, with no review
        # in between. On an agent platform that is a tool surface nobody approved.
        listing_mode = each.value.listing_mode
      }
    }
  }

  # Reachability. AgentCore runs outside the VPC, so a target in the cluster needs an ENI placed in
  # it: a ClusterIP Service is not reachable from the gateway however the credential is configured.
  dynamic "private_endpoint" {
    for_each = each.value.private_endpoint != null ? [each.value.private_endpoint] : []

    content {
      managed_vpc_resource {
        vpc_identifier           = private_endpoint.value.vpc_id
        subnet_ids               = private_endpoint.value.subnet_ids
        security_group_ids       = length(private_endpoint.value.security_group_ids) > 0 ? private_endpoint.value.security_group_ids : null
        endpoint_ip_address_type = private_endpoint.value.endpoint_ip_address_type
      }
    }
  }

  credential_provider_configuration {
    dynamic "api_key" {
      for_each = each.value.credential.kind == "api_key" ? [1] : []

      content {
        provider_arn              = aws_bedrockagentcore_api_key_credential_provider.this[each.value.credential.provider].credential_provider_arn
        credential_location       = each.value.credential.location
        credential_parameter_name = each.value.credential.parameter_name
        # Empty means no prefix -- the bare `X-Api-Key: <key>` shape. The API rejects an empty
        # string ("credentialPrefix ... must have length greater than or equal to 1"), so it is
        # omitted rather than sent.
        credential_prefix = each.value.credential.prefix == "" ? null : each.value.credential.prefix
      }
    }

    dynamic "oauth" {
      for_each = each.value.credential.kind == "oauth" ? [1] : []

      content {
        provider_arn = aws_bedrockagentcore_oauth2_credential_provider.this[each.value.credential.provider].credential_provider_arn
        scopes       = each.value.credential.scopes
        grant_type   = each.value.credential.grant_type
        # Where the browser lands after consent; see the variable. Null leaves the gateway's default.
        default_return_url = each.value.credential.default_return_url
      }
    }

    # The gateway's own role, for an AWS API target. This is how a gateway call to an AWS service is
    # signed; an agent's own AWS calls go through its own role instead, which is what attributes
    # them to the agent.
    dynamic "gateway_iam_role" {
      for_each = each.value.credential.kind == "gateway_iam_role" ? [1] : []

      content {
        service = each.value.credential.service
      }
    }
  }
}

# An OpenAPI service exposed to agents as MCP tools. The schema is what fixes the tool surface, so
# it is a reviewable file in Git rather than something the gateway infers.
resource "aws_bedrockagentcore_gateway_target" "open_api" {
  for_each = var.open_api_targets

  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  name               = each.key
  description        = each.value.description

  target_configuration {
    mcp {
      open_api_schema {
        dynamic "s3" {
          for_each = each.value.schema_s3_uri != null ? [1] : []

          content {
            uri = each.value.schema_s3_uri
          }
        }

        dynamic "inline_payload" {
          for_each = each.value.schema_inline != null ? [1] : []

          content {
            payload = each.value.schema_inline
          }
        }
      }
    }
  }

  # Reachability. AgentCore runs outside the VPC, so a target in the cluster needs an ENI placed in
  # it: a ClusterIP Service is not reachable from the gateway however the credential is configured.
  dynamic "private_endpoint" {
    for_each = each.value.private_endpoint != null ? [each.value.private_endpoint] : []

    content {
      managed_vpc_resource {
        vpc_identifier           = private_endpoint.value.vpc_id
        subnet_ids               = private_endpoint.value.subnet_ids
        security_group_ids       = length(private_endpoint.value.security_group_ids) > 0 ? private_endpoint.value.security_group_ids : null
        endpoint_ip_address_type = private_endpoint.value.endpoint_ip_address_type
      }
    }
  }

  credential_provider_configuration {
    dynamic "api_key" {
      for_each = each.value.credential.kind == "api_key" ? [1] : []

      content {
        provider_arn              = aws_bedrockagentcore_api_key_credential_provider.this[each.value.credential.provider].credential_provider_arn
        credential_location       = each.value.credential.location
        credential_parameter_name = each.value.credential.parameter_name
        # Empty means no prefix -- the bare `X-Api-Key: <key>` shape. The API rejects an empty
        # string ("credentialPrefix ... must have length greater than or equal to 1"), so it is
        # omitted rather than sent.
        credential_prefix = each.value.credential.prefix == "" ? null : each.value.credential.prefix
      }
    }

    dynamic "oauth" {
      for_each = each.value.credential.kind == "oauth" ? [1] : []

      content {
        provider_arn = aws_bedrockagentcore_oauth2_credential_provider.this[each.value.credential.provider].credential_provider_arn
        scopes       = each.value.credential.scopes
        grant_type   = each.value.credential.grant_type
        # Where the browser lands after consent; see the variable. Null leaves the gateway's default.
        default_return_url = each.value.credential.default_return_url
      }
    }

    dynamic "gateway_iam_role" {
      for_each = each.value.credential.kind == "gateway_iam_role" ? [1] : []

      content {
        service = each.value.credential.service
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Inference targets: the model egress path
# ---------------------------------------------------------------------------

# This is what makes the gateway a model egress point and not only a tool broker.
#
# The gateway exposes one OpenAI-compatible endpoint at /inference/v1 and routes each request to a
# target on the `model` field in the request body, so an agent sets base_url once and selects a
# model by name. Three properties come with it, and they are the reason an agent's model call goes
# here rather than to bedrock-runtime directly:
#
#   - The agent holds no model credential. The gateway signs with its own role (gateway_iam_role)
#     or attaches the provider key it holds (api_key).
#   - Bedrock Guardrails and AgentCore Policy apply to every call, whatever the provider.
#   - It is one audit point for every model call any agent made.
#
# The cluster-scoped egress policy already permits the gateway hostname and nothing else, so wiring
# this target is what turns that boundary from "nowhere to call" into "one place to call".
resource "aws_bedrockagentcore_gateway_target" "inference" {
  for_each = var.inference_targets

  # The policy, and then time for it to be visible to the service that evaluates it. See
  # time_sleep.iam_propagation.
  depends_on = [time_sleep.iam_propagation]

  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  name               = each.key
  description        = each.value.description

  target_configuration {
    inference {
      connector {
        source {
          connector_id = each.value.connector_id
        }
      }
    }
  }

  credential_provider_configuration {
    # Bedrock. The gateway signs with its own role. inference_model_arns bounds only the
    # gateway's own bedrock: calls; which models an agent reaches through this target is decided
    # by bedrock-mantle:CreateInference (see the variable).
    dynamic "gateway_iam_role" {
      for_each = each.value.credential.kind == "gateway_iam_role" ? [1] : []

      content {
        service = "bedrock"
      }
    }

    # A third-party provider that issues a static key. The gateway holds it; the agent never sees
    # it, which is the same property the tool targets are bought for.
    dynamic "api_key" {
      for_each = each.value.credential.kind == "api_key" ? [1] : []

      content {
        provider_arn              = aws_bedrockagentcore_api_key_credential_provider.this[each.value.credential.provider].credential_provider_arn
        credential_location       = each.value.credential.location
        credential_parameter_name = each.value.credential.parameter_name
        # Empty means no prefix -- the bare `X-Api-Key: <key>` shape. The API rejects an empty
        # string ("credentialPrefix ... must have length greater than or equal to 1"), so it is
        # omitted rather than sent.
        credential_prefix = each.value.credential.prefix == "" ? null : each.value.credential.prefix
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Lambda-backed MCP tools
# ---------------------------------------------------------------------------

# A tool the gateway invokes directly, with no server to run and nothing to expose.
#
# This is how an MCP server reaches a gateway that lives outside the cluster. The gateway signs the
# invoke with its own role, so the function holds no credential and needs no network path of its
# own -- unlike an in-cluster MCP server, which a gateway outside the VPC cannot reach without a
# private endpoint and a VPC-routable address.
resource "aws_bedrockagentcore_gateway_target" "lambda" {
  for_each = var.lambda_targets

  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id
  name               = each.key
  description        = each.value.description

  target_configuration {
    mcp {
      lambda {
        lambda_arn = each.value.function_arn

        tool_schema {
          dynamic "inline_payload" {
            for_each = each.value.tool_schema

            content {
              name        = inline_payload.value.name
              description = inline_payload.value.description

              input_schema {
                type = "object"

                dynamic "property" {
                  for_each = inline_payload.value.properties

                  content {
                    name        = property.value.name
                    type        = property.value.type
                    description = property.value.description
                    required    = property.value.required
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  credential_provider_configuration {
    # The gateway's own role signs the invoke. A Lambda target has no notion of the caller's
    # credential, so the agent's identity reaches the gateway and the gateway's policy is what
    # decides whether this tool may be called.
    gateway_iam_role {}
  }
}

# ---------------------------------------------------------------------------
# The gateway's own application log
# ---------------------------------------------------------------------------
#
# WITHOUT THIS A FAILED TOOL CALL IS UNDIAGNOSABLE. The agent receives
#   {"isError": true, "content": [{"text": "An internal error occurred. Please retry later."}]}
# for every target-side failure -- a secret the role cannot read, an upstream refusing the call --
# and nothing in the cluster, in CloudTrail or in the agent's telemetry says which. The gateway's
# vended APPLICATION_LOGS carry the real reason ("Access denied when retrieving the provided
# secret ...") and each tool's target. That log is where a missing grant, such as the external-secret one above, shows up.
#
# It holds request bodies, which carry tool arguments, so it gets the same retention input as the
# agents' own log groups rather than CloudWatch's never-expire default.
resource "aws_cloudwatch_log_group" "gateway" {
  count = var.enable_gateway_logs ? 1 : 0

  name              = "/aws/vendedlogs/bedrock-agentcore/gateway/${local.gateway_name}"
  retention_in_days = var.gateway_log_retention_days

  tags = local.tags
}

resource "aws_cloudwatch_log_delivery_source" "gateway" {
  count = var.enable_gateway_logs ? 1 : 0

  name         = "${local.gateway_name}-app-logs"
  log_type     = "APPLICATION_LOGS"
  resource_arn = aws_bedrockagentcore_gateway.this.gateway_arn

  tags = local.tags
}

resource "aws_cloudwatch_log_delivery_destination" "gateway" {
  count = var.enable_gateway_logs ? 1 : 0

  name = "${local.gateway_name}-app-logs"

  delivery_destination_configuration {
    destination_resource_arn = aws_cloudwatch_log_group.gateway[0].arn
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_delivery" "gateway" {
  count = var.enable_gateway_logs ? 1 : 0

  delivery_source_name     = aws_cloudwatch_log_delivery_source.gateway[0].name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.gateway[0].arn

  tags = local.tags
}
