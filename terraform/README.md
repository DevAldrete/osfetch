# osfetch — AWS Terraform Deployment

Provisions a complete osfetch monitoring stack on AWS using EC2 and VPC only (compatible with restricted lab environments).

## Architecture

```
internet
    │
    │  SSH / port 9000
    ▼
┌───────────────────────────────────────────────────────┐
│  VPC  10.10.0.0/16                                    │
│                                                       │
│  Public subnet  10.10.1.0/24                          │
│  ┌──────────────┐   ┌──────────────┐                  │
│  │  middleware  │   │   client     │                  │
│  │  EC2         │   │   EC2        │                  │
│  │  port 9000   │   │  (Docker TUI)│                  │
│  │  systemd     │   │              │                  │
│  └──────┬───────┘   └──────────────┘                  │
│         │ TCP :9001                                    │
│  ┌──────▼──────────────────────────────────────────┐  │
│  │  server1 EC2   server2 EC2   server3 EC2         │  │
│  │  systemd       systemd       systemd             │  │
│  │  (monitor_server.py via systemd)                 │  │
│  └─────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────┘
```

All instances use **Amazon Linux 2023**. Package installs happen via `user_data` at first boot with no external tooling required.

| Role | Count | Subnet | Exposes |
|------|-------|--------|---------|
| `server` | 3 (configurable) | public | port 9001 (SG: middleware only) |
| `middleware` | 1 | public | port 9000 (SG: 0.0.0.0/0) |
| `client` | 1 | public | port 22 (SSH bastion) |

## Prerequisites

- Terraform >= 1.6
- AWS credentials configured (`aws configure` or environment variables)
- An existing EC2 Key Pair in the target region (or leave `key_name = ""` to use SSM only)

## Quick Start

```bash
cd terraform/

# 1. Initialize providers
terraform init

# 2. Preview what will be created
terraform plan -var="key_name=my-lab-key"

# 3. Deploy (takes ~3-5 min for user_data to finish)
terraform apply -var="key_name=my-lab-key"

# 4. Get connection details
terraform output
```

## Connecting

After `terraform apply` completes, `terraform output` shows ready-to-use commands:

### SSH + Docker TUI (recommended)

```bash
# SSH into the client bastion
ssh -i my-lab-key.pem ec2-user@<client_public_ip>

# Once inside the bastion — view-only dashboard
osfetch-view

# Interactive dashboard (process start/stop)
osfetch-interactive
```

### SSM Session Manager (no key pair needed)

```bash
# Open shell on client bastion
aws ssm start-session --target <client_instance_id> --region us-east-1

# Then run the same helpers
osfetch-view
```

### Check service health on a server node

```bash
aws ssm start-session --target <server_instance_id> --region us-east-1
# Inside the session:
systemctl status osfetch-server
journalctl -u osfetch-server -f
```

### Check middleware health

```bash
aws ssm start-session --target <middleware_instance_id> --region us-east-1
systemctl status osfetch-middleware
journalctl -u osfetch-middleware -f
```

## Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `aws_region` | `us-east-1` | AWS region |
| `project` | `osfetch` | Resource name prefix |
| `environment` | `dev` | Environment label |
| `key_name` | _(required)_ | EC2 Key Pair name (set `""` for SSM-only) |
| `vpc_cidr` | `10.10.0.0/16` | VPC CIDR |
| `public_subnet_cidr` | `10.10.1.0/24` | Public subnet CIDR |
| `private_subnet_cidr` | `10.10.2.0/24` | Private subnet CIDR (reserved) |
| `availability_zone` | `us-east-1a` | Single AZ for the lab |
| `admin_cidr` | `0.0.0.0/0` | CIDR allowed to SSH — tighten to your IP |
| `server_count` | `3` | Number of monitoring server EC2s |
| `server_instance_type` | `t3.micro` | Server instance type |
| `middleware_instance_type` | `t3.micro` | Middleware instance type |
| `client_instance_type` | `t3.small` | Client instance type |
| `ami_id` | _(auto)_ | Override AMI (default: latest AL2023) |
| `middleware_port` | `9000` | Middleware TCP port |
| `server_port` | `9001` | Server TCP port |
| `enable_lambda_middleware` | `false` | Also deploy experimental Lambda middleware |

### Example: customize server count and restrict SSH

```hcl
# terraform.tfvars
aws_region    = "us-west-2"
key_name      = "my-lab-key"
admin_cidr    = "203.0.113.42/32"   # your laptop IP
server_count  = 5
```

## Optional: Lambda Middleware

When `enable_lambda_middleware = true`, Terraform also deploys:

- A Lambda function (`lambda/middleware_proxy.py`) attached to the VPC
- An API Gateway WebSocket API as the transport layer
- The WebSocket endpoint URL is printed as `lambda_middleware_endpoint`

The Lambda middleware is an alternative to the EC2 middleware — both can coexist. The EC2 middleware uses raw TCP (port 9000); the Lambda middleware uses WebSocket (`wss://`).

Note: The Lambda approach requires the client to speak WebSocket instead of raw TCP. The standard `monitor_client.py` connects via raw TCP and works with the EC2 middleware. A WebSocket-capable client adapter would be needed to use the Lambda endpoint.

## Cleanup

```bash
terraform destroy
```

This removes all resources including the VPC, subnets, security groups, EC2 instances, and (if enabled) Lambda/API GW resources.

## Bootstrap Log

Each instance writes its bootstrap log to `/var/log/osfetch-bootstrap.log` and to the system journal under the tag `osfetch-bootstrap`. Check this if a service fails to start:

```bash
# Via SSM
sudo cat /var/log/osfetch-bootstrap.log
sudo journalctl -t osfetch-bootstrap
```
