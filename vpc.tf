# =============================================================================
# vpc.tf — isolated networking baseline (the "network tier")
#
# Topology:
#
#   VPC 10.0.0.0/16
#   ├── Public  subnet AZ-a  10.0.0.0/24  ─┐
#   ├── Public  subnet AZ-b  10.0.1.0/24  ─┤─▶ Route Table ─▶ Internet Gateway
#   ├── Private subnet AZ-a  10.0.10.0/24 ─┐
#   └── Private subnet AZ-b  10.0.11.0/24 ─┴─▶ (no internet route — isolated)
#
#   Public subnets host the EC2 app server (internet-facing).
#   Private subnets host RDS (no route to the internet gateway).
# =============================================================================

# Discover which AZs are usable in the selected region. Using a data source
# (instead of hardcoding "us-east-1a") keeps the config portable across regions.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # A consistent prefix for resource names, e.g. "aws-secure-infra-dev".
  name_prefix = "${var.project_name}-${var.environment}"

  # Take the first two available AZs in the region.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Deterministic /24 CIDRs carved out of the VPC block.
  public_subnet_cidrs  = ["10.0.0.0/24", "10.0.1.0/24"]
  private_subnet_cidrs = ["10.0.10.0/24", "10.0.11.0/24"]
}

# -----------------------------------------------------------------------------
# VPC
#
# DNS support + hostnames are required for RDS endpoints to resolve and for
# EC2 instances to receive internal DNS names.
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# -----------------------------------------------------------------------------
# Public subnets (one per AZ)
#
# `map_public_ip_on_launch = true` so instances launched here get a public IP
# automatically. These subnets are "public" purely because their route table
# has a 0.0.0.0/0 route to the Internet Gateway (defined below).
# -----------------------------------------------------------------------------
resource "aws_subnet" "public" {
  count = length(local.public_subnet_cidrs)

  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-${local.azs[count.index]}"
    Tier = "public"
  }
}

# -----------------------------------------------------------------------------
# Private subnets (one per AZ)
#
# No public IPs, no internet route. RDS lives here so it is unreachable from
# the internet by network topology alone — defense in depth on top of the
# security group rules.
# -----------------------------------------------------------------------------
resource "aws_subnet" "private" {
  count = length(local.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "${local.name_prefix}-private-${local.azs[count.index]}"
    Tier = "private"
  }
}

# -----------------------------------------------------------------------------
# Internet Gateway — the VPC's door to the internet, used only by public subnets.
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# -----------------------------------------------------------------------------
# Public route table + association
#
# The 0.0.0.0/0 → IGW route is what makes the public subnets public. Private
# subnets are deliberately NOT associated with this table, so they keep only
# the implicit local route and remain isolated.
# -----------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${local.name_prefix}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# DB Subnet Group
#
# RDS requires a subnet group spanning at least two AZs. We point it at the
# PRIVATE subnets so the database can only ever be placed in the isolated tier.
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${local.name_prefix}-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${local.name_prefix}-db-subnet-group"
  }
}
