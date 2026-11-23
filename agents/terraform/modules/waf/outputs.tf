output "web_acl_arn" {
  description = "The web ACL's ARN, for a LoadBalancerConfiguration's wafV2.webACL or an aws_wafv2_web_acl_association."
  value       = aws_wafv2_web_acl.this.arn
}
