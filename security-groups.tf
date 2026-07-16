# =============================================================================
# security-groups.tf — least-privilege firewalls
#
# Two security groups implement the 3-tier trust boundary:
#
#   internet ──(80/443 any, 22 admin-IP)──▶ [EC2 SG] ──(5432 only)──▶ [RDS SG]
#
# The RDS SG trusts the EC2 SG *by reference* (source_security_group_id), not by
# IP. That means only traffic originating from instances in the EC2 SG can reach
# the database — the rule automatically follows the instances, and the database
# has no public ingress path at all.
#
# NOTE: this uses the modern rule resources (aws_vpc_security_group_ingress_rule
# / _egress_rule) instead of inline `ingress`/`egress` blocks. Each rule is a
# separate, individually-managed resource — the AWS-provider-recommended pattern
# in v5.x, which avoids the state drift that inline rules are prone to.
# =============================================================================

# -----------------------------------------------------------------------------
# EC2 Security Group — the public-facing application firewall.
# -----------------------------------------------------------------------------
resource "aws_security_group" "ec2" {
  name        = "${local.name_prefix}-ec2-sg"
  description = "Web tier: HTTP/HTTPS from anywhere, SSH from admin range only"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-ec2-sg"
  }
}

# HTTP from anywhere — public web traffic.
resource "aws_vpc_security_group_ingress_rule" "ec2_http" {
  security_group_id = aws_security_group.ec2.id
  description       = "HTTP from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# HTTPS from anywhere — public web traffic (TLS).
resource "aws_vpc_security_group_ingress_rule" "ec2_https" {
  security_group_id = aws_security_group.ec2.id
  description       = "HTTPS from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

# SSH ONLY from the administrator IP range (var.ssh_allowed_cidr).
# This is the single most important least-privilege control on the web tier:
# management access is never exposed to 0.0.0.0/0.
resource "aws_vpc_security_group_ingress_rule" "ec2_ssh" {
  security_group_id = aws_security_group.ec2.id
  description       = "SSH from administrator range only"
  cidr_ipv4         = var.ssh_allowed_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# Allow all outbound traffic (needed for OS updates, package installs, etc.).
resource "aws_vpc_security_group_egress_rule" "ec2_all_egress" {
  security_group_id = aws_security_group.ec2.id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # -1 = all protocols/ports
}

# -----------------------------------------------------------------------------
# RDS Security Group — the private database firewall.
# -----------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Database tier: DB port from the EC2 SG only, no public ingress"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-rds-sg"
  }
}

# The ONLY inbound rule: the database port, sourced from the EC2 security group.
# `referenced_security_group_id` (not a CIDR) is what enforces least privilege —
# only instances in the EC2 SG can connect, and there is no public path in.
# var.db_port defaults to 5432 (PostgreSQL); set it to 3306 for MySQL.
resource "aws_vpc_security_group_ingress_rule" "rds_from_ec2" {
  security_group_id            = aws_security_group.rds.id
  description                  = "DB port from the EC2 security group only"
  referenced_security_group_id = aws_security_group.ec2.id
  from_port                    = var.db_port
  to_port                      = var.db_port
  ip_protocol                  = "tcp"
}

# Allow all outbound (RDS uses this for things like S3-based backups / patching).
resource "aws_vpc_security_group_egress_rule" "rds_all_egress" {
  security_group_id = aws_security_group.rds.id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
