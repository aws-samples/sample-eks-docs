# A warm pool of pre-booted sandboxes

This example keeps a pool of execution-tier sandboxes booted and Ready, so a session claims one in about a second instead of waiting for a sandbox to boot and pull its image. Use it for interactive or bursty agents that idle between turns, or whose start-up is expensive. A stateless request-and-response agent doesn't need it: `runtime: deployment` on the `Agent` serves that more simply, and one long-lived agent needs only the default `Sandbox`. [Application setup](https://docs.aws.amazon.com/eks/latest/userguide/agents-application-setup.html) in the EKS User Guide compares the three.

| File | What it is |
|---|---|
| `warm-pool.yaml` | The `SandboxTemplate` named `execution`, and the `SandboxWarmPool` named `execution-pool`, which keeps three sandboxes Ready in `agents-execution`. |
| `rbac.yaml` | The `Role` and `RoleBinding` that let the `research` service account in `agents` drive the pool. |
| `claim.yaml` | One session's `SandboxClaim`, with a 10 GiB workspace volume. A reasoning tier creates claims at run time; it's the shape to create, not something to leave applied. |

## Settings in the template

* `networkPolicyManagement: Unmanaged`. With the default, `Managed`, the controller adds its own network policy, which with no rules allows the public internet. The template's pods have no network device (`sandbox.amazonaws.com/network-isolated: "true"`), and the deny-all policy from `gitops/base` covers a pod that loses the annotation.
* `karpenter.sh/do-not-disrupt: "true"`. Nothing reschedules a warm pod whose node is consolidated, drifted, or expired, so without the annotation the pool empties and every claim pays the cold start.
* The claim's pool and namespace are configuration in the reasoning tier's environment, never a tool argument, so the model can't point the tool at another namespace's pool.

## The RBAC is the control

Claiming a sandbox is a Kubernetes API call, so the reasoning tier needs `needsClusterApi: true`, and the scope of its token is the whole control. `rbac.yaml` grants create, get, list, watch, and delete on `sandboxclaims`, read on pods, their logs, and `sandboxes`, and `exec` and `attach` on pods, all in `agents-execution` only. It grants nothing on secrets, and nothing on `sandboxtemplates` or `sandboxwarmpools`: an agent that could edit the template could drop the `network-isolated` annotation.

Agent Sandbox's own MCP server would take the Kubernetes token off the reasoning tier, but every connection type it supports in v1.0.10 reaches the sandbox over the network, so it can't drive a `network-isolated` sandbox. Adopting it means trading the missing network device for a network policy, and the server has no authentication of its own. [VERSIONS.md](../../../VERSIONS.md) records how this was checked.

## Prerequisites

* Agent Sandbox v1.0.10 with its extensions (`extensions: true` in `gitops/platform/<path>/40-agent-sandbox.yaml`), which add `SandboxTemplate`, `SandboxWarmPool`, and `SandboxClaim`. This command must find the CRD:

  ```bash
  kubectl get crd sandboxtemplates.extensions.agents.x-k8s.io
  ```
* The `eks-agents-gp3` StorageClass from `gitops/base/templates/15-storage-class.yaml`, for the workspace in `claim.yaml`. EKS Auto Mode doesn't create a default StorageClass.

## Step 1: Apply the template, the pool, and the RBAC

```bash
kubectl apply -f gitops/examples/warm-pool/warm-pool.yaml
kubectl apply -f gitops/examples/warm-pool/rbac.yaml
```

## Step 2: Wait for the pool to fill

```bash
kubectl -n agents-execution get sandboxwarmpool execution-pool
```

The pool reports three ready replicas. The first fill can take minutes, because EKS Auto Mode may have to launch sandbox-capable instances; once the nodes have room, a refill takes seconds. If the pods stay `Pending` with a node-affinity message, no node can host a sandbox. Sandbox support is per instance type and is published as a node label:

```bash
kubectl get nodes -L eks.amazonaws.com/nitro-sandbox,node.kubernetes.io/instance-type
```

## Step 3: Claim a sandbox

