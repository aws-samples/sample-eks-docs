# A regional AWS WAF web ACL for an Application Load Balancer or an AgentCore gateway: the AWS
# managed rule groups for common exploits, known bad inputs and SQL injection, and an optional
# per-IP rate rule. It inspects a request before the load balancer's authentication or the
# gateway's authorizer runs, so it filters traffic that never reaches an agent.
#
# What the managed groups can and can't judge. Their body rules look for exploit signatures in a
# web form. An agent's body is a prompt, and a prompt that discusses SQL or HTML matches them, so
# those rules count rather than block (body_rules_count_only). Prompt injection is a separate
# problem that a signature list doesn't solve; the gateway's guardrail policies screen for it.

locals {
  # Body-inspecting rules in each managed group. Overridden to count when body_rules_count_only.
  body_rules = {
    AWSManagedRulesCommonRuleSet         = ["SizeRestrictions_BODY", "CrossSiteScripting_BODY", "GenericLFI_BODY", "GenericRFI_BODY", "EC2MetaDataSSRF_BODY"]
    AWSManagedRulesKnownBadInputsRuleSet = ["JavaDeserializationRCE_BODY", "Log4JRCE_BODY"]
    AWSManagedRulesSQLiRuleSet           = ["SQLi_BODY", "SQLiExtendedPatterns_BODY"]
  }
  managed_groups = ["AWSManagedRulesCommonRuleSet", "AWSManagedRulesKnownBadInputsRuleSet", "AWSManagedRulesSQLiRuleSet"]
}

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = var.description
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = var.rate_limit_per_ip == null ? [] : [var.rate_limit_per_ip]
    content {
      name     = "rate-per-ip"
      priority = 0

      action {
        block {}
      }

      statement {
        rate_based_statement {
          limit              = rule.value
          aggregate_key_type = "IP"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-rate-per-ip"
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = { for i, g in local.managed_groups : g => i + 1 }
    content {
      name     = rule.key
      priority = rule.value

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.key
          vendor_name = "AWS"

          dynamic "rule_action_override" {
            for_each = var.body_rules_count_only ? toset(local.body_rules[rule.key]) : toset([])
            content {
              name = rule_action_override.value
              action_to_use {
                count {}
              }
            }
          }
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${var.name}-${rule.key}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }

  tags = var.tags
}
