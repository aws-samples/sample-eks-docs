# egress-agentgateway

The AWS side of the open source path's egress gateway. AgentGateway itself runs in the cluster, and its GatewayClass, Gateway, backends, routes, and policies are in [`gitops/platform/open-source/`](../../../gitops/platform/open-source). The `open-source` root calls this module when `enable_gateway` is on.

## What it creates

| Resource | Notes |
|---|---|
| `aws_iam_role.gateway` and its Pod Identity association | For `gateway_namespace`/`gateway_service_account`. The role can assume agent roles, read its brokered secrets, and, with `enable_bedrock_marketplace_subscribe`, accept a Marketplace model subscription. It has no Bedrock invoke permission of its own: it signs model calls as the agent. |
| `aws_iam_role.judge` | With `judge` set, the evaluation judge's role, under the agent role path. |
| `aws_secretsmanager_secret.third_party` | One per entry in `third_party_credentials`, readable by the gateway and `credential_admin_principal_arns`. The module never sets a value. |
| `aws_acmpca_certificate_authority.mesh` | With `enable_mesh_private_ca`, a Private CA for the mesh. |

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `name`, `cluster_name`, `cluster_arn` | | |
| `gateway_namespace`, `gateway_service_account` | `"agentgateway-system"`, `"egress"` | Where the gateway runs. |
| `agent_role_arns` | `[]` | Agent roles from `agent-identity`, when agents are declared in Terraform. |
| `agent_role_path_arn` | `""` | A role path ARN such as `arn:aws:iam::111122223333:role/eks-agents/*`, when agents are `Agent` resources. The root sets it whenever `agents` is empty. |
| `third_party_credentials` | `{}` | One `{ destination, caller }` per brokered credential. |
| `credential_kms_key_arn`, `credential_admin_principal_arns` | `null`, `[]` | Key and admins for the brokered secrets. |
| `enable_mesh_private_ca`, `mesh_trust_domain` | `false`, `"cluster.local"` | |
| `enable_bedrock_marketplace_subscribe` | `true` | Grants `aws-marketplace:Subscribe` and `aws-marketplace:ViewSubscriptions` on `*`, account-wide, because Marketplace actions take no resource. On so the first Claude call on an account that has not subscribed succeeds; `false` is the tighter setting where subscriptions are managed centrally. The open-source root exposes it under the same name. |
| `judge` | `null` | `{ model_arns, role_path, permissions_boundary_arn }`. |

## Outputs

`gateway_role_arn`, `gateway_namespace`, `gateway_service_account`, `third_party_secret_arns`, `third_party_secret_names`, `mesh_private_ca_arn`, `judge_role_arn`.

## Constraints

* Set either `agent_role_arns` or `agent_role_path_arn`. With neither, the gateway can assume no agent role and every model call returns 403 from Bedrock.
* Brokering puts every agent's third-party credentials in one process, so treat the gateway's namespace and role as the most sensitive in the stack. [Third-party credentials](https://docs.aws.amazon.com/eks/latest/userguide/agents-third-party-credentials.html) covers how the values get set.
