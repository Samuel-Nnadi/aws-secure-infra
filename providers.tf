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

    # Zips the inline remediation Lambda source (aiops.tf) at apply time.
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
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

      # DevOps Guru "app boundary" tag. Its tag-based resource collection can
      # only target keys that begin with "DevOps-Guru-", so we stamp every
      # resource in the stack with this key. aiops.tf points DevOps Guru at it,
      # which enrolls the whole 3-tier stack for ML analysis in one shot.
      # The key is a static literal because DevOps Guru matches on the key
      # string, and Terraform tag keys cannot be interpolated at the provider
      # default_tags level in a way DevOps Guru would resolve.
      "DevOps-Guru-aws-secure-infra" = var.environment
    }
  }
}
