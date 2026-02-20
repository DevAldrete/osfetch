# ============================================================
# ec2.tf — EC2 instances for server nodes, middleware, and client
#
# Role summary:
#   server    × N  — monitor_server.py runs as a systemd service
#                    Python 3.11 + psutil installed via yum/pip
#                    Placed in the public subnet (lab: no NAT GW)
#                    SG blocks all inbound except port 9001 from middleware
#
#   middleware × 1 — proxy.py runs as a systemd service
#                    Pure Python stdlib; only Python 3.11 needed
#                    Placed in the public subnet; exposes port 9000
#
#   client     × 1 — monitor_client.py runs inside Docker
#                    Docker + docker-compose installed on boot
#                    Placed in the public subnet; SSH bastion for operator
# ============================================================

# ════════════════════════════════════════════════════════════
# Locals — build the SERVER_LIST string for the middleware
# ════════════════════════════════════════════════════════════

locals {
  # Each server uses its private IP so middleware → server traffic stays
  # inside the VPC and never exits to the internet.
  # We build the list after creation using aws_instance private_ip outputs
  # but we need a computed value, so we use a join over the count index.
  # The actual IPs are injected via a null_resource / user_data replacement
  # after the server instances are known. For simplicity in the lab we pass
  # the list as a rendered template once all instances are created.
  server_names = [for i in range(var.server_count) : "server${i + 1}"]
}

# ════════════════════════════════════════════════════════════
# MONITORING SERVER EC2 INSTANCES
# ════════════════════════════════════════════════════════════

resource "aws_instance" "server" {
  count = var.server_count

  ami                    = local.ami
  instance_type          = var.server_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.server.id]
  key_name               = var.key_name != "" ? var.key_name : null
  iam_instance_profile   = data.aws_iam_instance_profile.lab_profile.name

  # Root volume — 30 GB gp3 is enough for AL2023 + Python packages
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    encrypted             = true
  }

  # ── user_data bootstrap ──────────────────────────────────
  # Runs once on first boot as root.
  # Steps:
  #   1. System update + install Python 3.11 and pip
  #   2. Install psutil (only third-party dep for the server)
  #   3. Write monitor_server.py to /opt/osfetch/
  #   4. Write /etc/systemd/system/osfetch-server.service
  #   5. Enable + start the service
  user_data_base64 = base64gzip(templatefile("${path.module}/templates/server_userdata.sh.tpl", {
    server_name = "server${count.index + 1}"
    server_port = var.server_port
    project     = var.project
    environment = var.environment
  }))

  # Ensure the VPC + SG are ready first
  depends_on = [
    aws_internet_gateway.main,
    aws_security_group.server,
  ]

  tags = {
    Name        = "${local.name_prefix}-server-${count.index + 1}"
    Role        = "server"
    ServerIndex = tostring(count.index + 1)
  }
}

# ════════════════════════════════════════════════════════════
# MIDDLEWARE EC2 INSTANCE
# ════════════════════════════════════════════════════════════

resource "aws_instance" "middleware" {
  ami                    = local.ami
  instance_type          = var.middleware_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.middleware.id]
  key_name               = var.key_name != "" ? var.key_name : null
  iam_instance_profile   = data.aws_iam_instance_profile.lab_profile.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    delete_on_termination = true
    encrypted             = true
  }

  # SERVER_LIST is built from the private IPs of the server instances.
  # Format: "server1:10.10.1.x:9001,server2:10.10.1.y:9001,..."
  user_data_base64 = base64gzip(templatefile("${path.module}/templates/middleware_userdata.sh.tpl", {
    middleware_port = var.middleware_port
    server_port     = var.server_port
    server_list = join(",", [
      for i, inst in aws_instance.server :
      "server${i + 1}:${inst.private_ip}:${var.server_port}"
    ])
    project     = var.project
    environment = var.environment
  }))

  # Must wait for server instances so their private IPs are known
  depends_on = [
    aws_instance.server,
    aws_internet_gateway.main,
    aws_security_group.middleware,
  ]

  tags = {
    Name = "${local.name_prefix}-middleware"
    Role = "middleware"
  }
}

# ════════════════════════════════════════════════════════════
# CLIENT EC2 INSTANCE (Docker-based TUI bastion)
# ════════════════════════════════════════════════════════════

resource "aws_instance" "client" {
  ami                    = local.ami
  instance_type          = var.client_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.client.id]
  key_name               = var.key_name != "" ? var.key_name : null
  iam_instance_profile   = data.aws_iam_instance_profile.lab_profile.name

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30 # slightly larger for Docker image layer cache
    delete_on_termination = true
    encrypted             = true
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/client_userdata.sh.tpl", {
    middleware_host = aws_instance.middleware.private_ip
    middleware_port = var.middleware_port
    project         = var.project
    environment     = var.environment
  }))

  depends_on = [
    aws_instance.middleware,
    aws_internet_gateway.main,
    aws_security_group.client,
  ]

  tags = {
    Name = "${local.name_prefix}-client"
    Role = "client"
  }
}
