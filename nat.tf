# =============================================================================
# nat.tf — outbound internet for the private tier (production topology only)
#
# Created only when var.enable_alb = true. When the EC2 instance moves to a
# private subnet, it loses its direct route to the Internet Gateway — but it
# still needs outbound access for OS patching and package installs. NAT
# gateways provide that: private subnets route 0.0.0.0/0 to a NAT gateway that
# lives in a PUBLIC subnet and forwards traffic out through the IGW.
#
# Inbound connections cannot be initiated through a NAT gateway, so this grants
# egress without exposing the private instances to the internet.
#
#   private subnet ─0.0.0.0/0─▶ NAT gateway (public subnet) ─▶ IGW ─▶ internet
#
# NAT count is controlled by var.single_nat_gateway:
#   true  -> 1 NAT gateway (cheaper, single point of failure)
#   false -> 1 NAT gateway per AZ (HA)
# =============================================================================

locals {
  # How many NAT gateways to build when the feature is enabled.
  nat_gateway_count = var.enable_alb ? (var.single_nat_gateway ? 1 : length(aws_subnet.public)) : 0
}

# Elastic IPs — one per NAT gateway. A NAT gateway needs a stable public IP.
resource "aws_eip" "nat" {
  count  = local.nat_gateway_count
  domain = "vpc"

  tags = {
    Name = "${local.name_prefix}-nat-eip-${count.index}"
  }

  # The IGW must exist before an EIP can be associated with a NAT gateway.
  depends_on = [aws_internet_gateway.main]
}

# NAT gateways, placed in the PUBLIC subnets (that is where the internet route
# lives). With single_nat_gateway = true, only public subnet [0] is used.
resource "aws_nat_gateway" "main" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = {
    Name = "${local.name_prefix}-nat-${count.index}"
  }

  depends_on = [aws_internet_gateway.main]
}

# Private route tables — one per private subnet — each routing 0.0.0.0/0 to a
# NAT gateway. With a single NAT gateway, every private subnet points at NAT[0];
# with per-AZ NATs, each private subnet points at the NAT in its own AZ.
resource "aws_route_table" "private" {
  count = var.enable_alb ? length(aws_subnet.private) : 0

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[var.single_nat_gateway ? 0 : count.index].id
  }

  tags = {
    Name = "${local.name_prefix}-private-rt-${count.index}"
  }
}

resource "aws_route_table_association" "private" {
  count = var.enable_alb ? length(aws_subnet.private) : 0

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}
