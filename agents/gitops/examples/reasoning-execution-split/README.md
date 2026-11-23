# The two-tier agent

This example splits an agent into a reasoning tier that holds the conversation and reaches a model, and an execution tier that runs the code the model writes with no network device at all. Use it when an agent runs untrusted or model-generated code: the strongest containment applies exactly where that code runs, and you pay for it only in that tier.

| File | What it is |
|---|---|
| `reasoning.yaml` | An `Agent` named `research` with `runtime: deployment` and two replicas. |
| `execution.yaml` | A plain Deployment named `execution` in `agents-execution`, with the `sandbox.amazonaws.com/network-isolated: "true"` annotation and no AWS identity. |

## What each tier is

| | Reasoning tier | Execution tier |
|---|---|---|
| Namespace | `agents` | `agents-execution` |
| Runtime class | `isolated-sandbox` | `isolated-sandbox` |
| Network | Egress through the gateway only | No network device |
| AWS identity | Its own IAM role, with model access | None |
| Kubernetes API token | Not mounted | Not mounted |
| State | Session state outside the pod, checkpoints in Amazon S3 | `/workspace`, an `emptyDir` |

The annotation boots the guest with no interface besides loopback: no route out, no DNS, no instance metadata, and no Pod Identity credentials. There's no rule to get around and no policy-enforcement startup window, because there's nothing to program. `kubectl exec`, `cp`, and `logs` still work, because they use the sandbox's control channel rather than a network device; a reasoning tier that drives the execution tier uses them, and needs `needsClusterApi: true` and a scoped Role like the one in [`warm-pool/rbac.yaml`](../warm-pool/rbac.yaml). The deny-all `ApplicationNetworkPolicy` that `gitops/base` ships for `agents-execution` stays in place for a pod template that loses the annotation.

This isn't an exfiltration boundary. Each command's output returns to the reasoning tier, which has a network. The split keeps attacker-controlled code off the half with the network; it doesn't stop data that reaches the execution tier from leaving through the reasoning tier.

The execution tier can't call AWS, so the reasoning tier stages files for it. Amazon EFS can't be mounted without a network; Amazon EBS can, because the node attaches it outside the guest.

Don't use the split for an agent that runs only its own code: the reasoning tier alone under `isolated-sandbox` is enough.

## Prerequisites

* The base chart synced, which creates both namespaces, the admission policy, and the execution tier's deny-all policy. `kubectl get ns agents agents-execution` lists both.
* The agent images in ECR, for `reasoning.yaml`.

## Step 1: Apply both tiers

`reasoning.yaml` carries placeholders (`REPLACE_ECR_URL`, `ACCOUNT_ID`, and a guardrail), so render it. It's an `Agent` named `research` with `runtime: deployment`, so it replaces an existing `research`, such as the User Guide's first agent. `execution.yaml` stands alone: to keep your `research`, apply only `execution.yaml`.

```bash
./scripts/render-example.sh gitops/examples/reasoning-execution-split/reasoning.yaml aws-services | kubectl apply -f -   # or open-source
kubectl apply -f gitops/examples/reasoning-execution-split/execution.yaml
kubectl -n agents-execution rollout status deploy/execution
until kubectl -n agents-execution exec deploy/execution -- true 2>/dev/null; do sleep 5; done
```

The rollout reports `successfully rolled out`. The last line waits until `kubectl exec` reaches the pod: on a node that has just launched, `exec` fails with `tls: internal error` for a few seconds, until the node's kubelet certificate is issued. Set `GUARDRAIL_ARN` before rendering to attach a guardrail; without it, the render drops `guardrailArn` and says so on stderr.

## Step 2: Confirm the execution tier has no route out

This connection attempt must fail. It names an IP address, so a missing resolver can't make it pass.

```bash
kubectl -n agents-execution exec deploy/execution -- python -c "
import socket
try:
    socket.create_connection(('93.184.215.14', 443), timeout=5)
    print('CONNECTED: the execution tier has a route out')
except OSError as e:
    print('no route out: correct --', e)"
```

The output starts with `no route out: correct`.

## Step 3: Confirm there's no default route

A pod with a route and a policy that blocks it passes step 2 and fails this one.

```bash
kubectl -n agents-execution exec deploy/execution -- \
  awk 'NR>1 && $2=="00000000" {d=1; print "DEFAULT ROUTE via " $1} END {if (!d) print "no default route: correct"}' /proc/net/route
```

The output is `no default route: correct`. The `containment` phase of `scripts/exercise.sh` makes the same check against its own probe pod, and also checks that admission refuses an unsandboxed pod and a `hostNetwork` pod.

## Troubleshooting

* `error dialing backend: remote error: tls: internal error` from `kubectl exec`: the pod is on a node that launched seconds ago, and its kubelet serving certificate isn't issued yet. Retry after a minute. `scripts/exercise.sh` retries this error itself.
* Step 2 connects: the annotation didn't reach the pod. This command must print `true`:

  ```bash
  kubectl -n agents-execution get pod -l eks-agents/tier=execution \
    -o jsonpath='{.items[0].metadata.annotations.sandbox\.amazonaws\.com/network-isolated}'
  ```
* `no matches for kind "Agent"` when applying `reasoning.yaml`: the Agent resource definition isn't rendered, because your Terraform variables declare an `agents` map. The header of `reasoning.yaml` describes both fixes.
