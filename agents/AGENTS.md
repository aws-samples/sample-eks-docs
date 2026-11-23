# Working on these templates

These templates are a reference sample. Someone takes them, runs them in their own account, and
gets a working example of an agent platform with no help beyond the README and the User Guide. That is the only
thing they are for, and it is what makes the rule below non-negotiable rather than a preference.

## Nothing stays in the session

**If you did something by hand to get a cluster working, it goes back into `terraform/` or `gitops/`
before the work is called done.** Not into a runbook, not into a handoff note, not into a commit
message — into the code that runs on the next `apply`.

The test is a question: if a reader ran `terraform apply` and followed the README, would they hit
the thing you just worked around? If yes, it is a defect in the templates and the fix belongs in
the templates. A step you performed and did not commit is a step a reader cannot perform at all.

`terraform/modules/bastion` is the worked example. The API endpoint is private by default, so with
the default settings no `kubectl` command in the README works from outside the VPC — including the
step that bootstraps GitOps and the checks that confirm the egress boundary is enforcing. A bastion
built by hand to get around that, and torn down with the cluster, leaves the next reader at a dead
end on step 3. It is in the module and on by default, because a cluster nobody can reach is not a
usable platform. Workstation mode (a public endpoint limited to an allowlist, no bastion) is the
other supported way in, and it is also expressed in Terraform.

So, concretely, when a deploy needs any of these, it is a change to this repository and not a note:

- a host, a role, a security group or a VPC endpoint you created to reach something
- a `kubectl apply`, `helm install` or `aws` call you made that no Application or module makes
- a label, annotation or ConfigMap you set to make a controller behave
- a quota increase, a console toggle, or an account-level setting -- these cannot be coded, so they
  go in the `next_steps` output where someone will actually read them, with the reason
- a version pin you changed to get past a bug, with the issue link and the fixed-in version

If something genuinely cannot be expressed in Terraform or GitOps -- an account setting, a Billing
console action, a browser consent flow -- it belongs in `next_steps` and in `VERSIONS.md`,
stated as a thing the operator must do and why no code can do it. "Document it instead" is
the exception, and it has to be argued rather than assumed.

## Nothing from your account goes back

**No value that belongs to one deployment is ever committed to this repository.** Not an account id,
not an OIDC issuer URL, not an ECR host, not a VPC, subnet, security group or instance id, not a
cache endpoint, not a bucket name, not a cluster name. These templates are published and read by
people applying them in their own accounts, so every value in the tree is a placeholder, a
documentation example, or something true everywhere.

The rule exists because this is a published artifact, and because the same value is wrong three ways
at once. The next reader starts with somebody else's ARNs. Whoever ran the apply has published their
account id and their resource names. And the charts render **cleanly** against values that point at
a cluster the reader cannot reach — which is worse than failing, because the cluster looks
configured.

The file to be careful with is `gitops/platform/<path>/terraform-values.yaml`. It is written by
`terraform apply`, and it is meant to be committed — **to your own fork**, which is where the
workflow in the README sends it. The committed copy in this repository is a placeholder whose values
are invalid on purpose, so the charts' own fail guards refuse to render against them. If your apply
overwrote it, restore the placeholder before committing:

```bash
git checkout gitops/platform/<path>/terraform-values.yaml
```

When you need a value in an example, a doc or a test fixture, use the reserved ones:
`111122223333` and the other AWS documentation account ids, `example.com`, `example.internal`, and
the `*_NOT_SET` sentinels the charts already fail on. A plausible-looking fake is worse than an
obvious placeholder, because nobody can tell it from a real one.

**Turn the hook on, once per clone:** `git config core.hooksPath .githooks`. It runs the check below
over the staged tree before every commit, and it exists because the check alone is easy to skip --
`terraform apply` rewrites `terraform-values.yaml` with your account's values, so the
window between applying and committing is exactly when the tree is unsafe and exactly when a commit
is most likely.

**`scripts/lib/check_no_account_values.py` enforces the half that is mechanical** — account ids,
OIDC issuers, ECR hosts, VPC and subnet and security group and instance ids, Identity Center ARNs,
cache endpoints — and `validate.sh` runs it. A cluster *name* is the half no check can carry, because
`my-agents` is a fine example and `prod-eu-1` is somebody's real cluster. That half is this rule.

This applies to anything else that leaves with the repository: a kubeconfig, a `.tfvars` naming your
network, a rendered manifest, a log paste with your account in the ARN, a screenshot. `.gitignore`
covers the predictable ones; it cannot cover a file you create.

## Changes arrive as pull requests

**Contributions arrive as GitHub pull requests from a branch, and `./scripts/validate.sh` passes on
that branch before the pull request is opened.** Branch, commit there, open a pull request, address
the review, then merge.

A review is built to look at commits *before* they land. A review of code already merged cannot
change what shipped; it can only generate follow-up commits, which is how a two-commit change becomes
four.

**Do not rebase or force-push while a review is open.** Review comments are anchored to commits, and
replacing those commits strands the comments. Push new commits on top, finish the review, merge,
then tidy history if you must.

## The other non-negotiables

- **`./scripts/validate.sh` passes before anything is called done.** It is what catches a rendered
  placeholder, a value from your own account, a policy shape the data plane cannot enforce, and a
  link to a path that doesn't exist.
- **A version-dependent claim gets an entry in `VERSIONS.md` under "Recheck before publishing".**
  "The provider has no resource for this" and "this is broken before version X" are true of a release,
  not of the design, and they go stale while nothing in this tree changes. Write down how to check it
  and what to change if it flipped, so the recheck is a command rather than an investigation.
- **Observed beats reasoned, and say which it was.** Comments in this tree carry the log line, the
  rejection message or the tag containment that establishes a claim. A claim that was reasoned from
  documentation says so, so the next person knows what to re-check.
- **A check that cannot fail is not a check.** `scripts/exercise.sh` asserts refusals, not successes,
  and one manual step proves the egress probe tests something: run it once with enforcement off and
  confirm it succeeds.
- **Verify a teardown rather than declaring one.** `helm uninstall` leaves CRDs behind, and a
  label-selector delete that matches nothing exits 0 and reads exactly like success. Count what is
  left against what was there before.

## Agent skills

Skills live in `.agents/skills/`, one copy each. `.claude/skills` and `.kiro/skills` link to that folder.

| Skill | Use it to |
|---|---|
| `eks-agents-user-guide` | Walk a reader through the Amazon EKS User Guide's agent pages with this repository: the base, then one feature at a time, each confirmed by the page's own check and an exercise.sh phase, timed, with what it installed. It also holds the stage map, with a time for each stage, and a table of symptoms and fixes. It's written for people running the guide, not for changing these templates. |
| `eks-agents-templates` | Find your way around these templates and change them safely: where each piece lives, how one Terraform variable reaches the cluster, the checklist for a new variable, a new layer, an `Agent` field or an `exercise.sh` check, how to verify a change, and the known traps in this code. It assumes the rules above. |
