# adot-collector chart

The ADOT collector that carries agent telemetry to CloudWatch GenAI Observability on the AWS services path. Read this before you change the collector's pipeline.

The `adot-collector` Application in [`gitops/platform/aws-services/templates/50-adot.yaml`](../../platform/aws-services/templates/50-adot.yaml) installs it at sync wave 1, after the OpenTelemetry operator that reconciles it, when `enable_observability` is on. Each value is documented in [`values.yaml`](values.yaml), and each pipeline decision in the template.

## What it renders

| Template | Objects |
|---|---|
| `templates/collector.yaml` | The collector's ServiceAccount and one `OpenTelemetryCollector`, `adot`, in `opentelemetry-operator-system` |

## Values you set

| Key | Effect |
|---|---|
| `collector.metricNamespace` | The CloudWatch metric namespace. It must be one the collector's IAM role permits. |
| `collector.keepPromptContent` | Whether prompt and response content stays on spans and log records. `false`, the default, strips it. Content stays regardless when `observability.evaluationsReadSpans` is true, which Terraform sets with `enable_evaluations` or `enable_online_evaluation`, since both grade the spans. |
| `collector.replicas`, `collector.resources` | The collector's size. |

`region`, `cluster`, and `observability` (the log group, the service account, its role, and whether an evaluation reads the spans) come from `terraform-values.yaml`, and the chart refuses to render with the placeholder Region or no log group.

## Constraints

* `metric_declarations` bounds the exporter's dimensions; without it, each agent turn creates new CloudWatch custom metrics.
* `resource_to_telemetry_conversion` is what makes the `eks.agent` resource attribute usable as a metric dimension.
* `indexed_attributes` indexes span attributes only, and an entry for a resource attribute does nothing.
* The ADOT distribution ships a subset of upstream processors and has no `transform` processor; the template lists the ones it has.
