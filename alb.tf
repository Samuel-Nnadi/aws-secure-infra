# =============================================================================
# alb.tf — Application Load Balancer (production topology only)
#
# Created only when var.enable_alb = true. The ALB becomes the single
# internet-facing entry point; the EC2 instance moves behind it into a private
# subnet. Traffic path:
#
#   internet ─80/443─▶ [ALB SG] ALB (public subnets)
#                          │ container_port
#                          ▼
#                      [EC2 SG] EC2 instance (private subnet)
#
# The instance's security group is updated (in security-groups.tf) to accept the
# app port ONLY from the ALB security group, so the instance can never be
# reached directly from the internet.
# =============================================================================

# -----------------------------------------------------------------------------
# ALB security group — the new public edge. Allows web traffic from anywhere;
# all egress open so it can forward to the instances.
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  count = var.enable_alb ? 1 : 0

  name        = "${local.name_prefix}-alb-sg"
  description = "ALB edge: HTTP/HTTPS from anywhere"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-alb-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  count = var.enable_alb ? 1 : 0

  security_group_id = aws_security_group.alb[0].id
  description       = "HTTP from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count = var.enable_alb ? 1 : 0

  security_group_id = aws_security_group.alb[0].id
  description       = "HTTPS from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all_egress" {
  count = var.enable_alb ? 1 : 0

  security_group_id = aws_security_group.alb[0].id
  description       = "Allow all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# -----------------------------------------------------------------------------
# The load balancer, spanning both public subnets for AZ redundancy.
# -----------------------------------------------------------------------------
resource "aws_lb" "main" {
  count = var.enable_alb ? 1 : 0

  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = aws_subnet.public[*].id

  # Drop invalid/malformed HTTP headers at the edge — a cheap hardening win.
  drop_invalid_header_fields = true

  tags = {
    Name = "${local.name_prefix}-alb"
  }
}

# -----------------------------------------------------------------------------
# Target group — where the ALB forwards traffic. Targets the instance on the
# application port, with a health check so unhealthy instances are drained.
# -----------------------------------------------------------------------------
resource "aws_lb_target_group" "app" {
  count = var.enable_alb ? 1 : 0

  name        = "${local.name_prefix}-tg"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    enabled             = true
    path                = "/"
    protocol            = "HTTP"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }

  tags = {
    Name = "${local.name_prefix}-tg"
  }
}

# Register the EC2 instance with the target group.
resource "aws_lb_target_group_attachment" "app" {
  count = var.enable_alb ? 1 : 0

  target_group_arn = aws_lb_target_group.app[0].arn
  target_id        = aws_instance.app.id
  port             = var.container_port
}

# -----------------------------------------------------------------------------
# HTTP listener on :80 forwarding to the target group.
#
# NOTE: for real production, add an HTTPS (:443) listener with an ACM
# certificate and redirect :80 -> :443. That requires a domain + certificate,
# so it is intentionally left out of this baseline; the ALB SG already permits
# 443 so adding the listener later needs no SG change.
# -----------------------------------------------------------------------------
resource "aws_lb_listener" "http" {
  count = var.enable_alb ? 1 : 0

  load_balancer_arn = aws_lb.main[0].arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[0].arn
  }
}
