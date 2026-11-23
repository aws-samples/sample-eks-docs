# Where each layer's decisions are recorded, in one place.
#
# Each policy layer records its decisions somewhere different, and most of those places are off or
# unread by default. This file puts the ones that land in CloudWatch behind saved Logs Insights
# queries and one dashboard, so a platform team opens a console page instead of adapting a script:
#
#   network policy     every ACCEPT and DENY, per flow, in the network-policy log group (above).
#   AgentCore Gateway  DenyDecisions and AllowDecisions per Cedar policy, in the
#                      AWS/Bedrock-AgentCore metrics, by policy, with no caller.
#   admission          refusals by a ValidatingAdmissionPolicy (responseStatus.message of the audit
#                      event), in the control plane audit log, when
#                      enable_cluster_log_types includes "audit".
#
# Not here, and said so on the dashboard: IAM refusals (CloudTrail, errorCode AccessDenied), the MCP
# server's person-tool log (pod logs, which stay off because agent logs carry prompts), and the Nitro
# Sandbox, which isolates rather than decides and so records nothing. scripts/exercise.sh is the
# other half: it proves each layer refuses what it should; this shows what each one did.

locals {
  network_policy_log_group = "/aws/eks/${var.cluster_name}/network-policy"
  netpol_parse             = "parse msg /Src IP: (?<src>[0-9.]+) Src Port: (?<sport>\\d+) Dest IP: (?<dst>[0-9.]+) Dest Port: (?<dport>\\d+) Proto (?<proto>\\w+) Verdict (?<verdict>\\w+) Direction (?<direction>\\w+), Tier (?<tier>\\w+)/"
  # A Deny-action ValidatingAdmissionPolicy adds no annotation to the audit event: its name and
  # message are in responseStatus.message. (validation_failure annotations are for the Audit action.)
  admission_query = join("\n", [
    "fields @timestamp, user.username, objectRef.namespace, objectRef.resource, objectRef.name, responseStatus.message",
    "| filter responseStatus.code = 403 and responseStatus.message like /ValidatingAdmissionPolicy/",
    "| parse responseStatus.message /ValidatingAdmissionPolicy '(?<policy>[^']+)'.*denied request: (?<reason>.*)/",
    "| display @timestamp, user.username, objectRef.namespace, objectRef.resource, objectRef.name, policy, reason",
    "| sort @timestamp desc",
    "| limit 50",
  ])
  audit_on = contains(var.cluster_log_types, "audit")
}

resource "aws_cloudwatch_query_definition" "network_policy_denials" {
  count = var.enable_network_policy_logs ? 1 : 0

  name            = "${var.name}/policy-decisions/network-policy-denials"
  log_group_names = [local.network_policy_log_group]
  query_string = join("\n", [
    "fields @timestamp, @logStream",
    "| ${local.netpol_parse}",
    "| filter verdict = \"DENY\"",
    "| stats count(*) as denials, latest(@timestamp) as last_seen by src, dst, dport, proto, direction, tier",
    "| sort denials desc",
    "| limit 50",
  ])
}

resource "aws_cloudwatch_query_definition" "network_policy_flows" {
  count = var.enable_network_policy_logs ? 1 : 0

  name            = "${var.name}/policy-decisions/network-policy-flows-for-one-pod (replace POD_IP)"
  log_group_names = [local.network_policy_log_group]
  query_string = join("\n", [
    "fields @timestamp, @logStream",
    "| ${local.netpol_parse}",
    "| filter src = \"POD_IP\" or dst = \"POD_IP\"",
    "| stats count(*) as flows by verdict, direction, src, dst, dport, proto, tier",
    "| sort flows desc",
  ])
}

resource "aws_cloudwatch_query_definition" "admission_refusals" {
  count = local.audit_on ? 1 : 0

  name            = "${var.name}/policy-decisions/admission-refusals"
  log_group_names = ["/aws/eks/${var.cluster_name}/cluster"]
  query_string    = local.admission_query
}

resource "aws_cloudwatch_dashboard" "policy_decisions" {
  count = var.create_dashboard ? 1 : 0

  dashboard_name = "${var.name}-policy-decisions"
  dashboard_body = jsonencode({
    widgets = concat(
      [{
        type = "text", x = 0, y = 0, width = 24, height = 4
        properties = {
          markdown = join("\n", [
            "## Policy decisions, ${var.cluster_name}",
            "What each layer refused or allowed. Recorded here: **network policy** (every flow verdict, by IP), **AgentCore Gateway** (Cedar decisions per policy)${local.audit_on ? ", **admission** (control plane audit log)" : ""}.",
            "Elsewhere: **IAM** refusals are in CloudTrail (`errorCode` `AccessDenied`, filter by the agent's role). The **MCP server** logs each person-tool call with agent and person in its pod log. A **Nitro Sandbox** isolates rather than decides, so it records nothing; `scripts/exercise.sh` proves it.${local.audit_on ? "" : " **Admission** refusals need `audit` in `enable_cluster_log_types`."}",
            "Saved queries: CloudWatch Logs Insights, folder `${var.name}/policy-decisions`.",
          ])
        }
      }],
      var.enable_network_policy_logs ? [{
        type = "log", x = 0, y = 4, width = 24, height = 8
        properties = {
          title  = "Network policy: denied flows (by source and destination IP)"
          region = local.region
          view   = "table"
          query  = "SOURCE '${local.network_policy_log_group}' | fields @timestamp | ${local.netpol_parse} | filter verdict = \"DENY\" | stats count(*) as denials, latest(@timestamp) as last_seen by src, dst, dport, proto, direction, tier | sort denials desc | limit 25"
        }
      }] : [],
      var.gateway_id != "" ? [
        {
          type = "metric", x = 0, y = 12, width = 12, height = 6
          properties = {
            title   = "AgentCore Gateway: Cedar denials by policy"
            region  = local.region
            stat    = "Sum"
            period  = 300
            view    = "timeSeries"
            metrics = [[{ expression = "SEARCH('{AWS/Bedrock-AgentCore,OperationName,Policy,TargetResource} MetricName=\"DenyDecisions\" TargetResource=\"${var.gateway_id}\"', 'Sum', 300)", id = "deny", label = "" }]]
          }
        },
        {
          type = "metric", x = 12, y = 12, width = 12, height = 6
          properties = {
            title  = "AgentCore Gateway: decisions"
            region = local.region
            stat   = "Sum"
            period = 300
            view   = "timeSeries"
            metrics = [
              [{ expression = "SEARCH('{AWS/Bedrock-AgentCore,OperationName,TargetResource} MetricName=\"AllowDecisions\" TargetResource=\"${var.gateway_id}\"', 'Sum', 300)", id = "allow", label = "allow" }],
              [{ expression = "SEARCH('{AWS/Bedrock-AgentCore,OperationName,TargetResource} MetricName=\"DenyDecisions\" TargetResource=\"${var.gateway_id}\"', 'Sum', 300)", id = "deny2", label = "deny" }],
            ]
          }
        },
      ] : [],
      local.audit_on ? [{
        type = "log", x = 0, y = 18, width = 24, height = 8
        properties = {
          title  = "Admission: refused by a ValidatingAdmissionPolicy"
          region = local.region
          view   = "table"
          query  = "SOURCE '/aws/eks/${var.cluster_name}/cluster' | ${replace(local.admission_query, "\n", " ")}"
        }
      }] : [],
    )
  })
}
