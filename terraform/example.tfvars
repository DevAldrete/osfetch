# example.tfvars — copy to terraform.tfvars and fill in your values
# Run: terraform apply -var-file=terraform.tfvars

# ── Required ──────────────────────────────────────────────────
# Name of an existing EC2 Key Pair in your AWS account/region.
# Leave blank ("") to use SSM Session Manager only (no SSH).
key_name = "my-lab-key"

# ── Common overrides ──────────────────────────────────────────
aws_region   = "us-east-1"
environment  = "dev"

# Restrict SSH to your IP instead of the world
admin_cidr = "0.0.0.0/0"   # change to e.g. "203.0.113.42/32"

# Number of monitored server EC2s
server_count = 3

# ── Optional: Lambda middleware ───────────────────────────────
# Set to true if you want to also test the API GW WebSocket approach.
# Requires Lambda + API Gateway to be available in the lab account.
enable_lambda_middleware = false
