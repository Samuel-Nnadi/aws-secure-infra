# aws-secure-infra

> A foundational, secure **3-tier AWS infrastructure** built with modular Terraform — isolated networking, least-privilege security groups, a locked-down S3 bucket, a public web server, and a private database.

[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.3-7B42BC.svg)](https://www.terraform.io/)
[![AWS Provider](https://img.shields.io/badge/AWS%20Provider-~%3E5.0-FF9900.svg)](https://registry.terraform.io/providers/hashicorp/aws/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## Architecture

```
                              Internet
                                 │
                                 ▼
                        ┌──────────────────┐
                        │ Internet Gateway │
                        └────────┬─────────┘
                                 │ 0.0.0.0/0
                        ┌────────▼─────────┐
                        │  Public Route    │
                        │      Table       │
                        └───┬──────────┬───┘
              ┌─────────────┘          └─────────────┐
   ┌──────────▼──────────┐            ┌──────────────▼──────┐
   │ Public Subnet AZ-a  │            │ Public Subnet AZ-b  │
   │  ┌───────────────┐  │            │                     │
   │  │  EC2 (t3.micro│  │            │                     │
   │  │  AL2023)      │  │            │                     │
   │  │  [EC2 SG]     │  │            │                     │
   │  └───────┬───────┘  │            │                     │
   └──────────┼──────────┘            └─────────────────────┘
              │ 5432 (from EC2 SG only)
   ┌──────────▼──────────┐            ┌─────────────────────┐
   │ Private Subnet AZ-a │            │ Private Subnet AZ-b │
   │  ┌───────────────┐  │            │                     │
   │  │  RDS (Postgres│  │◀───────────┤  DB Subnet Group    │
   │  │  db.t3.micro) │  │  spans     │  spans both AZs     │
   │  │  [RDS SG]     │  │  both AZs  │                     │
   │  └───────────────┘  │            │                     │
   └─────────────────────┘            └─────────────────────┘
      (no internet route — isolated)

   S3: private, versioned, encrypted bucket with all public access blocked.
```

**Three tiers:**

| Tier      | Resource            | Placement       | Exposure                                    |
| --------- | ------------------- | --------------- | ------------------------------------------- |
| Web       | EC2 (t3.micro)      | Public subnet   | 80/443 from anywhere, 22 from admin IP only |
| Data      | RDS (PostgreSQL)    | Private subnets | 5432 from the EC2 SG only, no public access |
| Storage   | S3 bucket           | Global (private)| All public access blocked                   |

---

## File layout

| File                  | Responsibility                                                              |
| --------------------- | -------------------------------------------------------------------------- |
| `providers.tf`        | Terraform + AWS/random providers; region parameterized; default tags.       |
| `vpc.tf`              | VPC, 2 public + 2 private subnets, IGW, public route table, DB subnet group.|
| `security-groups.tf`  | EC2 SG (least-privilege) and RDS SG (references the EC2 SG).                |
| `s3.tf`               | Private bucket + public-access block + versioning + encryption.            |
| `ec2.tf`              | AL2023 t3.micro in a public subnet with a bootstrap `user_data` script.    |
| `rds.tf`              | Private db.t3.micro PostgreSQL instance.                                    |
| `variables.tf`        | All inputs (password marked `sensitive`).                                   |
| `outputs.tf`          | EC2 public IP, RDS endpoint, S3 bucket name, and more.                     |

---

## How the security relationships fit together

The three tiers are wired so trust flows in exactly one direction:

1. **The EC2 SG** allows `80`/`443` from the world and `22` only from
   `var.ssh_allowed_cidr` (your admin IP). All egress is open.
2. **The RDS SG** has a single ingress rule: the DB port, sourced from the
   **EC2 security group by reference** (`referenced_security_group_id`), not a
   CIDR. Only instances in the EC2 SG can reach the database.
3. **The private subnets** have no route to the Internet Gateway, so RDS is
   unreachable from the internet by topology — independent of the SG rules.
4. **`publicly_accessible = false`** on the RDS instance removes any public
   endpoint entirely.

That is three independent controls (SG reference, private subnets, no public
endpoint) all enforcing the same boundary — defense in depth.

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.3
- AWS credentials configured (`aws configure`, an SSO profile, or environment
  variables). The identity needs permissions to create VPC, EC2, RDS, and S3
  resources.

---

## Usage

```bash
# 1. Provide the DB password out-of-band (never commit it).
export TF_VAR_db_password='choose-a-strong-password-min-12-chars'

# 2. Lock SSH to your IP (edit example.tfvars → terraform.tfvars, or pass -var).
cp example.tfvars terraform.tfvars   # then set ssh_allowed_cidr to YOUR.IP/32

# 3. Deploy.
terraform init
terraform plan
terraform apply
```

After apply:

```bash
terraform output ec2_public_ip
terraform output rds_endpoint
terraform output s3_bucket_name
```

Tear down:

```bash
terraform destroy
```

### Key variables

| Variable            | Default            | Description                                        |
| ------------------- | ------------------ | -------------------------------------------------- |
| `aws_region`        | `us-east-1`        | Region to deploy into.                             |
| `environment`       | `dev`              | `dev` / `staging` / `prod` (drives naming + tags). |
| `ssh_allowed_cidr`  | `203.0.113.0/24`   | **Override this** with your admin IP `/32`.        |
| `db_password`       | *(none)*           | **Required**, `sensitive`, min 12 chars.           |
| `db_engine_version` | `16.4`             | PostgreSQL version.                                |
| `db_port`           | `5432`             | Set to `3306` for MySQL.                           |

---

## Security notes & deliberate trade-offs

This is a **cost-effective dev baseline**. The following are conscious choices,
flagged here so they are decisions, not oversights:

- **The EC2 instance has a public IP.** That is the intended web tier; a static
  analyzer (e.g. SonarLint S6329) will flag it. It is guarded by the
  least-privilege EC2 SG. For a hardened setup, front it with an ALB and move
  the instance to a private subnet with a NAT gateway.
- **`multi_az = false`** and **`skip_final_snapshot = true`** keep dev cheap and
  `destroy` clean. For production: enable Multi-AZ, set
  `skip_final_snapshot = false`, and turn on `deletion_protection`.
- **SSH is open to a CIDR.** Prefer AWS Systems Manager Session Manager (no open
  port 22 at all) for real environments.
- **RDS credentials** should graduate from a `TF_VAR_` password to AWS Secrets
  Manager with rotation.

Baseline protections already included: S3 public-access block + versioning +
SSE, EBS + RDS encryption at rest, and IMDSv2 required on the instance.

---

## License

[MIT](LICENSE)
