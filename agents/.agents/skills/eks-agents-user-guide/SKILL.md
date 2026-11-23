---
name: eks-agents-user-guide
description: Walk a reader through the agents section of the Amazon EKS User Guide with this repository, on either path (open source or AWS services). Covers the base, then each feature one change at a time, and running each page's commands as written. Also covers confirming each step with the page's own check and exercise.sh, seeing what each step installed, timing it, and tearing it all down. Use when someone asks you to set up, extend, verify or remove an agent platform on Amazon EKS from these templates, to follow a page of that guide, or to explain why a step's output doesn't match the page.
---

# Run the EKS User Guide's agent pages with this repository

The agents section of the Amazon EKS User Guide is the reader's procedure. This repository is the code that the procedure runs. Keep the two in that relationship:

- **The steps come from the guide.** Run each page's commands as the page writes them, in the page's order. Don't substitute a shortcut you know works, because the point of the walk is that the reader's steps work.
- **The behaviour comes from the code.** When the guide and the repository disagree about what something does, the repository is right. Read the script or the template, then report the guide's sentence as the thing to fix.
- **Observed beats reasoned.** Every claim you make to the reader about a step carries the command and the output line that shows it. "It should be Synced" isn't a result. `all 7 Applications Synced and Healthy after 112s` is.

Paths below are relative to the repository root. `references/stage-map.md` lists every page in the order to run them, with each page's variables, commands, confirming output, exercise phases, what it installs, and the time it takes. `references/symptoms.md` maps what a reader sees when a step goes wrong to its cause and fix. The times are approximate, and vary with the Region and the network.

## Before the first command

Settle these with the reader. Each one changes later steps, and some can't be changed after the first apply.

1. **The path.** `PAVED_PATH=open-source` or `PAVED_PATH=aws-services`. They differ in whether the gateway, memory, telemetry and evaluation run in the cluster or as AWS managed services. Describe the difference from the guide's comparison and let the reader choose. Don't recommend one.
2. **How `kubectl` reaches the cluster.** The base setup has a private-only endpoint and a bastion. Every in-cluster step then runs on the bastion through `scripts/run-stack.sh`, over Session Manager. Workstation mode is the alternative (cluster-setup, "Run from your workstation"): `cluster_endpoint_public_access = true`, `enable_bastion = false`, and every step runs on the reader's machine.
   - **On a network that leaves through a pool of NAT addresses** (a corporate network or a VPN), name the pool's CIDRs in `cluster_endpoint_public_access_cidrs`. An empty list allows only the one address Terraform looked up, and requests from the rest of the pool time out.
   - **After any change of network**, run `./scripts/check-endpoint.sh --root terraform/$PAVED_PATH` before anything else. It names the missing address and the fix. EKS takes about five minutes to roll out a new allowlist.
3. **Ingress, if the reader will turn it on.** It's hard to change later.
   - **A delegated public Route 53 zone** gets an ACM certificate, and in workstation mode an internet-facing load balancer.
   - **Without one**, the choice is `ingress_self_signed_certificate = true` and an internal load balancer. Its names resolve only inside the VPC.
   - **In workstation mode, the page's own manual Step 3 probes need a host in the VPC,** such as the bastion or a pod. Say this before the reader gets to the ingress page, not after. `exercise.sh` handles its own checks: its ingress, `signin`, `people` and `delegation` checks reach an internal load balancer from a short-lived probe pod in the cluster.
4. **Identity Center.** The Argo CD capability needs an instance. Find it with `aws sso-admin list-instances` in the cluster's Region, then in `us-east-1`. If it's in another Region, set `argocd_idc_region`.
5. **Credentials that last.** A long walk outlives a static session token. If the shell's environment holds `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN`, they override a profile whose `credential_process` renews itself. Unset them in every command and the profile carries on. `ExpiredToken` partway through a walk is almost always this, not an expired login.

## The loop for every feature

Every page after the base turns on one feature with the same steps (capabilities-setup, "Turn on a component later"). Run them in this order every time. There is no push: the sync passes the rendered values to the cluster itself.

