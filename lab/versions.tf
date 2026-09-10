terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region

  # `aws login` writes temporary credentials to the DEFAULT profile, so the
  # normal case is to leave aws_profile empty and let the SDK resolve
  # credentials the usual way. Setting a profile name here when one does not
  # exist produces a confusing "failed to get shared config profile" error.
  profile = var.aws_profile != "" ? var.aws_profile : null

  # Stamped on every resource this config creates. Two payoffs: one CLI call
  # finds every orphan you forgot, and you are about to sell tag hygiene to
  # clients, so run it on yourself first.
  default_tags {
    tags = {
      Project   = "Nameplate Analytics"
      ManagedBy = "terraform"
      Purpose   = "gpu-finops-lab"
    }
  }
}
