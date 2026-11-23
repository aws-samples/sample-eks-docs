#!/usr/bin/env python3
"""Every rendered DNS egress rule goes to the resolver ranges, never to any address.

    python3 scripts/lib/check_dns_egress.py <rendered.yaml> ...

A port-53 egress rule to 0.0.0.0/0, or with no `to` at all, lets a pod query a resolver on the
internet directly, which is a channel out of the cluster that no other rule here sees. Every DNS
rule in this repository names networkPolicy.dnsDestinations instead (gitops/base/values.yaml): the
private, carrier-grade NAT and link-local ranges every resolver an EKS pod uses is in. This reads
NetworkPolicy, ApplicationNetworkPolicy and ClusterNetworkPolicy egress rules, including the ones the
Agent resource definition composes, and fails on a port-53 rule that names anything else.
"""
import sys

import yaml

BASE = yaml.safe_load(open("gitops/base/values.yaml", encoding="utf-8"))["networkPolicy"]["dnsDestinations"]


def rules(doc):
    """(where, egress rule) for every egress rule in a policy, or in a policy an RGD composes."""
    kind = doc.get("kind")
    name = (doc.get("metadata") or {}).get("name")
    if kind in ("NetworkPolicy", "ApplicationNetworkPolicy", "ClusterNetworkPolicy"):
        for r in (doc.get("spec") or {}).get("egress") or []:
            yield f"{kind} {name}", r
    elif kind == "ResourceGraphDefinition":
        for res in (doc.get("spec") or {}).get("resources") or []:
            tpl = res.get("template") or {}
            if isinstance(tpl, dict) and tpl.get("kind") in ("NetworkPolicy", "ApplicationNetworkPolicy"):
                for r in (tpl.get("spec") or {}).get("egress") or []:
                    yield f"{name}/{res.get('id')}", r


def dns(rule):
    for p in rule.get("ports") or []:
        port = p.get("port", (p.get("portNumber") or {}).get("port"))
        if port == 53:
            return True
    return False


def destinations(rule):
    out = []
    for peer in rule.get("to") or []:
        if "ipBlock" in peer:
            out.append(peer["ipBlock"].get("cidr"))
        elif "networks" in peer:
            out += list(peer["networks"] or [])
        else:
            out.append(f"<{', '.join(sorted(peer))}>")
    return out


def main(paths):
    errs, n = [], 0
    for path in paths:
        for doc in yaml.safe_load_all(open(path, encoding="utf-8")):
            if not isinstance(doc, dict):
                continue
            for where, rule in rules(doc):
                if not dns(rule):
                    continue
                n += 1
                got = destinations(rule)
                if got != BASE:
                    errs.append(f"{path.split('/')[-1]}: {where}: DNS egress to {got or 'any address'}, "
                                f"not networkPolicy.dnsDestinations")
    for e in errs:
        print(f"      ✗ {e}")
    if not errs:
        print(f"      ✓ {n} DNS egress rules, each to networkPolicy.dnsDestinations only")
    return 1 if errs or n == 0 else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
