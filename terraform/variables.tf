# ============================================================
# variables.tf — Input variables for the osfetch AWS deployment
# ============================================================

# ── AWS Region ───────────────────────────────────────────────
variable "aws_region" {
  description = "AWS region to deploy all resources into."
  type        = string
  default     = "us-east-1"
}

# ── Project / naming ─────────────────────────────────────────
variable "project" {
  description = "Short project identifier used as a prefix on every resource name and tag."
  type        = string
  default     = "osfetch"
}

variable "environment" {
  description = "Deployment environment label (dev | staging | prod)."
  type        = string
  default     = "dev"
}

# ── Key pair ─────────────────────────────────────────────────
variable "key_name" {
  description = "Name of an existing EC2 Key Pair to associate with all instances. Required for SSH access."
  type        = string
  # No default — must be supplied (or left empty to skip SSH key association).
}

# ── Network ──────────────────────────────────────────────────
variable "vpc_cidr" {
  description = "CIDR block for the monitoring VPC."
  type        = string
  default     = "10.10.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for the public subnet (middleware + client live here)."
  type        = string
  default     = "10.10.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for the private subnet (monitor servers live here)."
  type        = string
  default     = "10.10.2.0/24"
}

variable "availability_zone" {
  description = "AZ to place both subnets in. Single-AZ keeps the lab cost minimal."
  type        = string
  default     = "us-east-1a"
}

# ── Allowed management CIDR ──────────────────────────────────
variable "admin_cidr" {
  description = "CIDR allowed to SSH into the middleware and client instances (e.g. your laptop's /32)."
  type        = string
  default     = "0.0.0.0/0" # tighten in production
}

# ── Instance types ───────────────────────────────────────────
variable "server_instance_type" {
  description = "EC2 instance type for monitoring server nodes."
  type        = string
  default     = "t3.micro"
}

variable "middleware_instance_type" {
  description = "EC2 instance type for the middleware proxy node."
  type        = string
  default     = "t3.micro"
}

variable "client_instance_type" {
  description = "EC2 instance type for the client/bastion node."
  type        = string
  default     = "t3.small" # slightly larger — Docker + rich TUI
}

# ── AMI ──────────────────────────────────────────────────────
variable "ami_id" {
  description = <<-EOT
    AMI to use for all instances. Defaults to an empty string which triggers
    a data-source lookup for the latest Amazon Linux 2023 x86_64 AMI in the
    selected region. Override to pin a specific AMI.
  EOT
  type        = string
  default     = "" # empty → auto-discover via data source
}

# ── Server count ─────────────────────────────────────────────
variable "server_count" {
  description = "Number of monitoring server EC2 instances to create."
  type        = number
  default     = 3
}

# ── Ports ────────────────────────────────────────────────────
variable "middleware_port" {
  description = "TCP port the middleware proxy listens on."
  type        = number
  default     = 9000
}

variable "server_port" {
  description = "TCP port each monitoring server listens on."
  type        = number
  default     = 9001
}

# ── Lambda middleware toggle ──────────────────────────────────
variable "enable_lambda_middleware" {
  description = <<-EOT
    When true, deploys the experimental Lambda-based middleware alternative in
    addition to the EC2 middleware. The Lambda variant uses API Gateway WebSocket
    to work around Lambda's stateless execution model. Both can coexist.
  EOT
  type        = bool
  default     = false
}
