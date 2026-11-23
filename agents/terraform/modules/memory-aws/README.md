# memory-aws

Agent memory on the AWS services path, as three independent rungs: Amazon ElastiCache Serverless (Valkey) for session state, Amazon S3 Vectors for semantic recall, and AgentCore Memory for consolidation. The `aws-services` root always calls it, and each rung is created only when its variable is on. The open source path runs Valkey, pgvector, and Mem0 in the cluster instead; [Agent memory](https://docs.aws.amazon.com/eks/latest/userguide/agents-memory.html) compares them.

## What it creates

| Rung | Variable | Resources |
|---|---|---|
| Session state | `enable_session_state` | A serverless cache, its security group with ingress from `client_security_group_ids`, and, unless you pass `session_state_user_group_id`, a user group with the default user disabled and an IAM-authenticated agent user. `session_state_agent_keyspaces` adds one user per agent, confined to its own key prefix. |
| Semantic recall | `enable_semantic_recall` | A vector bucket and one index per entry in `semantic_recall_indexes`. |
| Consolidation | `enable_consolidation` | An AgentCore Memory with one strategy per entry in `consolidation_strategies`. Its execution role is created only when `consolidation_model_arns` or `kms_key_arn` is set. |

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `name`, `cluster_name` | | |
| `vpc_id`, `subnet_ids`, `client_security_group_ids` | `null`, `[]`, `[]` | Placement and clients of the cache. |
| `kms_key_arn` | `null` | Customer managed key for all three rungs. |
| `session_state_max_storage_gb`, `session_state_max_ecpu`, `session_state_snapshot_retention_days` | `10`, `5000`, `0` | Cache limits and snapshots. |
| `session_state_user_group_id` | `null` | Bring your own user group. |
| `session_state_agent_keyspaces` | `{}` | Agent name to key pattern, such as `agent:research:*`. Empty means every agent shares one user with access to every key. |
| `semantic_recall_bucket_name`, `semantic_recall_indexes` | `null`, `{}` | |
| `consolidation_event_expiry_duration` | `90` | Days raw events are kept. |
| `consolidation_model_arns`, `consolidation_strategies`, `consolidation_indexed_keys` | `[]`, `{}`, `[]` | |

## Outputs

`session_state_endpoint` (an `address:port` string, empty when the rung is off), `session_state_cache_arn`, `session_state_security_group_id`, `session_state_user_arn`, `session_state_user_name`, `session_state_agent_user_arns`, `session_state_agent_user_names`, `semantic_recall_bucket_arn`, `semantic_recall_index_arns`, `memory_id`, `memory_arn`, `memory_execution_role_arn`.

## Constraints

* The cache accepts only TLS connections and authenticates with an IAM-signed token, not a password. A plaintext client connects and never gets a reply.
* A per-agent key prefix doesn't hide key names: `SCAN` still lists other agents' keys.
* AgentCore Memory has no Kubernetes interface, so agents reach it from application code rather than through the `Agent` resource.
