terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
    # Only for the generated certificate, and only when self_signed_certificate is set. The provider
    # makes no network call and needs no credential.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
  }
}
