# durable-storage

The S3 checkpoint bucket, for agent state that has to outlive the pod that wrote it. Both roots call it when `enable_checkpoints` is on.

It's a separate layer from session state: an agent touches a checkpoint about once per session and session state once per turn. The header of [`main.tf`](main.tf) has the reasoning.

## What it creates

One versioned bucket with ownership controls (bucket owner enforced), a public access block, encryption (SSE-S3, or SSE-KMS with a bucket key when `kms_key_arn` is set), a lifecycle configuration, and a bucket policy that denies non-TLS requests and principals outside the account or organization.

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `bucket_name` | | The roots derive it as `<name>-agent-checkpoints-<account>`. |
| `kms_key_arn` | `null` | Customer managed key. Pass the same ARN to `agent-identity` as `checkpoint_kms_key_arn`. |
| `organization_id` | `null` | Allows principals in the organization. Null allows this account only. |
| `noncurrent_version_retention_days` | `30` | How long a superseded version is kept. |
| `current_version_expiration_days` | `null` | Null keeps current objects indefinitely. |
| `force_destroy` | `false` | Delete every object and version with the bucket. |

## Outputs

`bucket_name`, `bucket_arn`, `bucket_regional_domain_name`.

## Constraints

* With `force_destroy = false`, `terraform destroy` fails with `BucketNotEmpty` until you delete every version and delete marker. [`scripts/teardown.sh`](../../../scripts/teardown.sh) does it, or set the root's `checkpoint_bucket_force_destroy = true` on a disposable stack.
