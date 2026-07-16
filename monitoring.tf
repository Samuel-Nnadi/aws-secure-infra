# =============================================================================
# monitoring.tf — ML-driven anomaly detection (the telemetry SOURCE)
#
# This is the first stage of the AIOps pipeline:
#
#   EC2 CPU metric ─▶ CloudWatch Anomaly Detection (band model)
#                       │
#                       ├─ band breached ─▶ SNS topic ─▶ email / chatops
#                       └─ (also feeds DevOps Guru + the remediation path in
#                          aiops.tf)
#
# Instead of a brittle static threshold ("alert at 80% CPU"), CloudWatch trains
# an ML model on the metric's own history and alerts when the value leaves a
# dynamically-computed "normal" band. This adapts to daily/weekly traffic
# patterns automatically — a nightly batch spike that is normal at 2am won't
# page anyone, but the same spike at an unusual time will.
# =============================================================================

# -----------------------------------------------------------------------------
# SNS topic — the alert fan-out point. The anomaly alarm publishes here; you
# subscribe email, Slack, PagerDuty, or a Lambda to it.
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-aiops-alerts"

  # Encrypt messages at rest with our CMK (fixes Trivy AWS-0095). The CloudWatch
  # publish path and the KMS key policy (kms.tf) are aligned to allow this.
  kms_master_key_id = aws_kms_key.main.id

  tags = {
    Name = "${local.name_prefix}-aiops-alerts"
  }
}

# Optional email subscription. Created only when var.alert_email is set. AWS
# sends a confirmation link that must be clicked before delivery begins.
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Allow CloudWatch alarms to publish to the topic. SNS topics are private by
# default; this resource-policy grants cloudwatch.amazonaws.com Publish rights,
# scoped to this account.
resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudWatchAlarmsToPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = { "AWS:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      }
    ]
  })
}

# Current account ID, used to scope the SNS policy above (and IAM in aiops.tf).
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Anomaly-detection alarm on EC2 CPU utilization.
#
# There is no `threshold = 80`. Instead the alarm is defined by TWO metric
# queries that CloudWatch evaluates together:
#
#   m1  the raw metric  (AWS/EC2 CPUUtilization for our instance)
#   ad1 the ML band     (ANOMALY_DETECTION_BAND(m1, <band_width>))
#
# `threshold_metric_id = "ad1"` tells the alarm to compare the raw metric
# against the ML band rather than a number. `comparison_operator` set to
# LessThanLowerOrGreaterThanUpperThreshold fires when CPU is anomalously HIGH
# *or* anomalously LOW — a sudden drop to ~0% (a hung/crashed service) is just
# as much a "service degradation" signal as a runaway spike.
#
# The second argument to ANOMALY_DETECTION_BAND is the standard-deviation band
# width (var.anomaly_band_width, default 2). Wider = fewer, higher-confidence
# alerts.
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "ec2_cpu_anomaly" {
  alarm_name        = "${local.name_prefix}-ec2-cpu-anomaly"
  alarm_description = "ML anomaly detection on EC2 CPU — fires when CPU leaves the learned normal band (high OR low)."

  comparison_operator = "LessThanLowerOrGreaterThanUpperThreshold"
  evaluation_periods  = 2
  threshold_metric_id = "ad1"

  # Query 1: the ML anomaly-detection band, derived from m1.
  metric_query {
    id          = "ad1"
    expression  = "ANOMALY_DETECTION_BAND(m1, ${var.anomaly_band_width})"
    label       = "CPUUtilization (expected band)"
    return_data = true
  }

  # Query 2: the raw source metric for our specific instance.
  metric_query {
    id          = "m1"
    return_data = true

    metric {
      metric_name = "CPUUtilization"
      namespace   = "AWS/EC2"
      period      = 300
      stat        = "Average"

      dimensions = {
        InstanceId = aws_instance.app.id
      }
    }
  }

  # On breach OR on return-to-normal, notify the SNS topic. Sending the OK
  # action too gives responders an automatic "resolved" signal.
  alarm_actions             = [aws_sns_topic.alerts.arn]
  ok_actions                = [aws_sns_topic.alerts.arn]
  insufficient_data_actions = []

  # Treat missing data as "not breaching" — a brief metric gap shouldn't page.
  treat_missing_data = "missing"

  tags = {
    Name = "${local.name_prefix}-ec2-cpu-anomaly"
  }
}
