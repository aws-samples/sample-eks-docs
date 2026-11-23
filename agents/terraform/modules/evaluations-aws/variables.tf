variable "name" {
  description = "Name prefix, normally the cluster name."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster the agents run on. Descriptions only."
  type        = string
}

variable "source_log_group_names" {
  description = "CloudWatch log groups holding the agent traces to grade. Pass the telemetry_log_group_name output of ../observability-aws. Evaluation runs on the traces the observability layer already collects, so this module has no instrumentation of its own."
  type        = list(string)

  validation {
    condition     = length(var.source_log_group_names) > 0
    error_message = "Name at least one log group. An evaluation config with no source grades nothing."
  }
}

variable "source_service_names" {
  description = <<-EOT
    Service names inside those log groups to scope the evaluation to, as the agent reports them in
    its OTEL resource attributes.

    EXACTLY ONE, ONCE enable_online_evaluation IS TRUE, and that is a hard limit of the API rather
    than a simplification here. The API refuses both other lengths:

      []              Member must have length greater than or equal to 1
      two names       Member must have length less than or equal to 1

    So ONE ONLINE EVALUATION CONFIG GRADES ONE AGENT. Several agents means several configs, each
    with its own name and its own evaluator set; this module creates one. The
    same shape as the gateway's one-subject limit, and it lands in the same place: the AWS-side
    control is per agent, and the platform has to fan out to match.

    It cannot be derived from the agents Terraform creates: that map is empty in the normal case --
    an empty `agents` map is what turns the `Agent` resource definition on -- so deriving it would
    create no online evaluation at all. Like the gateway's subject allowlist, this has to be stated
    by the platform team, because the agents are declared in the cluster and Terraform never sees
    them.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = !var.enable_online_evaluation || length(var.source_service_names) == 1
    error_message = "Name exactly one service when enable_online_evaluation is true. The API refuses both an empty serviceNames list and a list of two: one online evaluation config grades one agent. The value is the OTEL service.name the agent reports -- the name on its `Agent` resource, unless it overrides OTEL_SERVICE_NAME."
  }
}

variable "judge_model_arns" {
  description = "Model ARNs the evaluation role may invoke as a judge. Scoped, so the grade an agent's output receives comes from a model the team named."
  type        = list(string)
  default     = []
}

variable "builtin_evaluators" {
  description = <<-EOT
    AgentCore Evaluations' built-in evaluators the online evaluation grades with, by id
    (`aws bedrock-agentcore-control list-evaluators`). They need no model grant: AgentCore runs
    their judge. Graded alongside any llm_judge_evaluators.

    THE DEFAULT IS NOT EMPTY because online evaluation with no evaluator at all passes `plan` and
    fails `apply` with "Block evaluator must have a configuration value as the provider has marked
    it as required". Set [] to grade with llm_judge_evaluators only.
  EOT
  type        = list(string)
  default     = ["Builtin.Helpfulness", "Builtin.Correctness", "Builtin.GoalSuccessRate"]

  validation {
    condition     = alltrue([for id in var.builtin_evaluators : startswith(id, "Builtin.")])
    error_message = "builtin_evaluators takes AgentCore built-in evaluator ids, which start with \"Builtin.\" (e.g. Builtin.Helpfulness). Custom judges go in llm_judge_evaluators."
  }
}

