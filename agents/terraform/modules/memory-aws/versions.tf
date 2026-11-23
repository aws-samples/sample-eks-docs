terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.73"
    }
    # For the session state cache's disabled default user, which Valkey insists on giving a
    # password even though the user is off.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}
