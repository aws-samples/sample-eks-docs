# consent-receiver chart

The OAuth consent receiver, on both paths: a person approves a third-party service once, and the agent's calls through the gateway carry the resulting token. Read this before you add an OAuth client.

The `consent-receiver` Application in `gitops/platform/<path>/46-consent-receiver.yaml` installs it at sync wave 3, in the `consent` namespace. It syncs when `enable_gateway` is on and a client is set: `oauth_consent` on the open source path, `agentcore_consent` on the AWS services path. The receiver's code is in [`apps/consent-receiver/`](../../../apps/consent-receiver), and [Third-party credentials for agents](https://docs.aws.amazon.com/eks/latest/userguide/agents-third-party-credentials.html) covers the flow.

## What it renders

| Objects | Rendered when |
|---|---|
| The ServiceAccount and the Deployment, which binds `127.0.0.1` and has no Service | `consent.enabled` |
| A NetworkPolicy that admits no ingress | `consent.enabled` |
| A Role to mint tokens for the named agents' service accounts, for AgentCore Gateway's session binding | A client with `mode: agentcore` |
| A Role to restart the platform secrets syncer, so the gateway mounts a new token | An open source client |

All of it is in `templates/receiver.yaml`.

## Reach it

The receiver is reached only through `kubectl port-forward`, so who may grant a consent is decided by your cluster's authentication and `pods/portforward` RBAC:

```bash
kubectl -n consent port-forward deploy/consent-receiver 8765
```

The default base URL is `http://localhost:8765` (`consent.publicBaseUrl`). For an open source client, register `<base URL>/callback/<client>` as the provider's callback URL; for an AgentCore client, set `<base URL>/complete/<client>` as the credential provider's return URL.

## Values

`consent.clients`, `region`, and `registry` come from `terraform-values.yaml`. The chart refuses to render with no clients or no `agents/consent-receiver` image in the registry.
