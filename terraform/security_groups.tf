# ============================================================
# security_groups.tf - SGs for middleware, server, and client
#
# Traffic matrix:
#   internet  ──9000──►  middleware SG
#   internet  ──22───►   middleware SG  (SSH management)
#   internet  ──22───►   client SG      (SSH management)
#   middleware SG ──9001──►  server SG
#   client SG     ──9000──►  middleware SG
#   server SG - NO inbound from internet
# ============================================================

# ── Middleware Security Group ─────────────────────────────────
resource "aws_security_group" "middleware" {
  name        = "${local.name_prefix}-middleware-sg"
  description = "Allow inbound on port ${var.middleware_port} from clients and SSH from admin"
  vpc_id      = aws_vpc.main.id

  # TCP 9000 - monitoring clients connect here
  ingress {
    description = "Middleware proxy port - clients"
    from_port   = var.middleware_port
    to_port     = var.middleware_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH - management access
  ingress {
    description = "SSH management"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # All outbound - middleware must reach server instances on 9001
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-middleware-sg"
    Role = "middleware"
  }
}

# ── Server Security Group ─────────────────────────────────────
# Servers accept connections ONLY from the middleware - never directly
# from the internet or the client.
resource "aws_security_group" "server" {
  name        = "${local.name_prefix}-server-sg"
  description = "Allow inbound on port ${var.server_port} from middleware only"
  vpc_id      = aws_vpc.main.id

  # TCP 9001 - middleware connects here to proxy metrics/commands
  ingress {
    description     = "Monitoring server port - from middleware"
    from_port       = var.server_port
    to_port         = var.server_port
    protocol        = "tcp"
    security_groups = [aws_security_group.middleware.id]
  }

  # SSH - management access (useful for debugging in the lab)
  ingress {
    description = "SSH management"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # All outbound - needed for package installs during user_data bootstrap
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-server-sg"
    Role = "server"
  }
}

# ── Client Security Group ─────────────────────────────────────
# The client EC2 is a bastion/jump box that hosts the Docker-based
# monitor_client.py TUI. No inbound service ports needed.
resource "aws_security_group" "client" {
  name        = "${local.name_prefix}-client-sg"
  description = "Client bastion - SSH management only; outbound to middleware"
  vpc_id      = aws_vpc.main.id

  # SSH - operator attaches here to run the Docker client
  ingress {
    description = "SSH management"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # Streamlit Web UI - operator connects here
  ingress {
    description = "Streamlit Web UI"
    from_port   = 8501
    to_port     = 8501
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  # All outbound - client must reach middleware on 9000
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-client-sg"
    Role = "client"
  }
}

# ── Lambda Security Group (used only when enable_lambda_middleware = true) ─
resource "aws_security_group" "lambda" {
  count = var.enable_lambda_middleware ? 1 : 0

  name        = "${local.name_prefix}-lambda-sg"
  description = "Lambda middleware - outbound to server EC2s on port ${var.server_port}"
  vpc_id      = aws_vpc.main.id

  # Lambda functions don't need inbound SG rules (API GW manages that)
  egress {
    description = "Reach monitoring servers"
    from_port   = var.server_port
    to_port     = var.server_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "HTTPS - Lambda service endpoints (ECR, SSM, CloudWatch Logs)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-lambda-sg"
    Role = "lambda-middleware"
  }
}
