#!/usr/bin/env python3
"""Refuse a Cedar `permit` whose principal is unconstrained.

WHY THIS IS A BUILD FAILURE AND NOT A STYLE NOTE. On the aws-services path an AgentCore Gateway
admits exactly one Kubernetes service account subject or every one, so a platform running more than
one agent leaves `allowed_agent_subjects` empty and the gateway's door admits every subject its
audience accepts. The per-agent decision then belongs entirely to the policy engine, whose Cedar
principal `AgentCore::OAuthUser` carries that same `sub` claim as its entity id.

A permit written `permit(principal, action in ..., resource == ...)` applies to EVERY admitted
caller. One of those beside a correct per-agent policy set re-opens the gateway to everything, and
nothing reports it: the policy validates, reaches ACTIVE, and the engine still reports ENFORCE.
A service account named by no policy at all then gets a 200 from both the model and a tool.

`principal == ...` and `principal in ...` are constrained and pass. `principal is <Type>` alone is
NOT: on this gateway every caller is an AgentCore::OAuthUser, so `principal is AgentCore::OAuthUser`
admits every one of them, exactly like the bare keyword. `principal is <Type> in ...` passes.
A `forbid` is not checked: an unconstrained forbid is a deny, and fails closed.

COMMENTED-OUT POLICIES ARE CHECKED TOO, and that is deliberate. The commented examples in
example.tfvars are the only documentation of the shapes this path cannot demonstrate live -- a
temporal policy needs two tools -- so an example teaching an unconstrained principal is the same
defect one step removed. A leading `#` is stripped before matching for that reason.

Reads one .tfvars file. Exits 1 on a finding, printing the file, the policy key and the statement.
"""
import re
import sys

# `cedar_policies` and `dogwood_policies` take the same shape: a map of keys to objects with a
# `statement`. The statement is an HCL string, so the quotes inside it arrive escaped.
STATEMENT = re.compile(r'statement\s*=\s*(?:"((?:[^"\\]|\\.)*)"|<<-?(\w+)\n(.*?)\n\s*\2)', re.S)

# The key the statement belongs to, for a message that names something findable. The nearest
# preceding `<key> = {` wins -- and it has to match a commented key as well, or a finding inside a
# commented example is attributed to the last live policy above it, which is the wrong file to go
# and edit.
KEY = re.compile(r'^\s*#?\s*([A-Za-z_][\w-]*)\s*=\s*\{', re.M)

# `permit (` with optional whitespace, then a principal that is the BARE keyword or a type test
# alone: followed by a comma or close-paren rather than by == or in. The same rule as the
# cedar_policies and dogwood_policies validations in terraform/aws-services/variables.tf.
UNCONSTRAINED = re.compile(r'\bpermit\s*\(\s*principal\s*(?:is\s+[A-Za-z:_]+\s*)?(?=[,)])')


def key_before(text, pos):
    best = None
    for m in KEY.finditer(text, 0, pos):
        best = m.group(1)
    return best or "(unnamed)"


def main():
    path = sys.argv[1]
    try:
        raw_text = open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        return 0

    # Strip one leading `#` per line, so a commented-out example is read as the policy it teaches.
    # Line count is preserved, so the key attribution below still points at the right place.
    text = re.sub(r'^(\s*)#[ \t]?', r'\1', raw_text, flags=re.M)

    findings = []
    for m in STATEMENT.finditer(text):
        raw = m.group(1) if m.group(1) is not None else m.group(3)
        # An HCL double-quoted string escapes its own quotes; the Cedar to check is the unescaped
        # form. Nothing else in a statement needs unescaping for this check.
        stmt = raw.replace('\\"', '"').replace("\\n", " ")
        if "permit" not in stmt:
            continue
        if UNCONSTRAINED.search(stmt):
            findings.append((key_before(text, m.start()), " ".join(stmt.split())[:160]))

    for key, stmt in findings:
        print(f"      ✗ {path}: `{key}` permits every admitted caller")
        print(f"        {stmt}")
        print("        name the agent: permit(principal == AgentCore::OAuthUser::"
              "\"system:serviceaccount:<ns>:<name>\", ...)")
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main())
