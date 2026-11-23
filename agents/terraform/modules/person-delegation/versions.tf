terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
    # For the exchanger client only (main.tf says why).
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.110"
    }
  }
}
