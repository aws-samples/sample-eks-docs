#!/usr/bin/env python3
"""Refuse a commit that carries one deployment's own account, cluster or endpoints.

Run from the repository root:

    python3 scripts/lib/check_no_account_values.py

WHY THIS EXISTS. These templates are published. A reader clones them and applies them in their own
account, so every value in the tree has to be a placeholder, an example, or something true
everywhere. A real one is wrong three ways at once: the reader starts with somebody else's ARNs,
the owner of those ARNs has published their account id and resource names, and the charts render
cleanly against values that point at a cluster the reader cannot reach -- which is worse than
failing, because it looks configured.

The file most at risk is gitops/platform/<path>/terraform-values.yaml. It is written by
`terraform apply` and is *meant* to be committed -- to a fork. After an apply it carries the
account id, the OIDC issuer, the ECR repository URLs, the checkpoint bucket and the cluster name.

WHAT COUNTS AS A PLACEHOLDER, deliberately narrow: the AWS documentation account ids, `example.com`
and friends, and the `*_NOT_SET` sentinels these charts fail on. Anything else that looks like a
real account id, a real OIDC issuer, a real ECR host or a real queue/bucket ARN is a finding.

This cannot catch a cluster NAME, because a cluster name is just a word -- `my-agents` is a fine
example and `prod-eu-1` is somebody's real one. That half is a rule in AGENTS.md, not a check.
"""

import os
import re
import subprocess
import sys

# AWS's own documentation placeholders, plus the ones these templates use.
ALLOWED_ACCOUNTS = {
    "111122223333",  # AWS docs example account
    "444455556666",  # AWS docs second example account
    "222233334444",  # AWS docs third example account
    "555555555555",
    "123456789012",  # widely used in AWS docs and the provider's own examples
    "000000000000",
}

ALLOWED_SUBSTRINGS = (
    "ACCOUNT_ID_NOT_SET",
    "CLUSTER_NOT_SET",
    "REGION_NOT_SET",
    "OIDC_ISSUER_NOT_SET",
    "REPLACE_",
    "<account>",
    "<region>",
    "<cluster>",
    "example.com",
    "example.internal",
    "amazonaws.com/amazonlinux",  # public ECR paths
    "public.ecr.aws",
)

SKIP_DIRS = {".git", ".terraform", "refs", "__pycache__", "build", "node_modules"}
SKIP_SUFFIXES = (".png", ".svg", ".drawio", ".lock.hcl")

# A 12-digit run that is not part of a longer number. Deliberately loose: a false positive is a
# line to read, a false negative is a published account id.
ACCOUNT = re.compile(r"(?<!\d)(\d{12})(?!\d)")

# The parts of a rendered deployment that are unambiguously one account's.
PATTERNS = [
    (re.compile(r"oidc\.eks\.[a-z0-9-]+\.amazonaws\.com/id/([0-9A-F]{32})", re.I),
     "an EKS cluster's OIDC issuer id"),
    # The account id is captured so an allowed one -- the docs placeholder in an example URI --
    # does not report. Without that, every example image URI is a finding.
    (re.compile(r"\b(\d{12})\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com"),
     "a private ECR registry host"),
    (re.compile(r"\b[a-z0-9.-]+\.(?:serverless|cache)\.[a-z0-9-]+\.cache\.amazonaws\.com"),
     "a real ElastiCache endpoint"),
    (re.compile(r"\bvpc-[0-9a-f]{8,17}\b"), "a VPC id"),
    (re.compile(r"\bsubnet-[0-9a-f]{8,17}\b"), "a subnet id"),
    (re.compile(r"\bsg-[0-9a-f]{8,17}\b"), "a security group id"),
    (re.compile(r"\bi-[0-9a-f]{17}\b"), "an EC2 instance id"),
    (re.compile(r"\barn:aws:sso:::instance/ssoins-[0-9a-f]+"), "an Identity Center instance ARN"),
]


def interesting(path: str) -> bool:
    if any(path.endswith(s) for s in SKIP_SUFFIXES):
        return False
    return path.endswith((".tf", ".tfvars", ".yaml", ".yml", ".json", ".md", ".sh", ".py",
                          ".tftpl", ".hcl"))


# A TOKEN is a run of characters with no whitespace, quote or bracket in it: a URI, an ARN, a word.
TOKEN = re.compile(r"""[^\s"'`,;()\[\]{}<>]+""")


def allowed_spans(line: str) -> list:
    """The spans of the tokens that carry an allowed substring.

    ONLY THOSE TOKENS are exempt, not the whole line. A line exempt because it names
    `public.ecr.aws` somewhere would otherwise hide a real account id anywhere else on it. The
    placeholders written with angle brackets (`<account>`) are matched as themselves, since the
    brackets end a token.
    """
    spans = []
    for sub in ALLOWED_SUBSTRINGS:
        start = 0
        while (i := line.find(sub, start)) != -1:
            lo, hi = i, i + len(sub)
            for t in TOKEN.finditer(line):
                if t.start() <= i < t.end():
                    lo, hi = min(lo, t.start()), max(hi, t.end())
            spans.append((lo, hi))
            start = i + 1
    return spans


