# evaluations-aws

AgentCore Evaluations on the AWS services path: LLM-judge evaluators, the online evaluation configuration, and the roles they and the Strands Evals runner use. The `aws-services` root calls it only when `enable_observability` is on and `enable_evaluations` or `enable_online_evaluation` is on, because it grades the traces that [`observability-aws`](../observability-aws) collects.

## What it creates

| Resource | Notes |
|---|---|
| `aws_iam_role.evaluation` | The role AgentCore Evaluations assumes to read traces and call the judge models. |
| `aws_bedrockagentcore_evaluator.llm_judge` | One per entry in `llm_judge_evaluators`. |
| `aws_bedrockagentcore_online_evaluation_config.this` | With `enable_online_evaluation`. Its `execution_status` is `ENABLED` when `enable_on_create` is true and `DISABLED` otherwise, on every apply. |
| `aws_iam_role.runner` and its Pod Identity association | With `runner` set (the root sets it with `enable_evaluations`). Reads traces and writes results; no model permission, because its judge calls go through the AgentCore Gateway. |

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `name`, `cluster_name` | | |
| `source_log_group_names` | | The traces to grade, from `observability-aws`. |
| `source_service_names` | `[]` | Exactly one OTEL `service.name` when online evaluation is on. The root fills it from `agents` and `evaluation_service_names`. |
| `judge_model_arns` | `[]` | Extra models the evaluation role may invoke. Models named by `llm_judge_evaluators` are granted from each evaluator's `model_id`. |
| `builtin_evaluators` | `["Builtin.Helpfulness", "Builtin.Correctness", "Builtin.GoalSuccessRate"]` | Built-in evaluators, graded alongside the custom ones. |
| `llm_judge_evaluators` | `{}` | Custom evaluators, keyed by name. |
| `enable_online_evaluation`, `enable_on_create` | `false`, `false` | The root maps `enable_on_create` from `enable_online_evaluation_on_create`. |
| `sampling_percentage`, `session_timeout_minutes` | `10`, `30` | Share of sessions graded, and the idle time that ends a session. |
| `results_bucket_arn`, `kms_key_arn` | `null` | |
| `runner` | `null` | `{ namespace, service_account, cluster_arn }`. |

## Outputs

`evaluation_role_arn`, `evaluator_ids`, `evaluator_arns`, `online_evaluation_config_id`, `online_evaluation_running`, `runner_role_arn`.

## Constraints

* One online evaluation configuration grades one agent: the API refuses an empty `serviceNames` list and a list of two.
* Every sampled session is a judge model call, so `sampling_percentage` is the cost control.
