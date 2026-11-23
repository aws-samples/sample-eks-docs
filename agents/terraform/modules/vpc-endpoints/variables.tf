variable "name" {
  description = "Prefix for the endpoints' names and their security group."
  type        = string
}

variable "region" {
  description = "Region of the VPC, and of every service an endpoint is created for."
  type        = string
}

variable "vpc_id" {
  description = "VPC to create the endpoints in."
  type        = string
}

variable "vpc_cidr" {
  description = "The VPC's CIDR. The endpoints accept HTTPS from it, because EKS Auto Mode gives every pod an address in the VPC."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the endpoints' network interfaces, one per Availability Zone the agents run in."
  type        = list(string)
}

variable "endpoints" {
  description = "Which AWS services to reach through an interface endpoint instead of the internet. Keys: agentcore-gateway, bedrock-runtime, agentcore, s3vectors, sts, secretsmanager, sqs, ecr-api, ecr-dkr, eks-auth, oidc-eks, logs, monitoring, xray, ssm, ssmmessages, ec2messages, eks, elasticloadbalancing, bedrock."
  type        = set(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.endpoints : contains(["agentcore-gateway", "bedrock-runtime", "agentcore", "s3vectors", "sts", "secretsmanager", "sqs", "ecr-api", "ecr-dkr", "eks-auth", "oidc-eks", "logs", "monitoring", "xray", "ssm", "ssmmessages", "ec2messages", "eks", "elasticloadbalancing", "bedrock"], e)])
    error_message = "Supported endpoints: agentcore-gateway, bedrock-runtime, agentcore, s3vectors, sts, secretsmanager, sqs, ecr-api, ecr-dkr, eks-auth, oidc-eks, logs, monitoring, xray, ssm, ssmmessages, ec2messages, eks, elasticloadbalancing, bedrock."
  }
}

variable "agentcore_gateway_arns" {
  description = "The AgentCore gateways the agentcore-gateway endpoint admits. Its endpoint policy allows requests to these and refuses every other gateway, so a workload in the VPC can't use the endpoint to reach a gateway the platform didn't create."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
