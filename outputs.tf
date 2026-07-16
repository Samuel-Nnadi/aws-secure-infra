# =============================================================================
# outputs.tf — useful values surfaced after `terraform apply`
#
# Credential material (DB password) is never output. The endpoints/IPs below
# are safe to display and are what you need to actually use the stack.
# =============================================================================

output "ec2_public_ip" {
  description = "Public IP address of the application server (EC2 instance)."
  value       = aws_instance.app.public_ip
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
