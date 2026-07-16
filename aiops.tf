# =============================================================================
# aiops.tf — Amazon DevOps Guru + EventBridge-driven self-healing
#
# This is the ANALYSIS + REMEDIATION half of the pipeline. End-to-end flow:
#
#   ┌────────────────────────────────────────────────────────────────────────┐
#   │ 1. TELEMETRY (monitoring.tf)                                            │
#   │    EC2/RDS/ELB/S3 metrics + the CloudWatch anomaly alarm                │
#   └───────────────┬───────────────────────────────┬────────────────────────┘
#                   │                                │
#                   ▼                                ▼
#   ┌───────────────────────────────┐   ┌────────────────────────────────────┐
#   │ 2a. DevOps Guru               │   │ 2b. CloudWatch anomaly alarm        │
#   │  ML-correlates the whole      │   │  fires -> SNS (human notification)  │
#   │  tagged stack, raises an      │   │                                     │
#   │  "insight" on degradation     │   │                                     │
#   └───────────────┬───────────────┘   └───────────────┬────────────────────┘
#                   │ emits event                        │ emits event
#                   ▼                                    ▼
#   ┌────────────────────────────────────────────────────────────────────────┐
#   │ 3. EventBridge rule  (matches DevOps Guru "New Insight" +               │
#   │                       CloudWatch "Alarm State Change" events)           │
#   └───────────────────────────────┬────────────────────────────────────────┘
#                                   │ invokes
#                                   ▼
#   ┌────────────────────────────────────────────────────────────────────────┐
#   │ 4. remediation_lambda (Python + boto3)                                  │
#   │    parses the payload, checks severity, and — if auto-remediation is    │
#   │    enabled — runs `ssm:SendCommand` to restart the web server, scoped   │
#   │    by least-privilege IAM to THIS instance and the shell-script doc.    │
#   └────────────────────────────────────────────────────────────────────────┘
# =============================================================================

data "aws_region" "current" {}

# =============================================================================
# 2a. Amazon DevOps Guru — enroll the tagged stack for ML analysis.
# =============================================================================
# Tag-based resource collection: DevOps Guru analyzes every resource carrying
# the "DevOps-Guru-aws-secure-infra" tag key (stamped on everything via
# provider default_tags in providers.tf). tag_values = ["*"] means "any value".
#
# Toggled by var.enable_devops_guru because (a) it is billed per analyzed
# resource-hour and (b) an account may only have ONE resource-collection type
# enabled at a time.
resource "aws_devopsguru_resource_collection" "stack" {
  count = var.enable_devops_guru ? 1 : 0

  type = "AWS_TAGS"

  tags {
    app_boundary_key = "DevOps-Guru-aws-secure-infra"
    tag_values       = ["*"]
  }
}

# Route DevOps Guru's own notifications (new insights) to the SNS topic too, so
# humans see the insight in parallel with the automated path below.
resource "aws_devopsguru_notification_channel" "sns" {
  count = var.enable_devops_guru ? 1 : 0

  sns {
    topic_arn = aws_sns_topic.alerts.arn
  }
}

# =============================================================================
# 4. Remediation Lambda — the self-healing actuator.
# =============================================================================

# --- Package the inline Python handler into a deployment zip -----------------
# The handler source is written to the module directory at plan/apply time and
# zipped by the archive provider — no external build step or artifact bucket.
data "archive_file" "remediation" {
  type        = "zip"
  output_path = "${path.module}/.build/remediation_lambda.zip"

  source {
    filename = "index.py"
    content  = local.remediation_handler_src
  }
}

