# vpc-endpoints

Interface VPC endpoints that keep the cluster's traffic to AWS services inside the VPC instead of sending it through the NAT gateway to a public endpoint. Both roots create them from `vpc_endpoints`; none are created by default.

## What it creates

| Resource | When |
|---|---|
| A security group that accepts HTTPS from the VPC's CIDR | Any endpoint is requested |
| One interface endpoint per service key, with private DNS on | Per key in `endpoints` |

Private DNS makes each service's own hostname resolve to the endpoint inside the VPC, so the agents' URLs and network policy stay the same.

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `endpoints` | `[]` | Service keys, below. |
| `agentcore_gateway_arns` | `[]` | Gateways the `agentcore-gateway` endpoint admits. Required with that key. |
| `vpc_id`, `vpc_cidr`, `subnet_ids` | | The VPC, its CIDR, and the private subnets for the endpoints' interfaces. |
| `name`, `region`, `tags` | | Naming, Region, and tags. |

## Service keys

| Key | Endpoint service | Called by |
|---|---|---|
| `agentcore-gateway` | `bedrock-agentcore.gateway` | Agents, with the gateway on (AWS services path) |
| `bedrock-runtime` | `bedrock-runtime` | Agents without a gateway; AgentGateway (open source path) |
| `agentcore` | `bedrock-agentcore` | Agents, with AgentCore Memory |
| `s3vectors` | `s3vectors` | Agents, with semantic recall |
| `sts`, `secretsmanager` | `sts`, `secretsmanager` | Agents and platform components |
| `sqs` | `sqs` | Task agents (`enable_agent_tasks`): the task pod, the KEDA operator reading queue depth, and whatever sends tasks from inside the VPC |
| `ecr-api`, `ecr-dkr` | `ecr.api`, `ecr.dkr` | Nodes pulling images (layers come from S3, through its gateway endpoint) |
| `eks-auth` | `eks-auth` | The EKS Pod Identity agent on each node |
| `oidc-eks` | `oidc-eks` | Every service account token check: agents, the MCP server, and anything else that reads the cluster's OIDC issuer |
| `logs`, `monitoring`, `xray` | `logs`, `monitoring`, `xray` | The telemetry collector |
| `ssm`, `ssmmessages`, `ec2messages` | `ssm`, `ssmmessages`, `ec2messages` | The bastion's Session Manager channel |
| `eks`, `elasticloadbalancing`, `bedrock` | `eks`, `elasticloadbalancing`, `bedrock` | The scripts run on the bastion: the EKS API, load balancer and inference profile lookups |

Route 53, which ExternalDNS calls, has no VPC endpoint and stays on the NAT gateway.

With `eks`, the roots add `oidc-eks`, and the module refuses `eks` without it. The EKS endpoint's private DNS hosts `eks.<region>.amazonaws.com` in the VPC, and on its own it leaves the OIDC issuer `oidc.eks.<region>.amazonaws.com` with no record there, so every service account token check fails. With the `oidc-eks` endpoint's own zone also in the VPC, the issuer resolves to the `oidc-eks` endpoint and its discovery document answers, while the EKS API answers through the `eks` endpoint.

## With no NAT gateway route

With every key above and the private subnets' default route removed, these keep working: model and tool calls, Pod Identity, token checks (with `oidc-eks`), session state, checkpoints, memory, telemetry, ingress for machine callers, the release gate, new nodes joining, and Argo CD syncs (the EKS capability reads the repository on the AWS side). These need a route to the internet or a mirror:

| What | Why |
|---|---|
| Image pulls from public registries | quay.io, registry.k8s.io, docker.io (Istio's images), ghcr.io and public.ecr.aws have no VPC endpoint. Running pods keep their cached image; a pod scheduled on a new node, including the Istio CNI and ztunnel DaemonSet pods, can't start. Copy the images into private ECR, or use an ECR pull through cache rule for the registries it supports. |
| ExternalDNS | Route 53 has no VPC endpoint. |
| A person's sign-in through the chat UI | The chat UI verifies the load balancer's signed claims with the key at `public-keys.auth.elb.<region>.amazonaws.com`, which has no VPC endpoint. |
| Building images on the bastion | The base image comes from public.ecr.aws and packages from PyPI. |

Every endpoint except `agentcore-gateway` keeps the default endpoint policy, which allows whatever the caller's own IAM permissions allow. Scoping them further is a [data perimeter](https://aws.amazon.com/identity/data-perimeters-on-aws/) decision.

## Outputs

| Output | Value |
|---|---|
| `endpoint_ids` | Endpoint ID per key |
| `security_group_id` | The endpoints' security group |

## Constraints

* The `agentcore-gateway` endpoint's policy allows requests to the listed gateways only. Gateway callers authenticate with a JWT, not SigV4, so the policy scopes the resource, not the principal.
* An endpoint's private DNS zone answers for every name under it, so it can hide another service's host. `agentcore` (`bedrock-agentcore.<region>.amazonaws.com`) covers every AgentCore Gateway host (`<name>.gateway.bedrock-agentcore...`), so with the gateway on it needs `agentcore-gateway` as well, which the AWS services root adds. `eks` covers the cluster's OIDC issuer the same way, so it comes with `oidc-eks`.
* Private DNS for a service applies to the whole VPC. With the endpoint in place, every workload in the VPC reaches that service through it, subject to its policy.
