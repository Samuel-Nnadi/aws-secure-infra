# =============================================================================
# providers.tf — Terraform + AWS provider configuration
# =============================================================================

terraform {
  # Pin a modern Terraform CLI.
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    # Used to generate a globally-unique suffix for the S3 bucket name.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# -----------------------------------------------------------------------------
# AWS provider. The region is parameterized (see variables.tf) so the same
# configuration can be deployed to any region without code changes.
#
# `default_tags` are applied to every taggable resource this provider creates,
# which keeps cost-allocation and ownership tags consistent across the whole
# stack without repeating them on each resource.
# -----------------------------------------------------------------------------
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