variable "llm_judge_evaluators" {
  description = <<-EOT
    Graded dimensions, keyed by evaluator name. Ship a handful rather than one: a single aggregate
    score tells nobody which release regressed.

    level is the grain, and it is TOOL_CALL, TRACE or SESSION. TOOL_CALL grades one call and its
    arguments. TRACE grades one invocation end to end. SESSION grades a conversation across
    invocations. An agent whose failure mode is taking a wrong action is not caught at SESSION
    level, and an agent whose failure mode is forgetting what it was told is not caught at
    TOOL_CALL, so most agent platforms ship evaluators at more than one grain.

    rating_scale is a list of points, each with a label, a definition and a score. The definitions
    are what make two runs comparable and what a reviewer reads to know what a 3 meant.

    INSTRUCTIONS MUST NAME AT LEAST ONE PLACEHOLDER, AND WHICH ONES ARE ALLOWED DEPENDS ON THE
    LEVEL. Prose with no placeholder is refused at create, after everything else in the apply has
    succeeded. Single braces: `{context}`, not `{{context}}` -- the double form is rejected as an
    invalid placeholder while the message lists the same names, which reads as the name being
    wrong. The API allows these placeholders by level:

      TOOL_CALL  available_tools, context, tool_turn, system_instructions, user_message,
                 available_skills, invoked_skill, skill_content
      TRACE      context, assistant_turn, expected_response, system_instructions
      SESSION    available_tools, context, actual_tool_trajectory, expected_tool_trajectory,
                 assertions

    model_id IS AN INFERENCE PROFILE ID FOR MOST MODELS. Every Anthropic model in us-west-2
    reports INFERENCE_PROFILE only, so a bare foundation-model id is refused at create with
    "Invocation of model ID ... with on-demand throughput isn't supported". Use the `us.`-prefixed
    profile id, and remember that judge_model_arns then has to name the profile ARN AND the
    foundation model in every region the profile routes to.
  EOT
  type = map(object({
    description      = string
    level            = string
    instructions     = string
    model_id         = string
    judge_max_tokens = optional(number, 2048)
    rating_scale = list(object({
      label      = string
      definition = string
      score      = number
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.llm_judge_evaluators : contains(["TOOL_CALL", "TRACE", "SESSION"], v.level)
    ])
    error_message = "level must be TOOL_CALL, TRACE or SESSION."
  }

  validation {
    condition = alltrue([
      for k, v in var.llm_judge_evaluators : length(v.rating_scale) >= 2
    ])
    error_message = "A rating scale needs at least two points. One point is not a grade."
  }

  validation {
    condition = alltrue([
      for k, v in var.llm_judge_evaluators :
      alltrue([for p in v.rating_scale : trimspace(p.definition) != ""])
    ])
    error_message = "Every rating scale point needs a definition. A bare number is not comparable across runs and tells a reviewer nothing."
  }

  # The placeholder rules, checked here rather than at create. Both failures arrive from the API
  # after the role, the policy and every other evaluator are already made, and neither message
  # names the variable -- so an apply that is otherwise correct fails on prose.
  validation {
    condition = alltrue([
      for k, v in var.llm_judge_evaluators :
      length([
        for p in lookup({
          TOOL_CALL = ["available_tools", "context", "tool_turn", "system_instructions", "user_message", "available_skills", "invoked_skill", "skill_content"]
          TRACE     = ["context", "assistant_turn", "expected_response", "system_instructions"]
          SESSION   = ["available_tools", "context", "actual_tool_trajectory", "expected_tool_trajectory", "assertions"]
        }, v.level, []) : p if strcontains(v.instructions, "{${p}}")
      ]) > 0
    ])
    error_message = "Each evaluator's instructions must name at least one placeholder allowed at its level, in single braces. TOOL_CALL: available_tools, context, tool_turn, system_instructions, user_message, available_skills, invoked_skill, skill_content. TRACE: context, assistant_turn, expected_response, system_instructions. SESSION: available_tools, context, actual_tool_trajectory, expected_tool_trajectory, assertions. Without one the judge grades nothing, and the API refuses the evaluator at create."
  }

  validation {
    condition = alltrue([
      for k, v in var.llm_judge_evaluators : !strcontains(v.instructions, "{{")
    ])
    error_message = "Placeholders take single braces -- {context}, not {{context}}. The double form is rejected as an invalid placeholder while the message lists the same names, which reads as the name being wrong rather than the braces."
  }
}

variable "enable_online_evaluation" {
  description = "Grade live traffic as it happens, sampled. Off by default. A team with an internal agent and a small audience grades by hand first; the harness earns its place when the output starts reaching people who did not ask for it."
  type        = bool
  default     = false
}

variable "enable_on_create" {
  description = "Start the online evaluation as soon as it is created. False creates it stopped, which is what a team wants when it is validating the evaluator definitions before paying for them."
  type        = bool
  default     = false
}

variable "sampling_percentage" {
  description = "Share of sessions graded, 0 to 100. This is the cost control: every sampled session is a judge model call, so 100 means the harness costs about as much per session as the agent did."
  type        = number
  default     = 10

  validation {
    condition     = var.sampling_percentage > 0 && var.sampling_percentage <= 100
    error_message = "sampling_percentage must be between 1 and 100. Zero would create a harness that grades nothing."
  }
}

variable "session_timeout_minutes" {
  description = "How long after the last span a session is considered finished and graded. Set it past the longest gap an interactive agent leaves between turns, or one conversation is graded as several."
  type        = number
  default     = 30
}

variable "results_bucket_arn" {
  description = "Bucket the evaluation results are written to. Null leaves them in the service's own storage."
  type        = string
  default     = null
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for the evaluators and their results. The results quote the agent's output, which is content."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  default     = {}
}

variable "runner" {
  description = <<-EOT
    The Strands Evals runner's identity (gitops/charts/agent-evals), when evaluation is enabled. Null
    creates nothing. Its Pod Identity role reads source_log_group_names and aws/spans and writes
    /aws/bedrock-agentcore/evaluations/results/*; it has no model permission, because its judge
    calls go through the AgentCore Gateway on the pod's own token.
  EOT
  type = object({
    namespace       = string
    service_account = string
    cluster_arn     = string
  })
  default = null
}