locals {
  # -------------------------------------------------------------------------
  # The Lambda handler. It:
  #   1. Parses the incoming EventBridge event (DevOps Guru insight OR a
  #      CloudWatch alarm state change).
  #   2. Decides whether it represents a service-degradation anomaly worth
  #      acting on (high severity / ALARM state).
  #   3. If DRY_RUN is false, calls ssm:SendCommand to restart the web server
  #      (AWS-RunShellScript running `systemctl restart` + a health echo).
  #   4. Always logs its decision so the flow is auditable in CloudWatch Logs.
  #
  # Least privilege is enforced by the Lambda's IAM policy (below), NOT by the
  # code — the code cannot call anything the role does not allow.
  # -------------------------------------------------------------------------
  remediation_handler_src = <<-PY
    import json
    import os
    import boto3

    ssm = boto3.client("ssm")

    INSTANCE_ID = os.environ["TARGET_INSTANCE_ID"]
    SNS_TOPIC   = os.environ["SNS_TOPIC_ARN"]
    DRY_RUN     = os.environ.get("DRY_RUN", "true").lower() == "true"
    # Command run on the box to recover the web tier. Adjust the service name to
    # match your application (nginx/httpd/your-app.service).
    RESTART_CMD = os.environ.get("RESTART_COMMAND", "systemctl restart nginx || systemctl restart httpd || true")

    sns = boto3.client("sns")


    def _is_actionable(event: dict) -> tuple[bool, str]:
        """Return (should_remediate, human_reason) for a DevOps Guru insight or
        a CloudWatch alarm-state-change event."""
        source = event.get("source", "")
        detail = event.get("detail", {}) or {}

        # DevOps Guru "New Insight Open" events.
        if source == "aws.devops-guru":
            severity = str(detail.get("insightSeverity", "")).lower()
            itype    = str(detail.get("insightType", "")).lower()
            # Act only on high-severity, reactive (something-is-wrong-now) insights.
            if severity == "high" and itype == "reactive":
                return True, f"DevOps Guru high-severity reactive insight: {detail.get('insightDescription', 'n/a')}"
            return False, f"DevOps Guru insight ignored (severity={severity}, type={itype})"

        # CloudWatch anomaly alarm transitions.
        if source == "aws.cloudwatch":
            state = (detail.get("state", {}) or {}).get("value", "")
            if state == "ALARM":
                return True, f"CloudWatch alarm entered ALARM: {detail.get('alarmName', 'n/a')}"
            return False, f"CloudWatch alarm state ignored: {state}"

        return False, f"Unrecognized event source: {source}"


    def handler(event, context):
        print("Received event:", json.dumps(event))
        should, reason = _is_actionable(event)
        print("Decision:", {"should_remediate": should, "reason": reason, "dry_run": DRY_RUN})

        if not should:
            return {"action": "none", "reason": reason}

        if DRY_RUN:
            # Notify but take no action — lets you validate the full flow safely.
            msg = f"[DRY RUN] Would restart {INSTANCE_ID}. Reason: {reason}"
            print(msg)
            sns.publish(TopicArn=SNS_TOPIC, Subject="AIOps dry-run remediation", Message=msg)
            return {"action": "dry_run", "instance": INSTANCE_ID, "reason": reason}

        # Real remediation: restart the web service via SSM Run Command.
        resp = ssm.send_command(
            InstanceIds=[INSTANCE_ID],
            DocumentName="AWS-RunShellScript",
            Comment="AIOps self-heal: restart web tier after anomaly",
            Parameters={"commands": [RESTART_CMD, "echo restarted at $(date -u)"]},
        )
        command_id = resp["Command"]["CommandId"]
        msg = f"Self-heal issued for {INSTANCE_ID} (SSM command {command_id}). Reason: {reason}"
        print(msg)
        sns.publish(TopicArn=SNS_TOPIC, Subject="AIOps auto-remediation executed", Message=msg)
        return {"action": "remediated", "instance": INSTANCE_ID, "ssm_command_id": command_id}
  PY
}

# --- Lambda execution role ---------------------------------------------------
resource "aws_iam_role" "remediation_lambda" {
  name = "${local.name_prefix}-remediation-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-remediation-lambda-role"
  }
}