A claim with no workspace adopts a warm pod:

```bash
kubectl apply -f - <<'EOF'
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata:
  name: session-demo
  namespace: agents-execution
spec:
  warmPoolRef:
    name: execution-pool
EOF
kubectl -n agents-execution get sandboxclaim session-demo -o jsonpath='{.status.sandbox.name}{"\n"}'
```

The output names a sandbox from the pool, such as `execution-pool-pjlrs`, within about a second, and the pool boots a replacement.

## Step 4: Confirm the claimed pod has no network

Take the pod's name from the claim's status, because a label selector also matches the idle pods in the pool:

```bash
POD=$(kubectl -n agents-execution get sandboxclaim session-demo -o jsonpath='{.status.sandbox.name}')
kubectl -n agents-execution exec "$POD" -- sh -c 'ls /sys/class/net/'
```

The output lists `dummy0` and `lo`, and no `eth0`: the guest has no interface to carry traffic.

## Step 5: Release the claim

```bash
kubectl -n agents-execution delete sandboxclaim session-demo
```

## Adoption or a durable workspace

A claim that sets `volumeClaimTemplates` doesn't adopt a warm pod, because the warm pods have no such volume. The controller creates a new sandbox with the volume instead, and the pool is unchanged. So choose per session:

| Claim | You get | You give up |
|---|---|---|
| No `volumeClaimTemplates`, as in step 3 | A warm pod in about a second | A workspace that survives suspend. Keep state outside the sandbox, in the session cache or the agent's S3 prefix. |
| `claim.yaml`, with a 10 GiB `ReadWriteOncePod` workspace on `eks-agents-gp3` | A workspace that survives suspend and resume | The cold start the pool exists to avoid |

To create the stateful claim, give it the session's name:

```bash
sed 's/session-REPLACE/session-demo/' gitops/examples/warm-pool/claim.yaml | kubectl apply -f -
```

The template allows the volume with `volumeClaimTemplatesPolicy: Allowed`. The volume claim is immutable once created, and it's owned by the `Sandbox`, so deleting the claim or the sandbox deletes the volume. `claim.yaml` sets `shutdownPolicy: Delete` with a one-hour `ttlSecondsAfterFinished`, so an abandoned session doesn't hold a volume indefinitely.

## Suspend and resume a session

`operatingMode` is a field of the `Sandbox`, not of the `SandboxClaim`. `Suspended` terminates the pod and keeps the `Sandbox` and its volume claim; `Running` boots a new pod on the same volume. No process or memory survives, so a resumed agent continues from a checkpoint on its workspace.

```bash
SB=$(kubectl -n agents-execution get sandboxclaim session-demo -o jsonpath='{.status.sandbox.name}')
kubectl -n agents-execution patch sandbox "$SB" --type=merge -p '{"spec":{"operatingMode":"Suspended"}}'
kubectl -n agents-execution get pvc,pod          # the PVC is Bound and the pod is gone
kubectl -n agents-execution patch sandbox "$SB" --type=merge -p '{"spec":{"operatingMode":"Running"}}'
```

A reasoning tier that suspends its own sessions also needs `patch` on `sandboxes`, which `rbac.yaml` doesn't grant. Add it only if the tier drives suspend.

## Changing the template

A change to the `SandboxTemplate` applies to the next pod the pool boots, not to pods already warm, so a claim made after the change can get a pod built from the old template. The pool's `updateStrategy` decides how long that lasts:

| `updateStrategy` | Stale warm pods |
|---|---|
| `OnReplenish` (the default, used here) | Stay until they're claimed or deleted. |
| `Recreate` | Are deleted and rebooted from the new template when it changes, so the pool is cold while it refills. |

To replace the warm pods without a cold pool, scale the pool's `replicas` down to zero and back, and wait until every warm pod carries the new `agents.x-k8s.io/sandbox-template-hash` label. Claimed pods are never replaced. The Argo CD EKS Capability doesn't include Argo Rollouts, so run the drain by hand or with a Rollouts controller you operate.
