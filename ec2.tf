# =============================================================================
# ec2.tf — the application server (the "web tier")
#
# A single t3.micro running the latest Amazon Linux 2023, placed in a PUBLIC
# subnet and protected by the EC2 security group.
# =============================================================================

# -----------------------------------------------------------------------------
# Latest Amazon Linux 2023 AMI.
#
# We resolve it from the AWS-published SSM Parameter Store path rather than an
# aws_ami name filter. AWS keeps this parameter pointed at the current AL2023
# release for the region, so the instance always launches on a patched, current
# image without us hardcoding an AMI ID.
# -----------------------------------------------------------------------------
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# -----------------------------------------------------------------------------
# The application instance.
#
# Relationships made explicit:
#   * subnet_id            -> first PUBLIC subnet (internet-facing tier)
#   * vpc_security_group_ids-> EC2 SG (80/443 open, 22 admin-only)
#   * ami                  -> latest AL2023 (resolved above)
# -----------------------------------------------------------------------------
resource "aws_instance" "app" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = var.ec2_instance_type

  # Placement depends on the topology:
  #   enable_alb = false -> public subnet + public IP (direct web tier, dev)
  #   enable_alb = true  -> private subnet, no public IP (behind the ALB)
  subnet_id                   = var.enable_alb ? aws_subnet.private[0].id : aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.ec2.id]
  associate_public_ip_address = var.enable_alb ? false : true

  # Enforce IMDSv2 (token-required) to protect instance credentials against
  # SSRF-style metadata theft — a standard EC2 hardening baseline.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Encrypt the root volume at rest.
  root_block_device {
    encrypted   = true
    volume_size = 8
    volume_type = "gp3"
  }

  # Basic bootstrap: update packages and drop a system-check marker on boot.
  # Replace this placeholder with your real provisioning (web server, agent,
  # container runtime, etc.).
  user_data = <<-EOT
    #!/bin/bash
    set -euo pipefail

    # Update all packages to the latest patched versions.
    dnf update -y

    # Simple boot-time system check, written to a log for verification.
    {
      echo "===== ${local.name_prefix} boot check ($(date -u)) ====="
      echo "hostname: $(hostname)"
      echo "kernel:   $(uname -r)"
      echo "uptime:   $(uptime)"
    } > /var/log/boot-check.log 2>&1
  EOT

  tags = {
    Name = "${local.name_prefix}-app-server"
    Tier = "web"
  }
}
