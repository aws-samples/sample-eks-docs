# Sourced by scripts that call AWS from a workstation (teardown.sh): ride out a dropped network.
#
#   is_net_error <text>              exit 0 when <text> reads as a network failure between this
#                                    machine and AWS or the cluster, not an answer from either
#   wait_for_aws                     poll sts every 15 s until AWS answers, up to NET_WAIT_MINUTES
#                                    (default 15); exit 1 if it never does
#   net_retry <command...>           run it; on a network failure wait for AWS and run it again, up
#                                    to NET_RETRY_ATTEMPTS times (default 4). stdout passes through,
#                                    stderr is shown once, from the last attempt. Exit is the
#                                    command's own.
#
# With NET_REGION set, the sts check uses that Region. With NET_FLAG naming a file, the file is
# created once any drop is seen -- a file rather than a variable, because the calls run in
# subshells and background jobs -- so a caller can say so at the end.
#
# The patterns are the AWS CLI's, the Go SDK's (Terraform, kubectl) and kubectl's own, as they
# appear with a killed local proxy and on a VPN that drops mid-run.
NET_RE='dial tcp|i/o timeout|no such host|connection reset by peer|connection refused|TLS handshake timeout|request send failed|send request failed|request canceled|context deadline exceeded|network is unreachable|broken pipe|unexpected EOF|Could not connect to the endpoint URL|Connection was closed before we received|Read timeout on endpoint URL|EndpointConnectionError|Unable to connect to the server|connect timeout on endpoint|Temporary failure in name resolution|nodename nor servname provided|Failed to connect to proxy URL|proxyconnect tcp'
NET_WAIT_MINUTES="${NET_WAIT_MINUTES:-15}"
NET_RETRY_ATTEMPTS="${NET_RETRY_ATTEMPTS:-4}"

# The CLI's own retries for a blip of a few seconds, before any of this is needed.
export AWS_RETRY_MODE="${AWS_RETRY_MODE:-standard}"
export AWS_MAX_ATTEMPTS="${AWS_MAX_ATTEMPTS:-10}"

is_net_error() { printf '%s' "$1" | grep -Eiq "$NET_RE"; }

wait_for_aws() {
  local deadline=$(( $(date +%s) + NET_WAIT_MINUTES * 60 ))
  [[ -n "${NET_FLAG:-}" ]] && : > "$NET_FLAG"
  printf '  network to AWS dropped; waiting up to %s min for it to answer again\n' "$NET_WAIT_MINUTES" >&2
  while (( $(date +%s) < deadline )); do
    if command aws sts get-caller-identity ${NET_REGION:+--region "$NET_REGION"} >/dev/null 2>&1; then
      printf '  AWS answers again; retrying\n' >&2
      return 0
    fi
    sleep 15
  done
  printf '  AWS did not answer within %s min\n' "$NET_WAIT_MINUTES" >&2
  return 1
}

net_retry() {
  local err rc i
  err="$(mktemp -t netretry.XXXXXX)"
  for (( i = 1; i <= NET_RETRY_ATTEMPTS; i++ )); do
    "$@" 2>"$err"; rc=$?
    if (( rc == 0 )) || ! is_net_error "$(cat "$err")" || (( i == NET_RETRY_ATTEMPTS )); then
      cat "$err" >&2; rm -f "$err"; return "$rc"
    fi
    wait_for_aws || { cat "$err" >&2; rm -f "$err"; return "$rc"; }
  done
}
