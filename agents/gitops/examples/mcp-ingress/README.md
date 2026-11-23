# Exposing an agent to an MCP client through ingress

This example puts an agent behind the shared ingress Gateway with a `jwt-validation` gate, so an MCP client outside the agent's namespace reaches it with a bearer token and the load balancer refuses anything else. It's the hand-written form of what the `Agent` resource composes with `expose: route` and `routeAuth: workload`; use the files when a route needs more than the resource offers, such as path rewriting, header changes, traffic splitting, or a second hostname.

| File | What it is |
|---|---|
| `service.yaml` | A ClusterIP Service named `research`, port 80 to the agent's 8080. |
| `httproute.yaml` | An HTTPRoute on the shared Gateway `agent-ingress`, at `research.<ingress domain>`, with an `ExtensionRef` filter on every rule. |
| `listener-rule-jwt.yaml` | The `ListenerRuleConfiguration`: `jwt-validation` against the cluster's OIDC issuer, requiring both `sub` and `aud`. |

The `Agent` resource composes a Service, an HTTPRoute, and a `ListenerRuleConfiguration` with these same names when an Agent named `research` sets `expose: route`. Don't apply the files on top of an Agent that composes its own; set the Agent's fields instead, or name these objects for a workload the Agent resource doesn't compose.

## How the gate works

* The load balancer stays internal. Its scheme is `ingress.scheme` in `gitops/base/values.yaml` (`internal` by default), set on the shared Gateway, not on an agent's route, so an agent author can't make ingress internet-facing.
* An MCP client gets `jwt-validation`, which answers a bad token with `401`. A browser gate (`authenticate-cognito` or `authenticate-oidc`, from `routeAuth: browser`) answers with a `302` to a sign-in page, which a program can't follow.
* `jwt-validation` checks the signature and only the claims you list, so the rule names both `sub` and `aud`. With `sub` alone, a token for the right service account minted for another audience is accepted.
* The gate attaches from the route to the rule, through an `ExtensionRef` filter on each route rule. A route rule without the filter is served unauthenticated. The `ListenerRuleConfiguration` CRD has no `targetRef` field, and an unknown field is pruned on apply rather than rejected.
* An MCP session lives on the replica that created it, and a load balancer doesn't route on the MCP session ID. Keep session state outside the pod (the session-state rung of the [memory ladder](https://docs.aws.amazon.com/eks/latest/userguide/agents-memory.html)) or route on the session at the gateway. See [Ingress](https://docs.aws.amazon.com/eks/latest/userguide/agents-ingress.html).
* The ALB idle timeout is `ingress.idleTimeoutSeconds` (900 seconds in `gitops/base/values.yaml`). Set it longer than your longest agent turn.

## Prerequisites

* `enable_ingress = true`, which creates the Gateway. EKS Auto Mode runs the load balancer controller, so there's nothing to install. This command lists it:

  ```bash
  kubectl -n agents get gateways.gateway.networking.k8s.io agent-ingress
  ```
* An agent named `research` in `agents` that serves on port 8080, and an MCP client with an identity. In this example the client is the service account `research-client` in the namespace `mcp-clients`, and its token is a projected service account token with audience `research`.
* A host in the VPC for steps 3 and 4, such as the bastion, because the load balancer is internal.

## Step 1: Apply the Service, the route, and the rule

`render-example.sh` fills the issuer, the JWKS endpoint, and the hostname from your rendered values. The `sub` value, `system:serviceaccount:mcp-clients:research-client`, is yours to change in `listener-rule-jwt.yaml`.

The agent also checks its caller's namespace and admits only its own by default, so name the client's namespace on the `Agent`:

```bash
for f in service.yaml httproute.yaml listener-rule-jwt.yaml; do
  ./scripts/render-example.sh "gitops/examples/mcp-ingress/$f" | kubectl apply -f -
done
kubectl -n agents patch agent research --type merge -p '{"spec":{"callerNamespaces":"mcp-clients"}}'
```

Without the patch, a client that passes the load balancer is refused with `401` by the agent.

## Step 2: Confirm the route is accepted

```bash
kubectl -n agents get httproute research \
  -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\n"}'
```

The output is `True`. `False` usually means the hostname isn't covered by the listener's certificate, which is your platform's `ingress.certificateArn`.

## Step 3: Confirm the load balancer is internal

```bash
ADDR=$(kubectl -n agents get gateways.gateway.networking.k8s.io agent-ingress \
  -o jsonpath='{.status.addresses[0].value}')
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[?DNSName=='$ADDR'].Scheme" --output text
```

The output is `internal`.

## Step 4: Confirm the rule refuses what it should

Replace the hostname with `research.<your ingress domain>`, and set `CLIENT_TOKEN` to the client's token and `OTHER_AUD_TOKEN` to a token from the same service account for another audience:

```bash
URL="https://research.agents.internal.example.com/mcp"
curl -s -o /dev/null -w 'no token:        %{http_code}\n' "$URL"
curl -s -o /dev/null -w 'garbage token:   %{http_code}\n' -H 'Authorization: Bearer x.y.z' "$URL"
curl -s -o /dev/null -w 'wrong audience:  %{http_code}\n' -H "Authorization: Bearer $OTHER_AUD_TOKEN" "$URL"
curl -s -o /dev/null -w 'the client:      %{http_code}\n' -H "Authorization: Bearer $CLIENT_TOKEN" "$URL"
```

The first three return `401` from the load balancer, and the last returns anything but `401`. The `ingress` phase of `scripts/exercise.sh` makes the same kind of check against the Agent resource's own routes, and checks that the declared scheme is internal.

## Troubleshooting

* A `200` on any of the first three requests in step 4: the rule isn't attached. Check that every rule in `httproute.yaml` carries the `ExtensionRef` filter that names `research`.
* `ResolvedRefs=False` on the route: a `backendRef` names the container port. It must name the Service's port, `80`.
* A TLS handshake failure with the route `Accepted`: the hostname isn't covered by the certificate.
