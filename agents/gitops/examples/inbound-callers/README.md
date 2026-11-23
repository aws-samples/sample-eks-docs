# Who may call an agent

This example shows which controls decide who may call an agent on this stack, and the one mesh policy shape that applies to the workloads around the agents. A person at a browser needs no example; that gate is `routeAuth: browser` on the `Agent` resource, described in [Ingress](https://docs.aws.amazon.com/eks/latest/userguide/agents-ingress.html).

## The controls that hold for an agent

Every agent runs in a Nitro sandbox, and a sandboxed pod's traffic isn't captured by ztunnel, so no Istio policy, at Layer 4 or at a waypoint, makes a decision about a call to an agent. What decides is:

| Who is calling | Control | Where it's set |
|---|---|---|
| A workload in the cluster, such as the chat interface or the evaluation runner | The agent's own check of the caller's projected token: its audience must be the agent's name, and its namespace must be the agent's own or one in `callerNamespaces`. Anything else gets `401` from the agent. | `callerNamespaces` on the `Agent`; the reference agent reads `AGENT_ALLOWED_CALLER_NAMESPACES` ([Application setup](https://docs.aws.amazon.com/eks/latest/userguide/agents-application-setup.html)) |
| A workload outside the cluster, such as a service in another account, or a schedule | A token whose subject and audience the load balancer validates before the request reaches the agent, and the agent's own check after it. | `expose: route` with `routeAuth: workload` ([`mcp-ingress/`](../mcp-ingress/README.md), [Ingress](https://docs.aws.amazon.com/eks/latest/userguide/agents-ingress.html)) |
| Which destinations a caller can reach at all | Network policy | [`gitops/base`](../../base) |

## Mesh policy for unsandboxed workloads

A Layer 4 `AuthorizationPolicy` admits a caller by its mesh identity, a certificate both ends verify, on a port. ztunnel enforces it for unsandboxed pods in an enrolled namespace. The reference shape is [`mcp-server/mesh-authz.yaml`](../mcp-server/mesh-authz.yaml), which admits only the gateway to the MCP server. Policies that read a token, a path, or a method need an Istio waypoint, a proxy the stack doesn't deploy: in an agent namespace the admission policy refuses its unsandboxed pods, and a waypoint wouldn't see a sandboxed agent's traffic either.
