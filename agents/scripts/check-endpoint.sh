#!/usr/bin/env bash
# Why this machine can or cannot reach a stack's Kubernetes API endpoint, and what to change.
#
#   ./scripts/check-endpoint.sh --root terraform/<path>
#   ./scripts/check-endpoint.sh --cluster <name> --region <region>
#
# A public endpoint that refuses this machine's address does not refuse: the connection times out,
# which reads like a network fault. This prints the cluster's allowlist, this machine's address as
# two lookup services see it, whether the address is in the list, and whether the endpoint answers.
# scripts/run-stack.sh runs it when the endpoint does not answer from here.
#
# Two lookups, because a network that sends traffic out through a pool of addresses can show each
# service a different one, and the one the endpoint sees need not be either. The Terraform roots
# allow both lookups' /32s by default, which covers a network with two egress addresses but not a
# larger pool. The verdict therefore rests on whether /version answers, not on a lookup being listed.
#
# Exit 0 when the endpoint answers, 1 when it does not, 2 on a usage error.
set -uo pipefail

TF_ROOT="" CLUSTER="" REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null || true)}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)    TF_ROOT="$2"; shift 2 ;;
    --cluster) CLUSTER="$2"; shift 2 ;;
    --region)  REGION="$2"; REGION_SET=1; shift 2 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
if [[ -n "$TF_ROOT" && -z "$CLUSTER" ]]; then
  CLUSTER="$(terraform -chdir="$TF_ROOT" output -raw cluster_name 2>/dev/null || true)"
fi
# With --root, the stack's own Region, not the shell's default.
if [[ -n "$TF_ROOT" && -z "${REGION_SET:-}" ]]; then
  root_region="$(terraform -chdir="$TF_ROOT" output -raw region 2>/dev/null || true)"
  [[ -n "$root_region" ]] && REGION="$root_region"
fi
[[ -n "$CLUSTER" && -n "$REGION" ]] || { echo "usage: $0 --root <terraform root> | --cluster <name> --region <region>" >&2; exit 2; }

vpc="$(aws eks describe-cluster --region "$REGION" --name "$CLUSTER" \
         --query 'cluster.[endpoint, resourcesVpcConfig.endpointPublicAccess, resourcesVpcConfig.endpointPrivateAccess, certificateAuthority.data, join(`,`, resourcesVpcConfig.publicAccessCidrs)]' \
         --output text 2>&1)" || { echo "could not describe $CLUSTER in $REGION: $vpc" >&2; exit 1; }
read -r endpoint public private ca_data cidrs <<<"$vpc"
# The cluster's own CA, so the probe below verifies the endpoint's certificate rather than trusting
# whatever answers on that address.
ca="$(mktemp)"; trap 'rm -f "$ca"' EXIT
printf '%s' "$ca_data" | base64 --decode > "$ca" 2>/dev/null || printf '%s' "$ca_data" | base64 -D > "$ca"

lookup() { curl -s --max-time 5 "$1" 2>/dev/null | tr -d '[:space:]'; }
via_checkip="$(lookup https://checkip.amazonaws.com)"
via_ipify="$(lookup https://api.ipify.org)"

in_list() {  # <address> <comma-separated CIDRs>
  python3 -c 'import ipaddress, sys
a = sys.argv[1]; nets = [n for n in sys.argv[2].split(",") if n and n != "None"]
try: ip = ipaddress.ip_address(a)
except ValueError: print("unknown"); sys.exit()
print("yes" if any(ip in ipaddress.ip_network(n, strict=False) for n in nets) else "no")' "$1" "$2"
}

# Any HTTP status means the connection was accepted: a 401 or 403 is the API server answering an
# unauthenticated request, which is reachability, not a refusal.
code="$(curl -s --cacert "$ca" -o /dev/null -w '%{http_code}' --max-time 10 "$endpoint/version" 2>/dev/null)"
answers=no; [[ "$code" =~ ^[1-5][0-9][0-9]$ ]] && answers=yes

echo "cluster        $CLUSTER ($REGION)"
echo "endpoint       $endpoint"
echo "public access  $public, private access $private"
echo "allowlist      ${cidrs//,/ }"
printf 'this machine   %-18s (checkip.amazonaws.com) in allowlist: %s\n' "${via_checkip:-unknown}" "$(in_list "${via_checkip:-x}" "$cidrs")"
printf '               %-18s (api.ipify.org)         in allowlist: %s\n' "${via_ipify:-unknown}" "$(in_list "${via_ipify:-x}" "$cidrs")"
echo "answers here   $answers${code:+ (HTTP $code)}"

[[ "$answers" == yes ]] && exit 0

echo
if [[ "$public" != True ]]; then
  echo "The endpoint is private: it answers only inside the VPC. Use the bastion (scripts/run-stack.sh)."
elif [[ -n "$via_checkip" && -n "$via_ipify" && "$via_checkip" != "$via_ipify" ]]; then
  echo "The two lookups disagree, so this network sends traffic out through more than one address,"
  echo "and an address being in the allowlist does not mean the endpoint sees that one. On a VPN, one"
  echo "lookup can report an allowed address while traffic to EKS leaves from the one the other lookup"
  echo "reports. Add every address not yet listed, or the network's whole egress"
  echo "pool, to cluster_endpoint_public_access_cidrs and apply again:"
  missing=0
  for a in "$via_checkip" "$via_ipify"; do
    [[ "$(in_list "$a" "$cidrs")" == no ]] && { echo "  missing: $a/32"; missing=1; }
  done
  # Both listed and still refused: the endpoint sees a third member of the pool, which no lookup
  # reported (on an office network, for example: both lookups allowed, HTTP 000). Only the
  # whole pool fixes that, and an apply that looks the address up again moves the list to whatever
  # that apply sees, which can lock out the address that worked before.
  [[ "$missing" == 0 ]] && echo "  both are listed, so the endpoint sees an address neither lookup reported: name the pool's CIDRs."
elif [[ "$(in_list "${via_checkip:-x}" "$cidrs")" == no ]]; then
  echo "This machine's address is not in the allowlist. On a network that sends traffic out through a"
  echo "pool of NAT addresses (a VPN, a corporate network), each lookup can return a different member at"
  echo "different moments, so name the pool's CIDRs in cluster_endpoint_public_access_cidrs. On a single"
  echo "address, apply the root again from here (it allows this address when that list is empty) or add"
  echo "it to the list. Either way EKS takes about five minutes to roll the allowlist out."
else
  echo "The address is in the allowlist and the endpoint still does not answer. Right after an apply,"
  echo "EKS is most likely still rolling the allowlist out (about five minutes): wait and"
  echo "run this again. If it still does not answer, the endpoint may see a different address than either"
  echo "lookup (a NAT pool): name the pool's CIDRs. Otherwise check this machine's outbound path to 443."
fi
exit 1
