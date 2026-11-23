# agent-evals chart

The Strands Evals runner, on both paths: it grades sampled live sessions and runs declared test cases against deployed agents as a release gate. Read this to set up the release gate or change what's graded.

The `agent-evals` Application in `gitops/platform/<path>/52-agent-evals.yaml` installs it at sync wave 4 when `enable_evaluations` is on, with `values.yaml`, then `terraform-values.yaml`, then the path's `agent-evals-values.yaml`, which holds your cases. Each value is documented in [`values.yaml`](values.yaml).

The runner's judge is a gateway principal with its own service account and IAM role, so grading is a model call the gateway meters and audits like an agent's.

## What it renders

| Template | Objects | Rendered when |
|---|---|---|
| `templates/serviceaccount.yaml` | The `agent-evals` ServiceAccount, with no API token mounted | `evals.enabled` |
| `templates/configmap.yaml` | The runner's settings: evaluators, rubrics, and cases | `evals.enabled` |
| `templates/cronjobs.yaml` | `agent-evals-online`, which grades a sample of quiet sessions from Langfuse every 15 minutes | `evals.backend` is `langfuse` (open source) and `online.enabled` |
| | `agent-evals-experiment`, a suspended CronJob you run on demand as the release gate | `experiment.agents` isn't empty |
| `templates/networkpolicy.yaml` | Default deny, then DNS, the gateway, Langfuse or AWS APIs, and each agent under test | `evals.enabled` |

On the AWS services path, AgentCore Evaluations grades live traffic instead of the online CronJob, and the release gate writes its results to AgentCore Evaluations' result log group.

## Run the release gate

```bash
kubectl -n agent-evals create job --from=cronjob/agent-evals-experiment gate-1
```

The job exits 1 when the pass rate is below `experiment.minPassRate`, so a pipeline can wait on it.

## Values you set

| Key | Effect |
|---|---|
| `experiment.agents` | The agents to test, by `Agent` name, with their cases. Each needs `expose: cluster`. |
| `experiment.minPassRate` | The share of grades that must pass. |
| `evaluators`, `rubrics`, `experiment.extraEvaluators` | What's graded. `extraEvaluators` need an expected answer, so only the release gate runs them. |
| `online.samplingPercentage`, `online.schedule` | How much live traffic is graded, which is the judge's cost. |

`evals` (the backend, the judge's endpoint and model, and the AgentCore log groups) and `registry` come from `terraform-values.yaml`, and the chart refuses to render without the runner image, a valid backend, or the judge's endpoint.
