terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
    # The agents' Cognito clients: hashicorp/aws refuses ALLOW_TOKEN_EXCHANGE_DELEGATION in
    # explicit_auth_flows at plan time, and the Cloud Control provider passes it through.
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.110"
    }
  }
}
