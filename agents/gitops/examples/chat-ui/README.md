# The operator chat UI

The chat UI is a web page in front of your agents, so you can watch a turn run end to end instead of reading it from a log. It's the only service in these templates that a person reaches, so it sits behind a sign-in at the load balancer. This directory holds no manifests: the base chart renders the UI from `gitops/base/templates/60-chat-ui.yaml` when you turn it on. Source is in `apps/chat-ui`.

## How the gate works

1. The load balancer runs the sign-in, from a `ListenerRuleConfiguration` in the `ingress` namespace: `authenticate-cognito`, or `authenticate-oidc` with `ingress_idp = "oidc-direct"`. The rule sets `onUnauthenticatedRequest: authenticate`, so a person without a session is redirected to sign in rather than refused. The load balancer then signs the person's claims into the `x-amzn-oidc-data` header.
2. The UI verifies that header's signature against the Region's load balancer public keys and checks its expiry. A request without a valid header gets `401`, and no setting serves the UI unauthenticated.
3. The UI calls the agent with its own projected token, one per agent, each with that agent's audience. The person's identity travels in `X-Agent-On-Behalf-Of` for the audit trail, not as authority.

Step 3 bounds what a person can do by the agent's IAM role, not by who the person is: anyone who may use the UI can cause anything the agents' roles permit. Scope those roles accordingly; [Acting on behalf of a person](https://docs.aws.amazon.com/eks/latest/userguide/agents-identity-on-behalf-of.html) covers delegating a person's authority.

## Prerequisites

* `enable_ingress = true`, with an identity provider (`ingress_idp`). See [Ingress](https://docs.aws.amazon.com/eks/latest/userguide/agents-ingress.html).
* People to sign in. The Cognito user pool allows administrator-created users only, so people arrive from your identity provider federated into the pool, or through your own process for creating users. Nothing here creates one, except the throwaway user the `signin` phase makes for itself.
* A host in the VPC for step 3, such as the bastion, because the load balancer is internal by default.

## Step 1: Turn on the UI

Set the variables in your Terraform variables file and apply:

```hcl
enable_chat_ui = true
chat_ui_agents = ["research"]   # the Agents the UI offers, by name in the reasoning namespace
```

The apply creates the `agents/chat-ui` ECR repository, adds `chat.<ingress_domain_name>` to the identity provider's callback list, and writes `chatUi` into `terraform-values.yaml`. The chart then renders the Deployment and Service in `agents`, and the route and the sign-in rule in `ingress`. The chart refuses to render the UI without ingress, without an identity provider, or without an image in `registry`.

## Step 2: Build the image and sync

```bash
./scripts/build-images.sh --root terraform/aws-services   # or terraform/open-source
./scripts/run-stack.sh --root terraform/aws-services -- ./scripts/bootstrap-gitops.sh --path aws-services --sync
```

`build-images.sh` builds only the repositories that don't have the tag yet, so it builds `agents/chat-ui` and skips the rest. After the sync, `kubectl -n agents get deploy chat-ui` shows the Deployment ready.

## Step 3: Confirm the gate before you share the URL

From a host in the VPC:

```bash
curl -sS -o /dev/null -D - "https://chat.<your ingress domain>/" | head -5
```

The response is a `302` whose `Location` is your sign-in page (`/oauth2/authorize` on the Cognito pool's domain), with this host's `/oauth2/idpresponse` as the `redirect_uri`. A `200` means no gate ran; don't share the URL.

Then open the URL, sign in, pick an agent, and ask it something. The turn runs in the agent's Nitro sandbox.

## Step 4: Run the chat and signin phases

```bash
./scripts/exercise.sh --path aws-services chat signin
```

The `chat` phase checks from inside the pod that the UI refuses a request without the header and one with a forged header. The `signin` phase signs a person in through the load balancer and relays a turn; with a Terraform root and `ingress_idp = "cognito"` it creates and deletes its own test user with `scripts/ingress-test-user.sh`.

## Troubleshooting

* `kubectl port-forward svc/chat-ui 8080:8080` returns `401`: expected. The port-forward bypasses the load balancer, so no sign-in runs and no `x-amzn-oidc-data` header is attached, and the UI's own check refuses the request.
* A sign-in that works and then a `504`: the target group's health check isn't reaching `/healthz`. The chart sets it through a `TargetGroupConfiguration`; check that it was rendered.
* The pod is in `CrashLoopBackOff`: check `kubectl -n agents logs -l app=chat-ui --tail=25`.
