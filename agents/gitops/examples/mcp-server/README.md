# The reference MCP server

The reference MCP server gives an agent's `tools/list` something to return: three tools over MCP's streamable HTTP transport (a clock, a cluster fact, and a deterministic order lookup). The tools are placeholders for yours; the example shows the path to them, with a verified identity at each hop. Source is in `apps/mcp-server`.

| File | What it is |
|---|---|
| `namespace.yaml` | The `mcp-servers` namespace. Not an agent namespace, so the server runs unsandboxed and its own policy is its whole ingress set. |
| `mcp-server.yaml` | The ServiceAccount, the ClusterIP Service, the `mcp-server-ingress` ApplicationNetworkPolicy, and the Deployment. |
| `mesh-authz.yaml` | An AuthorizationPolicy that admits only the gateway's mesh identity. Open source path with `mesh_mode = "ambient"` only. |
| `caller-token.yaml` | A Deployment patch that adds an `mcp-server` token, for a hand-written agent Deployment only. An `Agent` gets the same token from `mcpAudience`. |

## Who may call it

`scripts/render-example.sh` renders the lines tagged `# mcp-require-token`, `# mcp-gateway`, and `# mcp-direct` for your path.

| Path | Caller | What gates it |
|---|---|---|
| Open source | AgentGateway, from `agentgateway-system`, over the mesh. Agents call the gateway's `/mcp` route, where the tool policy is evaluated. | The network policy admits only the gateway's namespace, and `mesh-authz.yaml` only the gateway's mesh identity. The server checks no token (`MCP_REQUIRE_TOKEN=false`), because the gateway forwards none. |
| AWS services | The agents, directly. AgentCore Gateway runs outside the cluster and can't reach a ClusterIP Service. | The server verifies a projected token with audience `mcp-server` against the cluster's OIDC issuer (`MCP_REQUIRE_TOKEN=true`). The network policy admits the `agents` namespace on port 8080, and an agent can reach `mcp-servers` only when its `Agent` sets `mcpAudience`. |

A sandboxed agent's traffic isn't captured by the mesh, which is why `mesh-authz.yaml` applies to the open source path only. There's no route and no load balancer in front of the server on either path.

## Prerequisites

* The `agents/mcp-server` image in ECR. `./scripts/build-images.sh --root terraform/<path>` builds it with the other images.
* An `Agent` named `research` in the `agents` namespace, for the checks in steps 3 and 4.

## Step 1: Apply the server

Set the path, then apply the namespace and the server. Apply `mesh-authz.yaml` only on the open source path with the mesh on.

```bash
P=open-source   # or aws-services
./scripts/render-example.sh gitops/examples/mcp-server/namespace.yaml $P | kubectl apply -f -
./scripts/render-example.sh gitops/examples/mcp-server/mcp-server.yaml $P | kubectl apply -f -
./scripts/render-example.sh gitops/examples/mcp-server/mesh-authz.yaml open-source | kubectl apply -f -   # mesh_mode = "ambient" only
kubectl -n mcp-servers rollout status deploy/mcp-server
```

The rollout reports `successfully rolled out`. The server refuses to start without `CLUSTER_OIDC_ISSUER`, which the render fills in.

## Step 2: Connect the agent (AWS services path)

On the open source path, skip this step: the gateway already aggregates the server through `mcpServers.reference` in `gitops/charts/agentgateway-config`, selected by the Service's label and its `appProtocol: agentgateway.dev/mcp` port.

On the AWS services path, set the server's URL and audience on the `Agent`:

```yaml
spec:
  mcpUrl: http://mcp-server.mcp-servers.svc.cluster.local:8080/mcp
  mcpAudience: mcp-server
```

The Agent resource projects a second token with audience `mcp-server` and sets `AGENT_MCP_TOKEN_FILE` in the pod's template. A running pod on the default runtime doesn't pick up the change, so recreate it:

```bash
./scripts/roll-agents.sh research
```

The script recreates the pod once its `Sandbox` carries the new token.

## Step 3: List the tools

```bash
./scripts/exercise.sh --path open-source tools   # or --path aws-services
```

The `tools` phase lists the three tools from inside the agent's sandbox with the agent's own token.

## Step 4: Confirm the gate

On the open source path, an agent must not reach the server around the gateway. A call from the agent's pod straight to the Service must time out:

```bash
kubectl -n agents exec "$(kubectl -n agents get pod -l eks-agents/agent=research -o name | head -1)" -c agent -- python -c "
import httpx
try:
    r = httpx.post('http://mcp-server.mcp-servers.svc.cluster.local:8080/mcp', timeout=8,
                   json={'jsonrpc':'2.0','id':1,'method':'tools/list'})
    print('REACHED', r.status_code)
except httpx.HTTPError as e: print('refused:', type(e).__name__)"
```

The output is `refused: ConnectTimeout`. `REACHED 200` means an agent can call tools with the gateway's policy bypassed.

On the AWS services path, the server's own token check is the gate, so a request without a token must return `401`:

```bash
kubectl -n mcp-servers exec deploy/mcp-server -- python -c "
import httpx; r = httpx.post('http://localhost:8080/mcp', json={'jsonrpc':'2.0','id':1,'method':'tools/list'}, timeout=5)
print(r.status_code)"
```

The output is `401`.

## Troubleshooting

* `mcp: no backends configured` with a `503` in the gateway's log: the Service's port is missing `appProtocol: agentgateway.dev/mcp`, or `mcpServers.reference.namespace` doesn't name `mcp-servers`.
* `upstream call timeout` from the gateway while the server is Ready: on the open source path with the mesh on, `mesh-authz.yaml` isn't applied, or its principal names a trust domain other than yours (`cluster.local` unless you changed `mesh.trustDomain`).
* A `tools/list` that returns `200` without a token on the AWS services path: `mcp-server.yaml` was rendered without the `aws-services` argument, so the default open source rendering set `MCP_REQUIRE_TOKEN` to `false`.
