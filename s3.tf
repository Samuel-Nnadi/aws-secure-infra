# =============================================================================
# s3.tf — secure object storage
#
# A private, versioned, encrypted bucket with a globally-unique name and a hard
# public-access lockdown. S3 bucket names are global across all AWS accounts, so
# we append a random suffix to avoid collisions.
# =============================================================================

# Random suffix so the bucket name is globally unique without manual coordination.
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# -----------------------------------------------------------------------------
# The bucket itself. Named "<project>-<env>-app-data-<random>".
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "app_data" {
  bucket = "${local.name_prefix}-app-data-${random_id.bucket_suffix.hex}"

  tags = {
    Name = "${local.name_prefix}-app-data"
  }
}

# -----------------------------------------------------------------------------
# Public access block — the critical control.
#
# All four flags are true, which is the strongest setting: it blocks public
# ACLs and public bucket policies both at write time (ignore/block) and at
# evaluation time (restrict). Even if someone later attaches a public policy by
# mistake, S3 will refuse to honor it while this block is in place.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "app_data" {
  bucket = aws_s3_bucket.app_data.id

  block_public_acls       = true
  block_public_policy      = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# Versioning — keeps prior object versions so accidental overwrites/deletes are
# recoverable (data durability).
# -----------------------------------------------------------------------------
resource "aws_s3_bucket_versioning" "app_data" {
  bucket = aws_s3_bucket.app_data.id

  versioning_configuration {
    status = "Enabled"
  }
}

# -----------------------------------------------------------------------------
# Server-side encryption at rest (AES-256).
#
# Not explicitly requested, but a private data bucket should never store
# plaintext objects. SSE-S3 is the zero-config baseline; swap to aws:kms for a
# customer-managed key if compliance requires it.
# -----------------------------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "app_data" {
  bucket = aws_s3_bucket.app_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
