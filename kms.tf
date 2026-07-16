# =============================================================================
# kms.tf — customer-managed key (CMK) for encrypting data at rest
#
# A single CMK encrypts both the S3 bucket (SSE-KMS) and the SNS alerts topic.
# A CMK (vs. AWS-owned/AES256 keys) gives us key rotation, an auditable key
# policy, and CloudTrail visibility into every decrypt — which is why Trivy
# flags AES256-only encryption (AWS-0132) and unencrypted SNS (AWS-0095).
#
# The key policy grants:
#   * the account root full control (so IAM policies can further delegate),
#   * S3, SNS, and CloudWatch the minimum crypto actions they need to use the
#     key on our behalf.
# =============================================================================

resource "aws_kms_key" "main" {
  description             = "${local.name_prefix} CMK for S3 + SNS encryption at rest"
  deletion_window_in_days = 7
  enable_key_rotation     = true # annual automatic rotation

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Root account retains full control; without this, a key policy can lock
        # everyone out irrecoverably. Standard AWS-recommended baseline statement.
        Sid       = "EnableRootAccountAdmin"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # Let S3 and SNS use the key for encrypt/decrypt on our resources.
        Sid    = "AllowServiceUse"
        Effect = "Allow"
        Principal = {
          Service = ["s3.amazonaws.com", "sns.amazonaws.com"]
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
      {
        # CloudWatch alarms publish to the SNS topic and must be able to encrypt
        # the message payload under this key.
        Sid       = "AllowCloudWatchPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-cmk"
  }
}

# Friendly alias so the key is easy to find in the console.
resource "aws_kms_alias" "main" {
  name          = "alias/${local.name_prefix}"
  target_key_id = aws_kms_key.main.key_id
}
