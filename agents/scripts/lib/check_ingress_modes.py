#!/usr/bin/env python3
"""Ingress renders in each browser-gate mode, and every browser gate lands where it must.

    python3 scripts/lib/check_ingress_modes.py <repo root>

Renders gitops/base on both paths in the two modes that have a browser gate -- Cognito, and direct
OIDC (ingress_idp = "oidc-direct") -- and asserts the layout the direct mode depends on:

  - every browser-gated HTTPRoute and its ListenerRuleConfiguration, the Agent resource's and the
    chat UI's, is in namespaces.ingress -- because that is the only namespace the client secret
    and the eks:managed grant exist in, and a rule anywhere else names a Secret it cannot read;
  - the workload gate (jwt-validation) stays beside the agent, because it needs no credential;
  - each cross-namespace backend has a ReferenceGrant naming exactly that Service;
  - the eks:managed Role and RoleBinding exist in direct mode only, scoped to one Secret name;
  - authenticate-oidc renders in direct mode only, and authenticate-cognito in Cognito mode only.

A mode-dependent layout is exactly what a refactor breaks quietly: the chart still renders, Argo CD
still syncs, and the ALB serves a fixed-response 500 because one rule moved back to a namespace with
no Secret in it.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

INGRESS_NS = "ingress"
POOL = {"userPoolArn": "arn:aws:cognito-idp:us-west-2:111122223333:userpool/us-west-2_EXAMPLE",
        "userPoolClientId": "example", "userPoolDomain": "example", "identityProvider": ""}
# None, not an object of empty strings: Terraform writes `cognito: null` in direct mode, and Helm
# DELETES a key a later values file sets to null. An object of empty strings renders cleanly here
# while the real values fail the chat UI with a nil pointer.
NO_POOL = None
OIDC = {"issuer": "https://idp.example.com", "authorizationEndpoint": "https://idp.example.com/authorize",
        "tokenEndpoint": "https://idp.example.com/token", "userInfoEndpoint": "https://idp.example.com/userinfo",
        "clientId": "example"}


def render(root: Path, path: str, mode: str) -> list[dict]:
    values = {
        "cluster": "ingress-modes",
        "path": path,
        "ingress": {"enabled": True, "domainName": "agents.example.com",
                      "certificateArn": "arn:aws:acm:us-west-2:111122223333:certificate/EXAMPLE",
                      "cognito": POOL if mode == "cognito" else NO_POOL, "oidc": OIDC},
        "chatUi": {"enabled": True},
        "registry": {"agents/chat-ui": "111122223333.dkr.ecr.us-west-2.amazonaws.com/agents/chat-ui"},
    }
    if path == "aws-services":
        values["gateway"] = {"hostname": "h", "modelEndpoint": "https://h", "mcpEndpoint": "https://h/m"}
        values["model"] = {"gatewayModelId": "bedrock/x"}
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        yaml.safe_dump(values, f)
    out = subprocess.run(
        ["helm", "template", "v", str(root / "gitops/base"),
         "-f", str(root / "gitops/base/values.yaml"),
         "-f", str(root / "scripts/lib/render-null-shape.yaml"), "-f", f.name],
        capture_output=True, text=True)
    Path(f.name).unlink(missing_ok=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip().splitlines()[-1] if out.stderr.strip() else "helm failed")
    return [d for d in yaml.safe_load_all(out.stdout) if d]


def check(docs: list[dict], mode: str) -> list[str]:
    errs: list[str] = []
    rgd = next((d for d in docs if d["kind"] == "ResourceGraphDefinition"), None)
    if rgd is None:
        return ["no ResourceGraphDefinition rendered"]
    res = {r["id"]: r.get("template", {}) for r in rgd["spec"]["resources"]}

    def ns(tid: str) -> str:
        return res.get(tid, {}).get("metadata", {}).get("namespace", "<absent>")

    for tid in ("httpRouteBrowser", "routeAuth"):
        if ns(tid) != INGRESS_NS:
            errs.append(f"Agent {tid} is in {ns(tid)!r}, not {INGRESS_NS!r}")
    for tid in ("httpRouteWorkload", "routeAuthWorkload", "ingressReferenceGrant"):
        if ns(tid) != "${schema.metadata.namespace}":
            errs.append(f"Agent {tid} is in {ns(tid)!r}, not the agent's own namespace")

    browser = res.get("routeAuth", {}).get("spec", {}).get("actions", [{}])[0].get("type")
    want = "authenticate-oidc" if mode == "direct" else "authenticate-cognito"
    if browser != want:
        errs.append(f"Agent browser gate is {browser!r} in {mode} mode, want {want!r}")

    backend = res.get("httpRouteBrowser", {}).get("spec", {}).get("rules", [{}])[0].get("backendRefs", [{}])[0]
    if backend.get("namespace") != "${schema.metadata.namespace}":
        errs.append("Agent browser route's backend does not name the agent's namespace")

    grant_to = res.get("ingressReferenceGrant", {}).get("spec", {}).get("to", [{}])
    if len(grant_to) != 1 or not grant_to[0].get("name"):
        errs.append("Agent ReferenceGrant does not name exactly one Service")

    objs = {(d["kind"], d["metadata"].get("namespace", ""), d["metadata"]["name"]): d for d in docs}
    lrcs = [d for d in docs if d["kind"] == "ListenerRuleConfiguration"]
    for d in lrcs:
        action = d["spec"]["actions"][0]["type"]
        if action in ("authenticate-oidc", "authenticate-cognito") and d["metadata"]["namespace"] != INGRESS_NS:
            errs.append(f"{action} rule {d['metadata']['name']} is in {d['metadata']['namespace']!r}")
        if action == "authenticate-oidc" and mode != "direct":
            errs.append(f"authenticate-oidc rendered in {mode} mode")
    routes = [d for d in docs if d["kind"] == "HTTPRoute" and d["metadata"]["name"] == "chat-ui"]
    if not routes or routes[0]["metadata"]["namespace"] != INGRESS_NS:
        errs.append("chat UI HTTPRoute is not in the ingress namespace")
    if not any(k[0] == "ReferenceGrant" and k[2] == "chat-ui-ingress" for k in objs):
        errs.append("chat UI ReferenceGrant missing")

    role = objs.get(("Role", INGRESS_NS, "eks-managed-ingress-oidc"))
    binding = objs.get(("RoleBinding", INGRESS_NS, "eks-managed-ingress-oidc"))
    if mode == "direct":
        if role is None or binding is None:
            errs.append("direct mode without the eks:managed Role and RoleBinding")
        else:
            rule = role["rules"]
            if len(rule) != 1 or rule[0].get("resourceNames") != ["ingress-oidc"] or \
                    set(rule[0].get("verbs", [])) - {"get", "list", "watch"}:
                errs.append(f"eks:managed Role is wider than one Secret, read-only: {rule}")
            subjects = binding.get("subjects", [])
            if subjects != [{"apiGroup": "rbac.authorization.k8s.io", "kind": "Group", "name": "eks:managed"}]:
                errs.append(f"RoleBinding subjects are {subjects}, want only Group eks:managed")
    elif role is not None or binding is not None:
        errs.append(f"eks:managed grant rendered in {mode} mode, which reads no Secret")
    return errs


def main() -> int:
    root = Path(sys.argv[1])
    failed = False
    for path in ("open-source", "aws-services"):
        for mode in ("cognito", "direct"):
            try:
                errs = check(render(root, path, mode), mode)
            except RuntimeError as e:
                errs = [f"render failed: {e}"]
            for e in errs:
                print(f"      ✗ {path} {mode}: {e}")
            failed |= bool(errs)
    if not failed:
        print("      ✓ both paths, Cognito and direct OIDC: every browser gate in the ingress namespace, the grant only where a Secret is read")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