# Least-privilege inline policy. The Lambda can do EXACTLY four things:
#   1. Write its own logs.
#   2. Run the shell-script SSM document — but only against THIS instance.
#   3. Read SSM command results (to confirm the restart).
#   4. Publish to our SNS topic only.
# It cannot touch any other instance, run any other document, or reach any
# other AWS resource.
resource "aws_iam_role_policy" "remediation_lambda" {
  name = "${local.name_prefix}-remediation-lambda-policy"
  role = aws_iam_role.remediation_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.name_prefix}-remediation*"
      },
      {
        # SendCommand is scoped to (a) our specific instance and (b) the single
        # AWS-RunShellScript document — the two resources SendCommand accepts.
        Sid    = "SsmSendCommandToTargetInstanceOnly"
        Effect = "Allow"
        Action = "ssm:SendCommand"
        Resource = [
          "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.app.id}",
          "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript"
        ]
      },
      {
        # Reading command status/results is not resource-scopable in IAM, so it
        # is granted separately and narrowly to the two read actions.
        Sid      = "SsmReadCommandResults"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommands", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
      {
        Sid      = "PublishToAlertsTopicOnly"
        Effect   = "Allow"
        Action   = "sns:Publish"
        Resource = aws_sns_topic.alerts.arn
      }
    ]
  })
}

# --- The function itself ------------------------------------------------------
resource "aws_lambda_function" "remediation" {
  function_name = "${local.name_prefix}-remediation"
  description   = "AIOps self-healing: restarts the web tier via SSM on a degradation anomaly."

  role    = aws_iam_role.remediation_lambda.arn
  handler = "index.handler"
  runtime = "python3.12"
  timeout = 60

  filename         = data.archive_file.remediation.output_path
  source_code_hash = data.archive_file.remediation.output_base64sha256

  environment {
    variables = {
      TARGET_INSTANCE_ID = aws_instance.app.id
      SNS_TOPIC_ARN      = aws_sns_topic.alerts.arn
      # DRY_RUN is the inverse of the operator's opt-in. Default posture is
      # "observe only" until auto-remediation is explicitly enabled.
      DRY_RUN = var.enable_auto_remediation ? "false" : "true"
    }
  }

  tags = {
    Name = "${local.name_prefix}-remediation"
  }
}

# CloudWatch log group with a retention policy (an unbounded default log group
# is a common cost/compliance gap).
resource "aws_cloudwatch_log_group" "remediation_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.remediation.function_name}"
  retention_in_days = 30

  tags = {
    Name = "${local.name_prefix}-remediation-logs"
  }
}

# =============================================================================
# 3. EventBridge — route anomaly events to the Lambda.
# =============================================================================
# One rule matches BOTH signal sources:
#   * DevOps Guru "New Insight Open" events
#   * CloudWatch alarm state changes for OUR anomaly alarm
# The Lambda's own logic decides which are actionable, so the rule can be broad
# without causing unwanted restarts.
resource "aws_cloudwatch_event_rule" "anomaly" {
  name        = "${local.name_prefix}-anomaly-events"
  description = "Route DevOps Guru insights and the CPU anomaly alarm to the remediation Lambda."

  event_pattern = jsonencode({
    "source" : ["aws.devops-guru", "aws.cloudwatch"],
    "detail-type" : ["DevOps Guru New Insight Open", "CloudWatch Alarm State Change"],
    "resources" : [{ "wildcard" : "*${local.name_prefix}*" }]
  })

  tags = {
    Name = "${local.name_prefix}-anomaly-events"
  }
}

resource "aws_cloudwatch_event_target" "remediation" {
  rule      = aws_cloudwatch_event_rule.anomaly.name
  target_id = "remediation-lambda"
  arn       = aws_lambda_function.remediation.arn
}

# Allow EventBridge to invoke the Lambda (source ARN scopes it to THIS rule).
resource "aws_lambda_permission" "eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.remediation.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.anomaly.arn
}
