# What the reader sees, why, and what to do

Each row is a symptom these templates produce. Look up the symptom before changing anything. Several of these look like a failure and aren't.

## Reaching the cluster

| Symptom | Cause | Do this |
|---|---|---|
| `kubectl` or `run-stack.sh` times out against the public endpoint | This machine's address isn't in `cluster_endpoint_public_access_cidrs`. A public endpoint doesn't refuse an address outside its allowlist; the connection times out instead. | Run `./scripts/check-endpoint.sh --root terraform/$PAVED_PATH`. It prints the allowlist, this machine's address from two lookups, and the fix. Add the address or the NAT pool's CIDRs, apply, then wait about five minutes. |
| The endpoint worked, then stopped partway through | The machine changed networks: off or on a VPN, or to another NAT member | Same as above. Once the new address is added, the endpoint answers within about two minutes of the apply. |
| `ExpiredToken` from every `aws`, `terraform` and `run-stack.sh` call | Static `AWS_*` keys in the shell's environment have expired. They override a profile that would renew itself. | `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN`, then retry. Ask the reader to log in again only if the profile itself fails. |
| A bastion step prints nothing for minutes | Session Manager returns a command's output only when the command ends | Wait. `run-stack.sh` prints a "still running on the bastion" line each minute. |
| A `kubectl ... -w` or `logs -f` through `run-stack.sh` prints nothing, then fails after an hour | The command never ends on its own, and Session Manager returns output only when it ends: `run-stack.sh` waits its full `--timeout`, 3600 s by default | Stop it, and run a form that ends: `kubectl wait --for=condition=Ready ... --timeout=120s`, then a plain `get`. For a sandbox claim: `kubectl -n agents-execution wait --for=condition=Ready sandboxclaim/session-1234 --timeout=120s` |

## Syncing

| Symptom | Cause | Do this |
|---|---|---|
| `eks-agents-platform` is OutOfSync | The root Application has no automated sync, by design | Judge by the child Applications and by the bootstrap script's last line |
| An Application stays `Progressing` after its objects are ready | Argo CD kept the health it computed while the objects were starting | Run the bootstrap script again (capabilities-setup, "Turn on a component later") |
| `langfuse-web` in `CrashLoopBackOff` during the observability sync | It restarts until ClickHouse, Postgres and its object storage are ready | Wait. The sync converges in about 5 minutes. |
| A feature is on, but the agent doesn't have its variable | On the default runtime, a `Sandbox` doesn't replace its running pod when its spec changes | Grep the `Sandbox` for the variable, then run `bootstrap-gitops.sh --sync --roll-agents` |
| The chat UI's pods are in `ImagePullBackOff` | The sync ran before `build-images.sh` | Build, then sync again (ingress, Step 4) |

## The agent

