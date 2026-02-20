# ============================================================
# outputs.tf — Post-apply values useful for connecting and debugging
# ============================================================

# ── VPC ───────────────────────────────────────────────────────
output "vpc_id" {
  description = "ID of the monitoring VPC."
  value       = aws_vpc.main.id
}

output "public_subnet_id" {
  description = "ID of the public subnet."
  value       = aws_subnet.public.id
}

output "private_subnet_id" {
  description = "ID of the private subnet."
  value       = aws_subnet.private.id
}

# ── Middleware ────────────────────────────────────────────────
output "middleware_public_ip" {
  description = "Public IP of the middleware EC2. Use this as MIDDLEWARE_HOST in the client."
  value       = aws_instance.middleware.public_ip
}

output "middleware_private_ip" {
  description = "Private IP of the middleware EC2 (used by server SERVER_LIST)."
  value       = aws_instance.middleware.private_ip
}

output "middleware_instance_id" {
  description = "Instance ID — useful for SSM Session Manager access."
  value       = aws_instance.middleware.id
}

# ── Server instances ──────────────────────────────────────────
output "server_instance_ids" {
  description = "Instance IDs of all monitoring server nodes."
  value       = aws_instance.server[*].id
}

output "server_public_ips" {
  description = "Public IPs of server nodes (for SSH/debugging only; SG blocks metric traffic from internet)."
  value       = aws_instance.server[*].public_ip
}

output "server_private_ips" {
  description = "Private IPs of server nodes — what the middleware connects to."
  value       = aws_instance.server[*].private_ip
}

output "server_list_env" {
  description = "Rendered SERVER_LIST environment variable value injected into the middleware."
  value = join(",", [
    for i, inst in aws_instance.server :
    "server${i + 1}:${inst.private_ip}:${var.server_port}"
  ])
}

# ── Client ────────────────────────────────────────────────────
output "client_public_ip" {
  description = "Public IP of the client bastion. SSH here to run the TUI."
  value       = aws_instance.client.public_ip
}

output "client_instance_id" {
  description = "Instance ID — useful for SSM Session Manager access."
  value       = aws_instance.client.id
}

# ── Ready-to-use connection commands ─────────────────────────
output "ssh_middleware" {
  description = "SSH command to connect to the middleware instance."
  value       = "ssh -i <your-key>.pem ec2-user@${aws_instance.middleware.public_ip}"
}

output "ssh_client" {
  description = "SSH command to connect to the client bastion."
  value       = "ssh -i <your-key>.pem ec2-user@${aws_instance.client.public_ip}"
}

output "run_dashboard_view" {
  description = "Command to launch the view-only TUI after SSH-ing into the client EC2."
  value       = "osfetch-view"
}

output "run_dashboard_interactive" {
  description = "Command to launch the interactive TUI after SSH-ing into the client EC2."
  value       = "osfetch-interactive"
}

output "docker_run_direct" {
  description = "Full docker run command (run from the client EC2 after SSH)."
  value       = "docker run --rm -it -e MIDDLEWARE_HOST=${aws_instance.middleware.private_ip} -e MIDDLEWARE_PORT=${var.middleware_port} osfetch-client:latest"
}

# ── SSM Session Manager commands (no SSH key needed) ─────────
output "ssm_middleware" {
  description = "AWS CLI command to open a shell on the middleware via SSM."
  value       = "aws ssm start-session --target ${aws_instance.middleware.id} --region ${var.aws_region}"
}

output "ssm_client" {
  description = "AWS CLI command to open a shell on the client bastion via SSM."
  value       = "aws ssm start-session --target ${aws_instance.client.id} --region ${var.aws_region}"
}

output "ssm_servers" {
  description = "AWS CLI commands to open shells on each server node via SSM."
  value = {
    for i, inst in aws_instance.server :
    "server${i + 1}" => "aws ssm start-session --target ${inst.id} --region ${var.aws_region}"
  }
}

# ── Lambda outputs (conditional) ─────────────────────────────
output "lambda_middleware_endpoint" {
  description = "API Gateway WebSocket endpoint for the Lambda middleware (wss://... URL). Empty when disabled."
  value       = var.enable_lambda_middleware ? "${aws_apigatewayv2_api.middleware[0].api_endpoint}/${var.environment}" : "disabled (set enable_lambda_middleware = true to deploy)"
}
