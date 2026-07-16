# Example variable values. Copy to `terraform.tfvars` (which is gitignored) and
# fill in real values, or supply them via -var / TF_VAR_* environment variables.
#
#   cp example.tfvars terraform.tfvars   # then edit
#
# The DB password has NO default and MUST be supplied. Prefer an environment
# variable so it never touches disk:
#
#   export TF_VAR_db_password='choose-a-strong-password-min-12-chars'

aws_region   = "us-east-1"
project_name = "aws-secure-infra"
environment  = "dev"

# Lock SSH down to YOUR admin IP as a /32 — do not use 0.0.0.0/0.
ssh_allowed_cidr = "203.0.113.7/32"

# Database
db_name     = "appdb"
db_username = "dbadmin"
# db_password = "..."   # DO NOT commit a real password here; use TF_VAR_db_password.
