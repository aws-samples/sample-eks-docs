terraform {
  required_version = ">= 1.9"

  required_providers {
    # Looks up the public address of the machine running Terraform, for
    # cluster_endpoint_public_access with no CIDRs named.
    http = {
      source  = "hashicorp/http"
      version = "~> 3.6"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.9"
    }
    # Required by modules/memory-aws and modules/platform-secrets, which generate the passwords no
    # human should invent.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
    # Required by modules/ingress for ingress_self_signed_certificate.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
    # Required by modules/agent-cluster for the IAM-propagation wait before the ARGOCD capability.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
    # The gateway's rate limits (gateway_rate_limits): awscc has the resource and aws doesn't.
    awscc = {
      source  = "hashicorp/awscc"
      version = "~> 1.110"
    }
  }

  # No backend block. State for an agent platform belongs in whatever the organization already uses,
  # with locking and encryption, and a template that picked one for you would either be wrong or
  # quietly create a bucket nobody reviewed. Configure it in a backend.tf alongside this file, or
  # pass -backend-config.
}

provider "aws" {
  region = var.region

  # eks-agents/cluster is what makes a teardown verifiable. Without it the tags below name the stack
  # and the path but not the deployment, so nothing ties a resource to one cluster -- and
  # `scripts/teardown.sh` can only sweep by NAME PREFIX, which misses every resource terraform
  # names for something other than the cluster (the ECR repositories, the tools Lambda) and misses
  # everything when `name` is not the cluster's own name: a full stack survives a teardown that
  # reports clean. Keep this tag.
  default_tags {
    tags = {
      "app.kubernetes.io/part-of" = "eks-agents-paved-paths"
      "eks-agents/path"           = "aws-services"
      "eks-agents/cluster"        = var.name
    }
  }
}

# The same provider with EC2-safe tag keys, for the one module that launches an instance.
#
# RunInstances REFUSES A TAG KEY CONTAINING `/`, and it is the only API in this stack that does:
#
#   InvalidParameterValue: 'app.kubernetes.io/part-of' is not a valid tag key. Tag keys must match
#   pattern ([0-9a-zA-Z\-_+=,.@:]{1,255})
#
# Every other EC2 resource this root creates -- the VPC, the subnets, the NAT gateway, the EIP --
# takes all three keys above without complaint, so the restriction is specific to instance tagging
# rather than to EC2. A default tag cannot be dropped for one resource, only overridden in value, so
# the key itself has to come from a different provider configuration.
#
# `/` becomes `.`. The keys still name the same things and scripts/teardown.sh queries both
# spellings, which it has to: a sweep that knew only the slashed form would report nothing left while
# the bastion and its security group were still running.
#
# Without it, even with the module setting EC2-safe keys for its OWN tags, the apply reaches
# RunInstances and fails there, after the security group, the instance profile, the role and the
# EKS access entry are created. The bastion is on by default, so the default configuration of this
# root cannot complete an apply without this provider.
provider "aws" {
  alias  = "ec2_instance_tags"
  region = var.region

  default_tags {
    tags = {
      "app.kubernetes.io.part-of" = "eks-agents-paved-paths"
      "eks-agents.path"           = "aws-services"
      "eks-agents.cluster"        = var.name
    }
  }
}

# THE IDENTITY CENTER REGION, which is frequently not the cluster's.
#
# An organization has at most one Identity Center instance and it lives in exactly one region. Every
# sso-admin and identitystore call has to be made there, so the module's discovery data source and
# the group, users and memberships it creates run through this provider rather than the default one.
#
# Defaults to the cluster's region, which is correct for the common same-region case and means this
# alias costs nothing when argocd_idc_region is unset. Set argocd_idc_region and the whole Identity
# Center wiring moves with it -- discovery included, which is what makes a cross-region instance
# zero manual steps instead of three.
provider "aws" {
  alias  = "idc"
  region = var.argocd_idc_region != "" ? var.argocd_idc_region : var.region
}

provider "awscc" {
  region = var.region
}
