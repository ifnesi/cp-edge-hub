# =============================================================================
# VPC — shared by Edge and Hub EKS clusters (different clusters, same network
# so that cross-cluster NLB traffic stays within AWS rather than going to the
# internet; keep costs down for a PoC).
# =============================================================================

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.resource_prefix}-vpc" }
}

# --- Internet Gateway (needed for NLBs and node egress) ---

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.resource_prefix}-igw" }
}

# --- Public subnet (NLBs) ---

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name                            = "${var.resource_prefix}-public-${var.availability_zone}"
    "kubernetes.io/role/elb"        = "1"
    "kubernetes.io/cluster/cp-edge" = "shared"
    "kubernetes.io/cluster/cp-hub"  = "shared"
  }
}

# --- Private subnet (EKS nodes) ---

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone

  tags = {
    Name                              = "${var.resource_prefix}-private-${var.availability_zone}"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/cp-edge"   = "shared"
    "kubernetes.io/cluster/cp-hub"    = "shared"
  }
}

# --- Secondary private subnet (AZ b) ---
# EKS requires cluster subnets to span >=2 AZs. No node group references this
# subnet, so no pods/EBS land here — the workload stays in the primary AZ.

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_b_cidr
  availability_zone = var.availability_zone_b

  tags = {
    Name                              = "${var.resource_prefix}-private-${var.availability_zone_b}"
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/cp-edge"   = "shared"
    "kubernetes.io/cluster/cp-hub"    = "shared"
  }
}

# --- NAT Gateway (allows private-subnet nodes to pull images / call AWS APIs) ---

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.resource_prefix}-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "${var.resource_prefix}-nat" }
  depends_on    = [aws_internet_gateway.igw]
}

# --- Route tables ---

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.resource_prefix}-public-rt" }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.resource_prefix}-private-rt" }

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "private_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.private.id
}
