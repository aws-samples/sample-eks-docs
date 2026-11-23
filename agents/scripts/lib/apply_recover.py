"""What scripts/apply.sh does after a plan or an apply fails, or a plan wants to replace a tainted
resource. Standard library only.

    python3 apply_recover.py classify <terraform output log>
        exit 10: a network failure between this machine and AWS -- wait for AWS, then plan again
        exit 11: AWS created something Terraform did not record ("already exists")
        exit 12: the object is busy with another update ("update in progress"); wait and plan again
        exit 0:  anything else

    python3 apply_recover.py import-hints <terraform output log> <plan.json>
        prints a `terraform import` command for each "already exists" error it can name

    python3 apply_recover.py adopt <terraform output log> <plan.json> <stack name> <region>
        prints "address<TAB>import id" for each "already exists" error whose AWS object is provably
        THIS stack's: its type is in OWNED and the object carries eks-agents/cluster = <stack name>,
        the tag the provider sets on every create. Exit 0 when every such error is adopted, 1 when
        any is left (import-hints names those).

    python3 apply_recover.py untaint <plan.json> <stack name> <region>
        prints, one per line, the tainted resources that are safe to untaint: every replacement the
        plan makes BECAUSE OF A TAINT is of a type in OWNED, its AWS object carries this stack's
        eks-agents/cluster tag, and an EKS cluster or capability is also ACTIVE. Exit 0 with that
        list; exit 1 (and print why) when any tainted replacement is not safe, so apply.sh leaves the
        plan to plan_guard.py as it is.

WHY UNTAINT AT ALL. A create whose follow-up read or wait is cut off by a drop leaves the resource
tainted, and the next plan replaces it: CreateRole can succeed while the provider's GetRole
read-back fails on the cut; an EKS cluster's ten-minute wait is the expensive case. Untainting is
right when the object exists and is this stack's, because the next plan's refresh reads its real
settings and corrects any difference in place. Only types whose create call carries the tags can be
proven this stack's; a tainted secret version, for one, really does need replacing on the open
source path, and is never untainted.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys

NETWORK = re.compile(
    r"dial tcp|i/o timeout|request send failed|no such host|connection reset by peer|connection refused|"
    r"TLS handshake timeout|send request failed|request canceled|context deadline exceeded|"
    r"network is unreachable|broken pipe|unexpected EOF|EOF$|Client\.Timeout|"
    r"failed to refresh cached credentials|could not connect to the endpoint|Failed to connect to proxy URL|proxyconnect tcp",
    re.I | re.M,
)
EXISTS = re.compile(
    r"already exists|EntityAlreadyExists|ResourceAlreadyExists|ResourceInUseException|"
    r"BucketAlreadyOwnedByYou|ResourceExistsException|AlreadyExistsException",
    re.I,
)
# BUSY IS NOT EXISTS. EKS answers ResourceInUseException both for a create whose object exists and
# for an update while another update on the same cluster is still running ("currently has an update
# in progress"). The second is a wait, not an import: the object is already in state, and importing
# it fails with "Resource already managed by Terraform".
BUSY = re.compile(r"update in progress|has an update in progress|currently being (?:updated|modified)", re.I)
# Terraform's error blocks name the resource on a "with <address>," line.
WITH = re.compile(r"with ((?:module\.[\w-]+(?:\[[^\]]+\])?\.)*[\w-]+\.[\w-]+(?:\[[^\]]+\])?),")

# Import ID by type, from the resource's planned values. Only types whose format is documented.
IMPORT_ID = {
    "aws_eks_cluster": lambda v: v.get("name"),
    "aws_eks_capability": lambda v: f'{v.get("cluster_name")},{v.get("capability_name")}',
    "aws_iam_role": lambda v: v.get("name"),
    "aws_iam_policy": lambda v: v.get("arn"),
    "aws_s3_bucket": lambda v: v.get("bucket"),
    "aws_cloudwatch_log_group": lambda v: v.get("name"),
    "aws_ecr_repository": lambda v: v.get("name"),
    "aws_eks_pod_identity_association": lambda v: (
        f'{v.get("cluster_name")},{v.get("association_id")}' if v.get("association_id") else None),
}


def _aws(*args: str) -> str | None:
    try:
        return subprocess.run(["aws", *args], capture_output=True, text=True, timeout=60,
                              check=True).stdout.strip()
    except (subprocess.SubprocessError, OSError):
        return None


def _account() -> str | None:
    return _aws("sts", "get-caller-identity", "--query", "Account", "--output", "text")


def _tag_ok(raw: str | None, name: str) -> bool:
    """raw is the JSON of a tag list ([{Key, Value}]) or a tag map ({key: value})."""
    if not raw:
        return False
    try:
        tags = json.loads(raw)
    except ValueError:
        return False
    if isinstance(tags, list):
        tags = {t.get("Key", t.get("key")): t.get("Value", t.get("value")) for t in tags}
    return isinstance(tags, dict) and tags.get("eks-agents/cluster") == name


def _owned_ecr(v: dict, name: str, region: str) -> bool:
    acct = _account()
    return bool(acct) and _tag_ok(_aws("ecr", "list-tags-for-resource", "--region", region, "--resource-arn",
                                       f"arn:aws:ecr:{region}:{acct}:repository/{v.get('name')}",
                                       "--query", "tags", "--output", "json"), name)


def _owned_role(v: dict, name: str, region: str) -> bool:
    return _tag_ok(_aws("iam", "list-role-tags", "--role-name", str(v.get("name")), "--query", "Tags",
                        "--output", "json"), name)


def _owned_log_group(v: dict, name: str, region: str) -> bool:
    acct = _account()
    return bool(acct) and _tag_ok(_aws("logs", "list-tags-for-resource", "--region", region, "--resource-arn",
                                       f"arn:aws:logs:{region}:{acct}:log-group:{v.get('name')}",
                                       "--query", "tags", "--output", "json"), name)


def _owned_bucket(v: dict, name: str, region: str) -> bool:
    return _tag_ok(_aws("s3api", "get-bucket-tagging", "--bucket", str(v.get("bucket")),
                        "--query", "TagSet", "--output", "json"), name)


def _owned_cluster(v: dict, name: str, region: str) -> bool:
    return _tag_ok(_aws("eks", "describe-cluster", "--region", region, "--name", str(v.get("name")),
                        "--query", "cluster.tags", "--output", "json"), name)


def _owned_capability(v: dict, name: str, region: str) -> bool:
    return _tag_ok(_aws("eks", "describe-capability", "--region", region,
                        "--cluster-name", str(v.get("cluster_name")),
                        "--capability-name", str(v.get("capability_name")),
                        "--query", "capability.tags", "--output", "json"), name)


# Types whose create call carries the tags, so a lost reply still leaves a tagged object. With AWS
# provider 6.x CreateBucket carries them too (an orphaned bucket has eks-agents/cluster);
# a bucket without the tag is not adopted, and gets the import command instead.
OWNED = {
    "aws_s3_bucket": _owned_bucket,
    "aws_ecr_repository": _owned_ecr,
    "aws_iam_role": _owned_role,
    "aws_cloudwatch_log_group": _owned_log_group,
    "aws_eks_cluster": _owned_cluster,
    "aws_eks_capability": _owned_capability,
}


def _exists_errors(log: str) -> list[str]:
    out = []
    for block in re.split(r"\n(?=.*Error: )", log):
        if EXISTS.search(block) and (m := WITH.search(block)):
            out.append(m.group(1))
    return out


def _rtype(addr: str) -> str:
    return re.sub(r"\[[^\]]*\]", "", addr).split(".")[-2]


def adopt(log: str, plan: dict, name: str, region: str) -> tuple[list[tuple[str, str]], list[str]]:
    values, adopted, left = _values(plan), [], []
    for addr in _exists_errors(log):
        rtype, v = _rtype(addr), values.get(addr, {})
        rid = IMPORT_ID.get(rtype, lambda _v: None)(v)
        owned = OWNED.get(rtype)
        if rid and owned and owned(v, name, region):
            adopted.append((addr, rid))
        else:
            left.append(addr)
    return adopted, left


def _active_cluster(v: dict, region: str) -> bool:
    return _aws("eks", "describe-cluster", "--region", region, "--name", str(v.get("name")),
                "--query", "cluster.status", "--output", "text") == "ACTIVE"


def _active_capability(v: dict, region: str) -> bool:
    return _aws("eks", "describe-capability", "--region", region,
                "--cluster-name", str(v.get("cluster_name")),
                "--capability-name", str(v.get("capability_name")),
                "--query", "capability.status", "--output", "text") == "ACTIVE"


# Beyond belonging to this stack, what a tainted object must also be before it is kept.
READY = {"aws_eks_cluster": _active_cluster, "aws_eks_capability": _active_capability}


def classify(log: str) -> int:
    if NETWORK.search(log):
        return 10
    if BUSY.search(log):
        return 12
    if EXISTS.search(log):
        return 11
    return 0


def _values(plan: dict) -> dict[str, dict]:
    return {c["address"]: (c.get("change", {}).get("after") or {}) for c in plan.get("resource_changes", [])}


def import_hints(log: str, plan: dict, root: str, var_files: str = "-var-file=<your tfvars>") -> list[str]:
    values, out = _values(plan), []
    for block in re.split(r"\n(?=.*Error: )", log):
        if not EXISTS.search(block):
            continue
        m = WITH.search(block)
        if not m:
            continue
        addr = m.group(1)
        rtype = re.sub(r"\[[^\]]*\]", "", addr).split(".")[-2]
        rid = IMPORT_ID.get(rtype, lambda v: None)(values.get(addr, {}))
        if rid:
            out.append(f"terraform -chdir={root} import {var_files} '{addr}' '{rid}'")
        else:
            out.append(f"{addr}: exists in AWS but not in state; import it (see the provider's docs "
                       f"for {rtype}'s import ID) or delete it, then apply again")
    return out


def untaint(plan: dict, name: str, region: str) -> tuple[list[str], list[str]]:
    safe, unsafe = [], []
    for c in plan.get("resource_changes", []):
        if c.get("action_reason") != "replace_because_tainted":
            continue
        rtype = c.get("type", "")
        before = c.get("change", {}).get("before") or {}
        owned, ready = OWNED.get(rtype), READY.get(rtype, lambda _v, _r: True)
        if not owned:
            unsafe.append(f'{c["address"]}: tainted, and {rtype} cannot be proven this stack\'s')
        elif not owned(before, name, region):
            unsafe.append(f'{c["address"]}: tainted, and AWS has no object tagged for {name}')
        elif not ready(before, region):
            unsafe.append(f'{c["address"]}: tainted, and AWS does not report it ACTIVE')
        else:
            safe.append(c["address"])
    return safe, unsafe


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "classify":
        return classify(open(sys.argv[2], errors="replace").read())
    if cmd == "import-hints":
        log = open(sys.argv[2], errors="replace").read()
        plan = json.load(open(sys.argv[3])) if len(sys.argv) > 3 else {}
        root = sys.argv[4] if len(sys.argv) > 4 else "<root>"
        var_files = sys.argv[5] if len(sys.argv) > 5 and sys.argv[5] else "-var-file=<your tfvars>"
        for h in import_hints(log, plan, root, var_files):
            print(h)
        return 0
    if cmd == "adopt":
        log = open(sys.argv[2], errors="replace").read()
        adopted, left = adopt(log, json.load(open(sys.argv[3])), sys.argv[4], sys.argv[5])
        for addr, rid in adopted:
            print(f"{addr}\t{rid}")
        return 0 if adopted and not left else 1
    if cmd == "untaint":
        safe, unsafe = untaint(json.load(open(sys.argv[2])), sys.argv[3], sys.argv[4])
        for u in unsafe:
            print(u, file=sys.stderr)
        if unsafe or not safe:
            return 1
        print("\n".join(safe))
        return 0
    if cmd == "selftest":
        return selftest()
    print(__doc__, file=sys.stderr)
    return 2


def selftest() -> int:
    ok = True

    def check(name: str, got, want) -> None:
        nonlocal ok
        if got != want:
            ok = False
            print(f"FAIL {name}: {got!r} != {want!r}")

    check("network dial", classify('Error: reading EKS Cluster: dial tcp: lookup eks.us-west-2.amazonaws.com: no such host'), 10)
    check("network send", classify("operation error STS: GetCallerIdentity, https response error StatusCode: 0, RequestID: , request send failed"), 10)
    check("exists", classify("Error: creating IAM Role (x): EntityAlreadyExists: Role with name x already exists."), 11)
    check("other", classify("Error: Invalid value for variable"), 0)
    check("busy", classify("Error: updating EKS Cluster (x) logging: ResourceInUseException: Cannot LoggingUpdate because cluster x currently has an update in progress"), 12)
    log = ("│ Error: creating EKS Capability (agents-argocd): ResourceInUseException: exists\n"
           "│   with module.cluster.aws_eks_capability.argocd[0],\n")
    plan = {"resource_changes": [{"address": "module.cluster.aws_eks_capability.argocd[0]",
                                  "change": {"after": {"cluster_name": "agents", "capability_name": "agents-argocd"}}}]}
    check("hint", import_hints(log, plan, "terraform/open-source"),
          ["terraform -chdir=terraform/open-source import -var-file=<your tfvars> 'module.cluster.aws_eks_capability.argocd[0]' 'agents,agents-argocd'"])
    tainted = {"resource_changes": [{"address": "module.x.aws_secretsmanager_secret_version.v", "type": "aws_secretsmanager_secret_version",
                                     "action_reason": "replace_because_tainted", "change": {"before": {}}}]}
    safe, unsafe = untaint(tainted, "a", "us-west-2")
    check("secret version is never untainted", (safe, len(unsafe)), ([], 1))
    check("no taint", untaint({"resource_changes": []}, "a", "us-west-2"), ([], []))
    check("tag list", _tag_ok('[{"Key":"eks-agents/cluster","Value":"a"}]', "a"), True)
    check("tag map", _tag_ok('{"eks-agents/cluster":"a"}', "a"), True)
    check("someone else's", _tag_ok('{"eks-agents/cluster":"b"}', "a"), False)
    check("untagged", _tag_ok("[]", "a"), False)
    check("secret versions are never owned", "aws_secretsmanager_secret_version" in OWNED, False)
    print("apply_recover selftest: " + ("ok" if ok else "FAILED"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
