#!/usr/bin/env python3
"""Refuse a Terraform plan that would replace a stateful or security resource, or that read one as
deleted. Used by scripts/apply.sh.

    terraform -chdir=<root> show -json <plan> | python3 scripts/lib/plan_guard.py [--allow-replace]
    python3 scripts/lib/plan_guard.py --self-test

WHY. The AWS provider's refresh can read an existing, non-empty checkpoint bucket as deleted -- a
single bad read -- and plan to "create" it. To get there Terraform first DESTROYS the bucket's
public access block, TLS-only policy, encryption, ownership controls, lifecycle and versioning on
the real bucket, then fails with BucketAlreadyOwnedByYou. The plan says so in two ways, both of
which this refuses:

  drift   "module.checkpoints[0].aws_s3_bucket.checkpoints has been deleted": resource_drift with a
          delete action, on a resource whose remote object exists.
  replace the bucket's six settings resources "must be replaced": delete and create in one change.

WHAT PASSES. A plain delete passes: turning a feature off (enable_person_access = false) deletes
its bucket on purpose, and an apply that does that should go through. Creates and in-place updates
pass. So the guard is narrow -- it refuses the two shapes that a wrong read produces, on the types
whose loss costs data or a security setting -- and --allow-replace lets a deliberate replacement
through.
"""
from __future__ import annotations

import json
import sys

# Stateful, or a security setting on something stateful. A prefix match on the resource type.
PROTECTED = (
    "aws_s3_bucket", "aws_s3vectors_", "aws_sqs_queue", "aws_cognito_user_pool", "aws_iam_",
    "aws_eks_cluster", "aws_eks_capability", "aws_secretsmanager_secret", "aws_kms_",
    "aws_ecr_repository", "aws_route53_zone", "aws_elasticache_", "aws_db_", "aws_rds_",
    "aws_bedrockagentcore_memory",
)


def protected(rtype: str) -> bool:
    return rtype.startswith(PROTECTED)


def findings(plan: dict) -> tuple[list[str], list[str]]:
    """(refusals, notes): refusals stop the apply unless --allow-replace."""
    refuse, notes = [], []
    for d in plan.get("resource_drift") or []:
        acts = (d.get("change") or {}).get("actions") or []
        if "delete" in acts and protected(d.get("type", "")):
            refuse.append(f"{d['address']}: refresh read it as DELETED. Confirm it is really gone before "
                          f"applying -- a bad read here makes the apply re-create it and replace everything "
                          f"that depends on it")
    for c in plan.get("resource_changes") or []:
        acts = (c.get("change") or {}).get("actions") or []
        if not protected(c.get("type", "")):
            continue
        if "delete" in acts and "create" in acts:
            refuse.append(f"{c['address']}: would be REPLACED (destroyed, then created)")
        elif acts == ["delete"]:
            notes.append(f"{c['address']}: will be deleted")
    return refuse, notes


def self_test() -> int:
    bucket = "module.checkpoints[0].aws_s3_bucket.checkpoints"
    cases = [
        ("a wrong read: drift delete + replaced settings",
         {"resource_drift": [{"address": bucket, "type": "aws_s3_bucket", "change": {"actions": ["delete"]}}],
          "resource_changes": [
              {"address": bucket, "type": "aws_s3_bucket", "change": {"actions": ["create"]}},
              {"address": "module.checkpoints[0].aws_s3_bucket_public_access_block.checkpoints",
               "type": "aws_s3_bucket_public_access_block", "change": {"actions": ["delete", "create"]}}]},
         True),
        ("a feature turned off deletes its bucket",
         {"resource_changes": [{"address": "module.person_access[0].aws_s3_bucket.people", "type": "aws_s3_bucket",
                                "change": {"actions": ["delete"]}}]}, False),
        ("creates and updates",
         {"resource_changes": [{"address": "a.aws_sqs_queue.x", "type": "aws_sqs_queue", "change": {"actions": ["create"]}},
                               {"address": "a.aws_iam_role.r", "type": "aws_iam_role", "change": {"actions": ["update"]}}]},
         False),
        ("a replaced local file is not protected",
         {"resource_changes": [{"address": "local_file.gitops_values[0]", "type": "local_file",
                                "change": {"actions": ["delete", "create"]}}]}, False),
        ("a replaced IAM role is refused",
         {"resource_changes": [{"address": "a.aws_iam_role.r", "type": "aws_iam_role",
                                "change": {"actions": ["create", "delete"]}}]}, True),
    ]
    bad = 0
    for name, plan, want in cases:
        got = bool(findings(plan)[0])
        print(("  PASS " if got == want else "  FAIL ") + f"{name}: {'refused' if got else 'allowed'}")
        bad += got != want
    print(f"{len(cases) - bad}/{len(cases)} passed")
    return 1 if bad else 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    allow = "--allow-replace" in sys.argv
    plan = json.load(sys.stdin)
    refuse, notes = findings(plan)
    for n in notes:
        print(f"plan-guard: note: {n}")
    if not refuse:
        print("plan-guard: no protected resource is replaced or read as deleted")
        return 0
    for r in refuse:
        print(f"plan-guard: {r}", file=sys.stderr)
    if allow:
        print("plan-guard: --allow-replace given; applying anyway", file=sys.stderr)
        return 0
    print("plan-guard: refused. Check each resource above in the console or the CLI. If the plan is "
          "what you intend, run again with --allow-replace.", file=sys.stderr)
    return 3


if __name__ == "__main__":
    sys.exit(main())
