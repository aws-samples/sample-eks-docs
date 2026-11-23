# Warnings, not errors: each is a configuration that applies cleanly and then refuses every call.

# THE POLICY ENGINE IS ON BY DEFAULT, AND CEDAR IS DENY-BY-DEFAULT. Turning the gateway on with no
# permit leaves every model and tool call refused: `HTTP 403 ... No policy applies to the request
# (denied by default)`. Name each agent's service account in a permit (example.tfvars), or set
# policy_engine_mode = "LOG_ONLY" while you write them.
#
# Both checks read local.cedar_policies, which holds the permits Terraform generates from
# gateway_permitted_agents and enable_evaluations as well as cedar_policies. Reading the variable
# alone would warn at every User Guide gateway step, where the permits are all generated.
check "gateway_policy_permits_a_caller" {
  assert {
    condition     = !(var.enable_gateway && var.enable_policy_engine && var.policy_engine_mode == "ENFORCE") || length(local.cedar_policies) > 0
    error_message = "The gateway's policy engine is ENFORCE with no cedar_policies, so it will deny every call (403 \"No policy applies to the request\"). Name each agent in gateway_permitted_agents, or add a permit to cedar_policies, e.g. permit(principal == AgentCore::OAuthUser::\"system:serviceaccount:agents:<name>\", action in AgentCore::Action::\"bedrock\", resource == AgentCore::Gateway::\"{{gateway_arn}}\"), or set policy_engine_mode = \"LOG_ONLY\"."
  }
}

# THE EVALUATION JUDGE IS A GATEWAY PRINCIPAL OF ITS OWN. With per-agent permits and none naming
# the runner's service account, every judge call is a 403 and the release gate grades nothing.
check "evaluation_judge_is_permitted" {
  assert {
    condition = !(var.enable_evaluations && var.enable_policy_engine && var.policy_engine_mode == "ENFORCE") || anytrue([
      for p in values(local.cedar_policies) : strcontains(p.statement, "system:serviceaccount:agent-evals:agent-evals")
    ])
    error_message = "enable_evaluations is on and no cedar_policies statement names the judge, system:serviceaccount:agent-evals:agent-evals, so every judge call through the gateway is refused and the release gate grades nothing. Add a permit for it on the inference target."
  }
}
