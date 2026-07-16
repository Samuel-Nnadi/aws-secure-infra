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
# Production hardening toggle
# -----------------------------------------------------------------------------
variable "enable_alb" {
  description = <<-EOT
    Production topology switch.

    false (default) — cost-effective dev baseline: the EC2 instance sits in a
      public subnet with a public IP and takes web traffic directly.

    true — hardened production topology: an internet-facing Application Load
      Balancer is created in the public subnets, the EC2 instance is moved to a
      PRIVATE subnet (no public IP), NAT gateways provide the instance outbound
      internet for patching, and the instance's security group only accepts web
      traffic from the ALB. This removes the instance's direct internet exposure.
  EOT
  type        = bool
  default     = false
}

variable "single_nat_gateway" {
  description = <<-EOT
    When enable_alb = true, controls NAT gateway redundancy.

    true (default) — one NAT gateway shared by both private subnets. Cheaper,
      but a single-AZ failure removes outbound internet for the private tier.

    false — one NAT gateway per AZ (highly available), at roughly double the
      NAT hourly + data cost. Recommended for real production.
  EOT
  type        = bool
  default     = true
}

variable "container_port" {
  description = "Port the application listens on, targeted by the ALB and opened in the EC2 SG when enable_alb = true. Defaults to 80 (the user_data placeholder does not run a server; adjust to your app)."
  type        = number
  default     = 80
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

# -----------------------------------------------------------------------------
# AIOps / observability
# -----------------------------------------------------------------------------
variable "alert_email" {
  description = <<-EOT
    Email address subscribed to the SNS alerts topic. Leave empty to create the
    topic without an email subscription (e.g. if you wire the topic to Slack or
    PagerDuty out of band). When set, AWS sends a confirmation email that must
    be accepted before alerts are delivered.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be a valid email address or an empty string."
  }
}

variable "anomaly_band_width" {
  description = <<-EOT
    Standard-deviation band width for the CloudWatch anomaly-detection model
    (the "2" in ANOMALY_DETECTION_BAND(m1, 2)). Larger = wider band = fewer,
    higher-confidence alerts; smaller = tighter band = more sensitive. 2 is the
    common default (~95% of normal behavior falls inside the band).
  EOT
  type        = number
  default     = 2

  validation {
    condition     = var.anomaly_band_width > 0 && var.anomaly_band_width <= 10
    error_message = "anomaly_band_width must be between 0 (exclusive) and 10."
  }
}

variable "enable_devops_guru" {
  description = <<-EOT
    Enable Amazon DevOps Guru analysis of this stack (tag-based resource
    collection). DevOps Guru is billed per resource-hour analyzed, so it is
    opt-in. NOTE: only ONE resource-collection type can be active per account —
    if another stack already enabled CloudFormation- or account-wide coverage,
    applying this will conflict.
  EOT
  type        = bool
  default     = false
}

variable "enable_auto_remediation" {
  description = <<-EOT
    When true, the remediation Lambda is allowed to actually restart the EC2
    instance via SSM in response to a high-severity anomaly. When false, the
    Lambda still runs and logs what it WOULD do, but takes no action (dry-run).
    Start with false, confirm the detection/notification flow, then enable.
  EOT
  type        = bool
  default     = false
}
