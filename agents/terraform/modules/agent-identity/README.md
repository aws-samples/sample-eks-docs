# agent-identity

One agent's AWS identity: an IAM role, its trust and permission policies, and the EKS Pod Identity association that delivers it to the pod. Both roots call it once per entry in their `agents` map.

The default is `agents = {}`, and then this module creates nothing. Agents are declared in the cluster as `Agent` resources instead, and kro composes the same objects through ACK. The two are alternatives: don't use both for the same agent.

## What it creates

| Resource | Notes |
|---|---|
| `aws_iam_role.agent` | Trusts `pods.eks.amazonaws.com` for this cluster only, plus any role in `assumable_by_role_arns`. Created under `role_path` with `permissions_boundary_arn`. |
| `aws_iam_role_policy.agent` | Bedrock invoke on the granted models, `ApplyGuardrail` when a guardrail is required, checkpoint access scoped to the agent's prefix, and `extra_policy_json`. |
| `aws_eks_pod_identity_association.agent` | Binds the role to `namespace`/`service_account`. |

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `cluster_name`, `cluster_arn` | | The cluster the trust policy is scoped to. |
| `agent_name`, `namespace` | | |
| `service_account` | `agent_name` | |
| `role_path`, `permissions_boundary_arn` | `"/eks-agents/"`, `null` | From the `agent-cluster` outputs. |
| `bedrock_model_arns`, `bedrock_inference_profile_ids` | `[]` | Models the agent may call. An inference profile is expanded to every Region it routes to. |
| `bedrock_guardrail_arn`, `bedrock_guardrail_version` | `null` | Set both to require the guardrail on every model call; one alone has no effect. |
| `checkpoint_bucket_arn`, `checkpoint_prefix`, `checkpoint_kms_key_arn` | `null` | Prefix defaults to `agents/<agent_name>/`. |
| `assumable_by_role_arns`, `gateway_identity_claim` | `[]`, `null` | For a gateway that signs as the agent. Set the claim whenever you set the roles; it binds the session to one agent's SPIFFE ID through `sts:ExternalId`. |
| `session_policy_json` | `null` | A session policy on the association. Setting it turns session tags off. |
| `extra_policy_json` | `null` | Extra permissions, still capped by the permissions boundary. |

## Outputs

`role_arn`, `role_name`, `namespace`, `service_account`, `association_id`, `session_tags_enabled`, `checkpoint_prefix`.

## Constraints

* Pod Identity attaches the cluster, namespace, service account, pod name, and pod UID as session tags on every session, and a policy elsewhere can read them as conditions. With `session_policy_json` set those tags are gone, so the session policy must carry any scoping they did.
