# Base chart

The Helm chart that owns everything cluster-wide on both paths: the agent namespaces, the network policy tiers, the admission policies, the agents' NodeClass, and the `Agent` resource definition. Read it before you change a control that applies to every agent.

The `eks-agents-base` Application (`gitops/platform/<path>/00-base.yaml`) installs it at sync wave `-10`, with `values.yaml` and then the path's `terraform-values.yaml`. Nothing here is applied by hand.

## Templates

| Template | What it renders | Rendered when |
|---|---|---|
| `00-namespaces.yaml` | The `agents` and `agents-execution` namespaces with their Pod Security, admission, and mesh labels, plus `ingress` and `agent-evals` | Always; `ingress` with `ingress.enabled`, `agent-evals` with `evals.enabled` |
| `05-oci-repositories.yaml` | An Argo CD repository Secret per OCI Helm registry a component pulls from | Per key in `ociRepositories`, which Terraform sets on the open source path |
| `10-network-policy-controller.yaml` | The `amazon-vpc-cni` ConfigMap that turns network policy enforcement on | `networkPolicy.enabled` |
| `11-agents-nodeclass.yaml` | The `eks-agents` NodeClass and NodePool, with `networkPolicy: DefaultDeny` and the `eks-agents/dedicated` taint | `nodeClass.enabled` and a `nodeClass.roleName` from Terraform |
| `15-storage-class.yaml` | `eks-agents-gp3`, the default StorageClass, which EKS Auto Mode doesn't create | `storageClass.create` |
| `20-admission-sandbox.yaml` | The `eks-agents-sandbox-required` admission policy: a pod in a namespace labeled `eks-agents/admission: enforce` needs a sandbox runtime class and can't use the node's network, PID, or IPC namespace | Always |
| `30-cluster-egress-policy.yaml` | Admin-tier ClusterNetworkPolicies: execution tier denied, DNS, infrastructure, approved destinations, the cluster API, and the reasoning tier's default deny | `networkPolicy.enabled` and `networkPolicy.clusterScoped` |
| `31-namespaced-egress-policy.yaml` | ApplicationNetworkPolicies for the reasoning tier's egress and the execution tier's isolation | `networkPolicy.enabled` and `networkPolicy.namespaced` |
| `32-ingress-network-policy.yaml` | Ingress from the load balancer for workloads the `Agent` doesn't compose | `ingress.enabled` and `ingress.loadBalancerCidrs` |
| `35-kro-rbac.yaml` | The RBAC the kro capability needs to compose each kind an `Agent` uses | `agentResource.enabled` and a kro role name from Terraform |
| `40-agent-rgd.yaml` | The `Agent` resource definition | `agentResource.enabled` |
| `41-admission-agent-runtime.yaml` | The `eks-agents-agent-runtime` admission policy, which refuses `Agent` specs the sandbox runtime can't honor, such as more than one replica | `agentResource.enabled` |
| `45-agent-gateway-api.yaml` | The ingress GatewayClass, the `agent-ingress` Gateway, and its LoadBalancerConfiguration | `ingress.enabled` |
| `46-admission-ingress.yaml` | The `eks-agents-ingress-authenticated` admission policy: every route on the ingress authenticates | `ingress.enabled` with an OIDC issuer |
| `47-ingress-oidc.yaml` | The Role and RoleBinding that let the managed load balancer controller read the direct OIDC client secret | `ingress.enabled` with direct OIDC |
| `50-mesh-authz.yaml` | Istio PeerAuthentication and AuthorizationPolicies | `mesh.mode` isn't `none` and `mesh.authz.enabled` |
| `60-chat-ui.yaml` | The chat UI's Deployment, Service, and authenticated route | `chatUi.enabled`, which needs `ingress.enabled` |

`_agent-pod.tpl`, `_mesh.tpl`, and `_route.tpl` are shared helpers. Every policy template is inert without `10-network-policy-controller.yaml`, and the NodeClass's enforcement mode applies only to nodes launched after it's set. [Network policies for agents](https://docs.aws.amazon.com/eks/latest/userguide/agents-network-policies.html) explains which layer to change for a given control.

## The Agent resource definition

`40-agent-rgd.yaml` is a kro `ResourceGraphDefinition` that registers the `Agent` kind. From one `Agent`, kro composes the agent's ServiceAccount, an IAM role through ACK, a Pod Identity association, its ApplicationNetworkPolicies (plus `-mcp` with `mcpAudience` and `-cluster-api` with `needsClusterApi`), the workload, and a Service. The workload is an Agent Sandbox `Sandbox` by default (`agentResource.defaultRuntime`) or a Deployment with `runtime: deployment`. With the gateway on, it also composes the agent's model backend and route; with `expose: route`, its ingress route and authentication.

Only `image` and `modelArns` are required. [Set up agent applications](https://docs.aws.amazon.com/eks/latest/userguide/agents-application-setup.html) lists every field of the `Agent` resource.

kro resolves every resource's kind when it activates the definition, so a resource whose kind might not be installed is gated with a Helm condition at render time, not with `includeWhen`. The definition renders when `agentResource.enabled` is true, which Terraform sets when `var.agents` is empty: declaring agents in Terraform and using the `Agent` resource are alternatives.

## Values

`values.yaml` documents each key in place. The ones that change the most:

| Key | Effect |
|---|---|
| `path` | `open-source` or `aws-services`. Egress policy, the model name, and the gateway URLs differ by path. |
| `agentResource.enabled` | Whether the `Agent` kind exists. |
| `mesh.mode`, `mesh.authz` | Whether namespaces are enrolled in Istio, and what the mesh enforces. |
| `ingress.enabled`, `chatUi.enabled` | Whether the ingress Gateway, the agents' routes, and the chat UI render. |
| `networkPolicy.inClusterDestinations` | The in-cluster memory Services an agent may reach. Empty on `aws-services`, whose memory is managed services. |
| `model.gatewayModelId` | The model name an agent sends through the gateway. Required on `aws-services` with the gateway on. |

The account, Region, cluster, role ARNs, and endpoints come from `terraform-values.yaml`. The committed copy holds placeholders, and the chart refuses to render the `Agent` resource definition against them.

## Changing it

A change here affects every agent on the cluster. Run `scripts/validate.sh`, which renders this chart against both paths and checks placeholders, guards, workload security settings, and cross-references.