def line_findings(line: str) -> list:
    """(what, value) for each account-specific value on one line, outside the allowed tokens."""
    spans = allowed_spans(line)

    def exempt(m):
        return any(lo <= m.start() and m.end() <= hi for lo, hi in spans)

    out = []
    for pattern, what in PATTERNS:
        for m in pattern.finditer(line):
            # A pattern with a capture group puts the account id in it; an allowed
            # account there makes the whole match an example rather than a finding.
            if exempt(m) or (m.groups() and m.group(1) in ALLOWED_ACCOUNTS):
                continue
            out.append((what, m.group(0)))
    for m in ACCOUNT.finditer(line):
        if not exempt(m) and m.group(1) not in ALLOWED_ACCOUNTS:
            out.append(("an AWS account id", m.group(1)))
    return out


def self_test() -> int:
    """Lines that must and must not be reported. `--self-test` runs them; validate.sh does too."""
    # Assembled, so this file holds no literal account id or VPC id for the tree scan to report.
    real = "7" * 4 + "1" * 4 + "9" * 4
    vpc = "vpc-" + "0123456789abcdef0"
    cases = [
        # (line, reported?)
        (f"image: public.ecr.aws/docker/library/python:3.13  # account {real}", True),
        (f"example.com {real}", True),
        (f"{real}.dkr.ecr.us-east-1.amazonaws.com/amazonlinux:2023", False),
        ("account: ACCOUNT_ID_NOT_SET", False),
        (f"arn:aws:iam::{real}:role/x", True),
        ("arn:aws:iam::111122223333:role/x", False),
        ("image: 111122223333.dkr.ecr.us-west-2.amazonaws.com/agents/reasoning:v1", False),
        (f"image: {real}.dkr.ecr.us-west-2.amazonaws.com/agents/reasoning:v1", True),
        (vpc, True),
        (f"host: agents.example.com {vpc}", True),
    ]
    failed = 0
    for line, want in cases:
        got = bool(line_findings(line))
        if got != want:
            failed += 1
            print(f"      ✗ self-test: {line!r} reported={got}, expected {want}")
    if failed:
        return 1
    print(f"      ✓ self-test: {len(cases)} lines classified as expected")
    return 0


def tracked_files() -> list:
    """Only what git tracks.

    The subject of this check is what gets COMMITTED, so walking the filesystem is the wrong scope:
    it reports a local `my.tfvars` naming your own account, which is the file .gitignore exists to
    keep out and the one place those values are SUPPOSED to be. A check that fires on correct local
    state is a check people learn to skip.
    """
    out = subprocess.run(["git", "ls-files", "-z"], capture_output=True, text=True)
    if out.returncode != 0:
        # Not a git tree -- fall back to walking, so this still works on an extracted archive.
        found = []
        for root, dirs, names in os.walk("."):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            found += [os.path.join(root, n).removeprefix("./") for n in names]
        return found
    return [p for p in out.stdout.split("\0") if p]


def staged_contents() -> dict:
    """What the commit will carry: each path's content in the INDEX, not on disk.

    The pre-commit hook passes --staged. Reading the working tree there would refuse every commit
    made after a `terraform apply` -- the apply rewrites terraform-values.yaml in place, the file
    stays tracked and modified, and a commit of an unrelated file (a release-gate case, an Agent
    manifest) would be refused for content it does not carry. A rendered file
    that IS staged is still refused, which is the case this check exists for.
    """
    ls = subprocess.run(["git", "ls-files", "-s", "-z"], capture_output=True, text=True, check=True)
    entries = []
    for rec in ls.stdout.split("\0"):
        if not rec:
            continue
        meta, path = rec.split("\t", 1)
        mode, sha, _stage = meta.split()
        if mode.startswith("1") and interesting(path):
            entries.append((path, sha))
    if not entries:
        return {}
    cat = subprocess.run(["git", "cat-file", "--batch"], input=("\n".join(sha for _, sha in entries) + "\n").encode(),
                         capture_output=True, text=False, check=True).stdout
    out, pos = {}, 0
    for path, _sha in entries:
        header_end = cat.index(b"\n", pos)
        size = int(cat[pos:header_end].split()[2])
        start = header_end + 1
        out[path] = cat[start:start + size].decode("utf-8", errors="replace")
        pos = start + size + 1
    return out


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    findings = []
    if "--staged" in sys.argv[1:]:
        contents = staged_contents()
        sources = [(path, lambda path=path: contents[path]) for path in contents]
    else:
        def read(path):
            return open(path, encoding="utf-8", errors="replace").read()
        sources = [(path, lambda path=path: read(path)) for path in tracked_files()]
    for path, load in sources:
        if True:
            if not interesting(path):
                continue
            try:
                lines = load().split("\n")
            except OSError:
                continue
            for n, line in enumerate(lines, 1):
                for what, value in line_findings(line):
                    findings.append((path, n, what, value))

    if not findings:
        print("      ✓ no account-specific value in the tree")
        return 0

    print("      ✗ values from one deployment are committed. These belong in a fork, not here:")
    for path, n, what, value in findings[:40]:
        print(f"        {path}:{n}  {what}: {value}")
    if len(findings) > 40:
        print(f"        ... and {len(findings) - 40} more")
    print()
    print("      If this is a rendered file, restore its placeholder form and commit the real one")
    print("      to your own fork. If it is documentation, use 111122223333 and example.com.")
    print("      If the value genuinely is public, add it to ALLOWED_* in this script with a reason.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
