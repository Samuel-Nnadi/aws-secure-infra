# =============================================================================
# variables.tf — all input parameters
#
# Every tunable is surfaced here with a safe default (except the DB password,
# which is intentionally has no default so it must be supplied explicitly and
# never lands in the repo).
# =============================================================================

# -----------------------------------------------------------------------------
# Provider / naming
# -----------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name, used as a prefix for resource names and tags."
  type        = string
  default     = "aws-secure-infra"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens only."
  }
}

variable "environment" {
  description = "Deployment environment name (e.g. dev, staging, prod)."
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

# -----------------------------------------------------------------------------
# Security
# -----------------------------------------------------------------------------
variable "ssh_allowed_cidr" {
  description = <<-EOT
    CIDR range permitted to reach the EC2 instance over SSH (port 22).
    Set this to your administrator IP as a /32 (e.g. "203.0.113.7/32").
    The default is intentionally a documentation placeholder that should be
    overridden — do NOT leave it at 0.0.0.0/0 in a real deployment.
  EOT
  type        = string
  default     = "203.0.113.0/24"

  validation {
    condition     = can(cidrhost(var.ssh_allowed_cidr, 0))
    error_message = "ssh_allowed_cidr must be a valid IPv4 CIDR block."
  }
}

# -----------------------------------------------------------------------------
# EC2
# -----------------------------------------------------------------------------
variable "ec2_instance_type" {
  description = "EC2 instance type for the application server."
  type        = string
  default     = "t3.micro"
}

# -----------------------------------------------------------------------------
# RDS
# -----------------------------------------------------------------------------
variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t3.micro"
}

variable "db_engine_version" {
  description = "PostgreSQL engine version for RDS."
  type        = string
  default     = "16.4"
}

variable "db_port" {
  description = "Database port. 5432 for PostgreSQL, 3306 for MySQL. Shared by the RDS security group rule and the DB engine."
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Name of the initial database to create."
  type        = string
  default     = "appdb"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]*$", var.db_name))
    error_message = "db_name must start with a letter and contain only letters, numbers, and underscores."
  }
}

variable "db_username" {
  description = "Master username for the RDS instance."
  type        = string
  default     = "dbadmin"
}

variable "db_password" {
  description = <<-EOT
    Master password for the RDS instance. Marked sensitive so Terraform never
    prints it. Has NO default — supply it via an environment variable
    (TF_VAR_db_password), a *.tfvars file that is gitignored, or a secrets
    manager. Never hardcode it.
  EOT
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 12
    error_message = "db_password must be at least 12 characters."
  }
}
