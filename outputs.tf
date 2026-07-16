# =============================================================================
# outputs.tf — useful values surfaced after `terraform apply`
#
# Credential material (DB password) is never output. The endpoints/IPs below
# are safe to display and are what you need to actually use the stack.
# =============================================================================

output "ec2_public_ip" {
  description = "Public IP of the app server. Empty when enable_alb = true (the instance is private — use alb_dns_name instead)."
  value       = aws_instance.app.public_ip
}

output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer. Null unless enable_alb = true; this is the address to hit in production mode."
  value       = var.enable_alb ? aws_lb.main[0].dns_name : null
}

output "application_url" {
  description = "The address to reach the app: the ALB DNS name in production mode, or the instance's public IP in dev mode."
  value       = var.enable_alb ? "http://${aws_lb.main[0].dns_name}" : "http://${aws_instance.app.public_ip}"
}

output "ec2_instance_id" {
  description = "ID of the application server instance."
  value       = aws_instance.app.id
}

output "rds_endpoint" {
  description = "Connection endpoint (host:port) of the RDS database."
  value       = aws_db_instance.main.endpoint
}

output "rds_address" {
  description = "Hostname of the RDS database (without the port)."
  value       = aws_db_instance.main.address
}

output "s3_bucket_name" {
  description = "Name of the private application-data S3 bucket."
  value       = aws_s3_bucket.app_data.bucket
}

output "vpc_id" {
  description = "ID of the VPC hosting the stack."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (web tier)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (data tier)."
  value       = aws_subnet.private[*].id
}

# -----------------------------------------------------------------------------
# AIOps pipeline outputs
# -----------------------------------------------------------------------------
output "sns_alert_topic_arn" {
  description = "ARN of the SNS topic that receives anomaly alerts and remediation notices. Subscribe Slack/PagerDuty/Lambda here."
  value       = aws_sns_topic.alerts.arn
}

output "cpu_anomaly_alarm_name" {
  description = "Name of the ML anomaly-detection alarm on EC2 CPU."
  value       = aws_cloudwatch_metric_alarm.ec2_cpu_anomaly.alarm_name
}

output "remediation_lambda_name" {
  description = "Name of the self-healing remediation Lambda function."
  value       = aws_lambda_function.remediation.function_name
}

output "auto_remediation_active" {
  description = "Whether the Lambda will actually restart the instance (true) or run in dry-run/observe-only mode (false)."
  value       = var.enable_auto_remediation
}

output "devops_guru_dashboard" {
  description = "Amazon DevOps Guru dashboard URL plus enablement status and next steps for this stack."
  value = join("\n", [
    "DevOps Guru dashboard: https://${var.aws_region}.console.aws.amazon.com/devops-guru/#/dashboard",
    "Status for this stack: ${var.enable_devops_guru ? "ENABLED" : "DISABLED"}",
    var.enable_devops_guru
    ? "Analyzing all resources tagged with app-boundary key 'DevOps-Guru-aws-secure-infra'; insights flow to the SNS topic and the remediation Lambda."
    : "Set enable_devops_guru = true to turn it on (billed per resource-hour; only one resource-collection type may be active per account).",
  ])
}
