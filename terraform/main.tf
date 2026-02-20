# ============================================================
# main.tf — Provider, VPC, networking for the osfetch lab
# ============================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ── AMI lookup (skipped when var.ami_id is explicitly set) ───
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

locals {
  name_prefix = "${var.project}-${var.environment}"
  ami         = var.ami_id != "" ? var.ami_id : data.aws_ami.amazon_linux_2023.id

  common_tags = {
    Project     = var.project
    Environment = var.environment
  }
}

# ════════════════════════════════════════════════════════════
# VPC
# ════════════════════════════════════════════════════════════

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${local.name_prefix}-vpc"
  }
}

# ── Internet Gateway (public subnet → internet) ──────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${local.name_prefix}-igw"
  }
}

# ════════════════════════════════════════════════════════════
# Subnets
#
#  public  — middleware EC2 + client EC2
#            Has a public IP; reachable from the internet (SSH, port 9000)
#
#  private — monitoring server EC2s
#            No public IP; only reachable from inside the VPC
# ════════════════════════════════════════════════════════════

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true

  tags = {
    Name = "${local.name_prefix}-public-subnet"
    Tier = "public"
  }
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-subnet"
    Tier = "private"
  }
}

# ════════════════════════════════════════════════════════════
# Route Tables
# ════════════════════════════════════════════════════════════

# Public RT: default route → IGW
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
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private RT: local only (no NAT gateway — lab keeps costs at zero)
# Server nodes can still reach the internet for package installs if you add
# a NAT GW later; for the lab the user_data uses the public package mirrors
# that are accessible once the instance is in the private subnet and you
# assign a public IP during bootstrap, OR you do the install from user_data
# via the instance's direct internet access during launch (see ec2.tf note).
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  # No default route — servers are isolated from the internet after boot
  tags = {
    Name = "${local.name_prefix}-private-rt"
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# ── IMPORTANT: Private instances need internet during user_data boot ─────────
# Because we have no NAT Gateway (lab cost constraint), we temporarily allow
# the private subnet to use the IGW during the initial bootstrap by setting
# map_public_ip_on_launch = true on the private subnet in a second pass, or
# by placing servers in the public subnet during the lab.
#
# Simpler lab approach chosen: server instances are placed in the PUBLIC subnet
# but their security group blocks all inbound traffic except from the middleware
# security group. They get a public IP only for the user_data yum install calls;
# after boot the SG keeps them effectively private.
#
# To use a true private subnet + NAT GW, set enable_nat_gateway = true (future
# variable) and uncomment the NAT resources below.

# ── Optional NAT Gateway (commented out — add if lab grants Elastic IP) ──────
#
# resource "aws_eip" "nat" {
#   domain = "vpc"
#   tags   = { Name = "${local.name_prefix}-nat-eip" }
# }
#
# resource "aws_nat_gateway" "main" {
#   allocation_id = aws_eip.nat.id
#   subnet_id     = aws_subnet.public.id
#   tags          = { Name = "${local.name_prefix}-nat-gw" }
#   depends_on    = [aws_internet_gateway.main]
# }
#
# resource "aws_route" "private_nat" {
#   route_table_id         = aws_route_table.private.id
#   destination_cidr_block = "0.0.0.0/0"
#   nat_gateway_id         = aws_nat_gateway.main.id
# }