1. **Set the page's variable** in the reader's variables file.
2. **Apply:** `./scripts/apply.sh --root terraform/$PAVED_PATH -var-file=<file>`. Never a bare `terraform apply`: the script refuses a plan that would replace a stateful or security resource, or that reads one as deleted during refresh.
3. **Sync:** `./scripts/run-stack.sh --root terraform/$PAVED_PATH -- ./scripts/bootstrap-gitops.sh --path $PAVED_PATH --sync`. Wait for its last line: `all N Applications Synced and Healthy after Ns`.
4. **Recreate the agent's pod** when the page says the feature changes the agent: add `--roll-agents` to the bootstrap command. On the default runtime, a `Sandbox` doesn't replace its running pod when its spec changes. Check that the `Sandbox` shows the new variable before you roll, with the page's `grep`.
5. **Verify with the page's own commands**, then with the page's `exercise.sh` phase. Show the reader the confirming line from each.
6. **Confirm the step installed only what the page describes.** Compare Terraform's state and the cluster's Applications, namespaces, workloads and CRDs before and after. An addition the page doesn't name is a finding about the guide, even when it's harmless.

A component turned off with only its chart value keeps running. Only the Terraform variable controls whether Argo CD syncs it. To turn one off, set the variable to `false`, apply, and sync with `--prune`.

## Reading results correctly

- **`exercise.sh` asserts refusals, not successes.** A phase passes when the wrong caller is refused. Read its `✓`, `✗` and `!` lines, not its exit code alone. `!` is a skip and always says why. A layer that's off skips.
- **An `Agent` reads `ACTIVE` only once its agent is running.** That means the `Sandbox` is Ready, the Agent is suspended, or every replica is available. Otherwise it reads `IN_PROGRESS`, and the `Sandbox`'s Ready condition says why (application-setup, Step 3).
- **The root Application `eks-agents-platform` has no automated sync.** Judge convergence by the child Applications. The bootstrap script's last line counts them.
- **The first sync of a large layer takes minutes, and that isn't a fault.** For example, Langfuse's web pod restarts until its databases are ready. `references/stage-map.md` has the time each page takes. Wait at least that long before calling a step stuck, and say so.
- **Telemetry arrives after the agent's first export.** The collector's `strands_` metrics are empty right after the first turn and present a minute later (observability, Step 3).

## Running long steps

- **Run long steps in the background and watch them.** Apply, sync, builds and the full `exercise.sh` run take minutes each, and the base apply takes about 20 minutes. Don't block on them. Report progress at each step, and flag a stall within minutes, not at the end.
- **On the bastion, a command prints nothing until it ends.** Session Manager returns output then. `run-stack.sh` prints a "still running on the bastion" line each minute, so silence between those lines isn't a hang.
- **Never edit a script while it runs.** Bash reads a running script as it goes, so an edit mid-run corrupts the run. Stop it, edit, and start again from the step that failed.
- **Time every step,** and keep the times with the outputs. The reader will ask how long the platform takes to stand up, and the per-page times in `references/stage-map.md` are the baseline to compare against.

## Nothing from the reader's account goes into any repository

Argo CD reads the platform's code from the public repository at `gitops_repo_revision`. The values `apply.sh` renders, which name the reader's account, cluster, OIDC issuer and ECR repositories, stay in files beside the platform chart (`gitops/platform/<path>/*-values.yaml`). `bootstrap-gitops.sh` passes them to the cluster in the root Application, so an edit to one of them, such as a release-gate case, reaches the cluster on the next sync. Nothing is committed or pushed.

Files the pages save in the repository root, such as `my-agent.yaml`, `chat.sh` and `agents-app.yaml`, are gitignored for the same reason. A repository of the reader's own is needed only for changed templates, or for application setup Step 6, which manages `Agent` manifests from Git: `gitops-mirror.sh create` and `push`, then `gitops_repo_url`, `gitops_repo_path = ""` and `gitops_repo_revision`.

## Tearing it down

Follow cluster-setup, "Clean up":

1. Dry-run the teardown first: `./scripts/teardown.sh --path $PAVED_PATH --cluster <name> --region <region> --root terraform/$PAVED_PATH --cluster-going-away`.
2. Run it with `--yes --destroy-with <file>`.
3. If the reader made a repository with `gitops-mirror.sh create`, delete it: `./scripts/gitops-mirror.sh delete --name <name> --region <region>`.
4. Delete anything the reader created outside the stack for a page's example, such as a DynamoDB table for the on-behalf-of entry.
5. Run `--sweep-only` and show the reader its last lines.

A teardown is done when the sweep reports no leftovers, not when `terraform destroy` returns. The sweep lists a CodeCommit repository made by `gitops-mirror.sh` as a reminder, not a leftover.

## Reporting to the reader

At each step, give the reader four things:

- the commands as the page gives them;
- the output lines that confirm the step;
- the step's time;
- what it installed.

At the end, give them:

- a table by stage;
- every difference from the guide, as a guide finding with the output that shows it;
- every manual step or workaround you needed, as a change to make in the repository so the next reader doesn't need it;
- what's still running and billing.

Keep the reader's account values out of anything they'll share.
