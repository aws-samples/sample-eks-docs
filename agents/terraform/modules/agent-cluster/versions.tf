terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"

      # A SECOND AWS PROVIDER, FOR THE IDENTITY CENTER REGION.
      #
      # An organization has at most ONE Identity Center instance, in one region, and it is commonly
      # not the cluster's -- us-east-1 while the cluster is in us-west-2 is the ordinary case, not
      # the exception. Every sso-admin and identitystore call has to be made in THAT region.
      #
      # Without this alias the discovery data source and the three identity-store resources run in
      # the cluster's region, so a cross-region instance means: discovery finds nothing, the caller
      # has to supply argocd_idc_instance_arn by hand, and argocd_manage_admin_group has to be false
      # because the group and users would be created in the wrong region. That leaves the Argo CD
      # capability with NO rbac_role_mapping and therefore no administrator, which applies cleanly
      # and is unopenable.
      #
      # So this is not a convenience. It is what makes the cross-region case the same number of
      # manual steps as the same-region one: zero, beyond creating the instance itself, which the
      # provider still has no resource for.
      configuration_aliases = [aws, aws.idc]
    }
    # Only for the IAM-propagation wait before the ARGOCD capability. See main.tf.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.14"
    }
  }
}
