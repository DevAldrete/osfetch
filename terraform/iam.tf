# ============================================================
# iam.tf — IAM roles and instance profiles
#
# Every EC2 instance gets:
#   1. AmazonSSMManagedInstanceCore — enables Session Manager so you can
#      open a shell without SSH keys or open port 22 (useful when the lab
#      restricts Elastic IPs / key pairs).
#   2. CloudWatchAgentServerPolicy — optional; lets the CloudWatch agent
#      ship logs / metrics without extra credentials.
#
# Lambda (when enabled) gets:
#   1. Basic execution (CloudWatch Logs)
#   2. VPC access (ENI create/delete for VPC-attached Lambda)
# ============================================================

# ════════════════════════════════════════════════════════════
# EC2 Instance Role (shared by server, middleware, client)
# ════════════════════════════════════════════════════════════

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
  description        = "Shared role for osfetch EC2 instances (SSM + CW)"

  tags = {
    Name = "${local.name_prefix}-ec2-role"
  }
}

# AWS SSM Session Manager — no-SSH shell access
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch Logs — forward systemd journal via CloudWatch agent
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = {
    Name = "${local.name_prefix}-ec2-profile"
  }
}

# ════════════════════════════════════════════════════════════
# Lambda Execution Role (used only when enable_lambda_middleware = true)
# ════════════════════════════════════════════════════════════

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  count = var.enable_lambda_middleware ? 1 : 0

  name               = "${local.name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  description        = "Execution role for osfetch Lambda middleware"

  tags = {
    Name = "${local.name_prefix}-lambda-role"
  }
}

# Basic Lambda execution (CloudWatch Logs)
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  count = var.enable_lambda_middleware ? 1 : 0

  role       = aws_iam_role.lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# VPC access (create/describe/delete ENIs)
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  count = var.enable_lambda_middleware ? 1 : 0

  role       = aws_iam_role.lambda[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}