| Symptom | Cause | Do this |
|---|---|---|
| `Agent` reads `IN_PROGRESS` | The agent isn't running yet | Read the reason: `kubectl -n agents get sandbox <name> -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'` (application-setup, Step 3) |
| The first agent takes a minute or more to become Ready | EKS Auto Mode is launching a sandbox-capable node | Wait. The first agent takes a minute or two; later agents start faster on the running node. |
| After the gateway is on, the agent can't reach the model | It's still on `agents/reasoning-direct`, or its pod predates the gateway | Move the image to `agents/reasoning`, apply the Agent, then `--roll-agents` (gateway, Prerequisites and Step 1) |
| A direct connection to Bedrock from the agent's pod succeeds | Network policy isn't enforced for that pod | Stop and check `enable_network_policy` and the agents' NodeClass. Timing out is the correct result. |

## Checks

| Symptom | Cause | Do this |
|---|---|---|
| The page's own ingress probes don't resolve from the reader's machine | The load balancer is internal, and in workstation mode the machine is outside the VPC | Run the page's probes from a host in the VPC, such as the bastion or a pod, or use an internet-facing load balancer with a delegated public zone (ingress, "Internet-facing load balancer for workstation mode"). `exercise.sh` reaches the internal load balancer from its own short-lived probe pod. It skips its ingress-dependent checks only if that pod can't become Ready, and it says so. |
| A route's host name doesn't resolve for minutes after the sync, then does | A lookup made before ExternalDNS wrote the record cached "no such name" for the zone's negative TTL: 900 s on a zone whose TTL the apply hasn't set to 60 s yet | Wait, or apply again to set the 60 s TTL (`module.ingress.terraform_data.negative_ttl`). At a 900 s TTL the name can take several minutes to resolve; at 60 s, about a minute. |
| The page's ingress probes print `HTTP/2 401` | Correct: the load balancer refused them | Only `server: awselb/2.0` counts as the gate. A `401` from the agent's own server means the gate let the request through. |
| The collector lists no `strands_` metrics | The agent hasn't exported since its first turn | Send a turn, wait a minute, and read the list again (observability, Step 3) |
| The `evals` phase skips the gate: "no experiment CronJob" | The release-gate cases weren't added, or no sync followed | evaluations, Step 2: add the case to `agent-evals-values.yaml`, push, and sync |

## Teardown

| Symptom | Cause | Do this |
|---|---|---|
| The sweep lists a CodeCommit repository | The teardown leaves a repository made with `gitops-mirror.sh`, by design | `./scripts/gitops-mirror.sh delete --name <name> --region <region>` |
| The sweep reports "1 resource still tagged" for the cluster | Usually something the reader created for an example and tagged with the cluster's name, such as a DynamoDB table | Delete it, then run `--sweep-only` again |
| Namespace deletion times out during `--cluster-going-away` | The cluster is going away. Those waits don't block anything that follows. | Let it continue. The destroy and sweep are the result that matters. |

## AWS services path

| Symptom | Cause | Do this |
|---|---|---|
| A model call returns `403` with `No policy applies to the request` | The agent has no Cedar permit: it isn't in `gateway_permitted_agents` | Add it (name, or namespace/name), apply. The permits are Terraform resources, so nothing needs to sync (gateway, Step 1). |
| A model call returns `403` naming `forbid_unlisted_principals` | Correct for a caller outside `gateway_permitted_agents`: the baseline forbid refused it | Nothing, unless the caller should be allowed; then add it to the list and apply |
| `403 insufficient_scope` on every agent from the first request | `allowed_clients` is set on the gateway's authorizer | Leave `allowed_agent_subjects = []`, or list every agent's subject (gateway, Step 2) |
| `403 insufficient_scope` on one agent only | Its subject isn't in `allowed_agent_subjects` | Add `system:serviceaccount:<namespace>:<name>` and apply |
| Calls work, then fail later with `403 insufficient_scope` | The gateway token expired: it lives 600 s, and the agent cached it | The reference agent reads the token file on each request. Code of your own must do the same. |
| A model call returns `404` naming the model | `AGENT_MODEL` isn't in the gateway connector's catalog | List the catalog with the inference page's `/models` command and set `gateway_model_id` to a listed name |
| The agent can't reach the model right after the gateway is turned on | It's still on `agents/reasoning-direct`, which has no gateway route | Move the image to `agents/reasoning`, apply the Agent, then `--roll-agents` (gateway, Step 1) |
| The session-state `PING` times out | Right after the apply, the ElastiCache Serverless cache is still starting; or the check used plain TCP | Use the page's TLS form (`ssl.create_default_context().wrap_socket`), and run it again a minute later before looking at network policy. `-NOAUTH Authentication required.` is the pass. |
| A task's result is `"status": "incomplete"`, `"the model returned no text"` | The model answered nothing, twice (the worker retries an empty turn once) | Send the task again. The model occasionally returns an empty turn. |
| `ingress_self_signed_certificate = true` probes print nothing | curl doesn't trust the generated certificate | `terraform -chdir=terraform/$PAVED_PATH output -raw ingress_certificate_pem > ca.pem`, then add `--cacert ca.pem` to each `curl` |
| Two `vpc_endpoints` more than the list names | `agentcore-gateway` is added whenever the gateway and `agentcore` are both on, and `oidc-eks` whenever `eks` is listed | Nothing; both are expected |

