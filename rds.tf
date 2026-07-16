# =============================================================================
# rds.tf — the secure database (the "data tier")
#
# A db.t3.micro PostgreSQL instance placed in the PRIVATE subnets, reachable
# only from the EC2 security group, and never exposed to the internet.
# =============================================================================

resource "aws_db_instance" "main" {
  identifier = "${local.name_prefix}-db"

  # --- Engine ----------------------------------------------------------------
  # PostgreSQL on port 5432. var.db_port is shared with the RDS security group
  # rule so the firewall and the engine can never disagree on the port.
  engine         = "postgres"
  engine_version = var.db_engine_version
  port           = var.db_port

  # --- Sizing (cost-effective dev baseline) ----------------------------------
  instance_class    = var.db_instance_class
  allocated_storage = 20
  storage_type      = "gp3"
  multi_az          = false # single-AZ to keep the dev baseline cheap

  # --- Credentials (all parameterized; password is sensitive) ----------------
  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  # --- Network placement & isolation -----------------------------------------
  # publicly_accessible = false + a private DB subnet group means the database
  # has no public endpoint and lives only in the isolated subnets. The security
  # group restricts inbound to the EC2 SG on the DB port. Three independent
  # controls (no public IP, private subnets, SG reference) all point the same
  # way — defense in depth.
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # --- Data protection -------------------------------------------------------
  storage_encrypted = true # encrypt data at rest

  # --- Lifecycle (dev-friendly) ----------------------------------------------
  # skip_final_snapshot = true and deletion protection off make `terraform
  # destroy` clean for a dev baseline. For production, flip both: set
  # skip_final_snapshot = false and deletion_protection = true.
  skip_final_snapshot = true
  deletion_protection = false

  # Suppress noisy diffs on the auto-selected latest minor version.
  apply_immediately = true

  tags = {
    Name = "${local.name_prefix}-db"
    Tier = "data"
  }
}
