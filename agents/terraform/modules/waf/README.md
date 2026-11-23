# waf

A regional AWS WAF web ACL for the ingress load balancer (`enable_ingress_waf`) or the AgentCore gateway (`enable_gateway_waf`, AWS services path). It inspects each request before the load balancer's sign-in or the gateway's authorizer runs.

## What it creates

| Resource | When |
|---|---|
| A regional web ACL that allows by default | Always |
| A rule that blocks a source IP address over `rate_limit_per_ip` requests in 5 minutes | `rate_limit_per_ip` is set |
| `AWSManagedRulesCommonRuleSet`, `AWSManagedRulesKnownBadInputsRuleSet`, `AWSManagedRulesSQLiRuleSet` | Always |

The managed rules that match on the request body count rather than block when `body_rules_count_only` is on, which is the default. An agent's request body is a prompt or a conversation. It can hold SQL and markup, and it often exceeds the common rule set's 8 KB body limit, so blocking on those rules refuses ordinary turns. Rules on headers, query strings and URIs still block. The agent server refuses a prompt over its own size limit with `413`.

## What it sees on a route that validates a token

On the ingress, a route with a load-balancer gate refuses a request with no valid credential before AWS WAF evaluates it. On an agent route that validates a JWT at the load balancer, a request with no token gets `401` from the load balancer, and AWS WAF never counts it. So on those routes the web ACL, including the per-IP rate rule, inspects only requests that carry a valid token. Routes that send a person to sign in, such as the chat interface, are inspected before the redirect.

## Inputs

| Variable | Default | Purpose |
|---|---|---|
| `name`, `description`, `tags` | | Naming, and the prefix of the CloudWatch metric names. |
| `rate_limit_per_ip` | `null` | Requests per source address per 5 minutes, or null for no rate rule. Leave it null for a gateway: its callers share the NAT gateway's address. |
| `body_rules_count_only` | `true` | Count, rather than block, the managed rules that inspect the body. |

## Outputs

| Output | Use |
|---|---|
| `web_acl_arn` | A `LoadBalancerConfiguration`'s `wafV2.webACL`, or an `aws_wafv2_web_acl_association`. |
