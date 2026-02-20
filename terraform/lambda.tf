# ============================================================
# lambda.tf — Optional Lambda-based middleware using API Gateway WebSocket
#
# Enabled when: var.enable_lambda_middleware = true
#
# Architecture:
#   Client ──wss://──► API GW WebSocket ──invoke──► Lambda ──TCP:9001──► server EC2s
#
# The Lambda function (lambda/middleware_proxy.py) is VPC-attached so it
# can reach the server EC2 private IPs directly over TCP.
#
# Note on the APIGW_ENDPOINT circular dependency:
#   Lambda needs to know the API GW Management URL to push messages back to
#   WebSocket clients.  The URL is:
#     https://<api_id>.execute-api.<region>.amazonaws.com/<stage>
#   The <api_id> is known as soon as aws_apigatewayv2_api is created —
#   before the stage exists — so we can inline the URL directly into the
#   Lambda environment block.  We use depends_on to guarantee ordering.
# ============================================================

# ── Package the Lambda function ───────────────────────────────
data "archive_file" "lambda_middleware" {
  count = var.enable_lambda_middleware ? 1 : 0

  type        = "zip"
  source_file = "${path.root}/../lambda/middleware_proxy.py"
  output_path = "${path.module}/lambda_middleware.zip"
}

# ── API Gateway WebSocket API ─────────────────────────────────
# Declared before Lambda so its ID is available when we build the
# APIGW_ENDPOINT environment variable below.
resource "aws_apigatewayv2_api" "middleware" {
  count = var.enable_lambda_middleware ? 1 : 0

  name                       = "${local.name_prefix}-middleware-ws"
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"

  tags = {
    Name = "${local.name_prefix}-middleware-ws"
    Role = "lambda-middleware"
  }
}

# ── Lambda function ───────────────────────────────────────────
resource "aws_lambda_function" "middleware" {
  count = var.enable_lambda_middleware ? 1 : 0

  function_name = "${local.name_prefix}-middleware-lambda"
  description   = "osfetch middleware proxy — WebSocket / API GW edition"
  role          = data.aws_iam_role.lab_role.arn
  handler       = "middleware_proxy.handler"
  runtime       = "python3.11"

  filename         = data.archive_file.lambda_middleware[0].output_path
  source_code_hash = data.archive_file.lambda_middleware[0].output_base64sha256

  # VPC attachment — Lambda must reach server EC2 private IPs on TCP 9001
  vpc_config {
    subnet_ids         = [aws_subnet.public.id]
    security_group_ids = [aws_security_group.lambda[0].id]
  }

  # Allow up to 15 min per invocation; Lambda holds the TCP socket open
  # while streaming metrics back to the WebSocket client.
  timeout     = 900
  memory_size = 256

  environment {
    variables = {
      # Static server registry — same format as middleware/proxy.py SERVER_LIST
      SERVER_LIST = join(",", [
        for i, inst in aws_instance.server :
        "server${i + 1}:${inst.private_ip}:${var.server_port}"
      ])

      # Management API URL — Lambda uses this to POST messages back to clients.
      # The API ID is known once aws_apigatewayv2_api is created; the stage
      # name is deterministic (var.environment).
      APIGW_ENDPOINT = "https://${aws_apigatewayv2_api.middleware[0].id}.execute-api.${var.aws_region}.amazonaws.com/${var.environment}"
    }
  }

  depends_on = [
    aws_instance.server,
    aws_apigatewayv2_api.middleware,
  ]

  tags = {
    Name = "${local.name_prefix}-middleware-lambda"
    Role = "lambda-middleware"
  }
}

# ── Lambda integration ────────────────────────────────────────
resource "aws_apigatewayv2_integration" "middleware" {
  count = var.enable_lambda_middleware ? 1 : 0

  api_id           = aws_apigatewayv2_api.middleware[0].id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.middleware[0].invoke_arn

  content_handling_strategy = "CONVERT_TO_TEXT"
  passthrough_behavior      = "WHEN_NO_MATCH"
}

# ── Routes ────────────────────────────────────────────────────

resource "aws_apigatewayv2_route" "connect" {
  count = var.enable_lambda_middleware ? 1 : 0

  api_id    = aws_apigatewayv2_api.middleware[0].id
  route_key = "$connect"
  target    = "integrations/${aws_apigatewayv2_integration.middleware[0].id}"
}

resource "aws_apigatewayv2_route" "disconnect" {
  count = var.enable_lambda_middleware ? 1 : 0

  api_id    = aws_apigatewayv2_api.middleware[0].id
  route_key = "$disconnect"
  target    = "integrations/${aws_apigatewayv2_integration.middleware[0].id}"
}

resource "aws_apigatewayv2_route" "default" {
  count = var.enable_lambda_middleware ? 1 : 0

  api_id    = aws_apigatewayv2_api.middleware[0].id
  route_key = "$default"
  target    = "integrations/${aws_apigatewayv2_integration.middleware[0].id}"
}

# ── Stage ─────────────────────────────────────────────────────
resource "aws_apigatewayv2_stage" "middleware" {
  count = var.enable_lambda_middleware ? 1 : 0

  api_id      = aws_apigatewayv2_api.middleware[0].id
  name        = var.environment
  auto_deploy = true

  default_route_settings {
    logging_level          = "INFO"
    data_trace_enabled     = false
    throttling_burst_limit = 100
    throttling_rate_limit  = 50
  }

  tags = {
    Name = "${local.name_prefix}-middleware-ws-stage"
    Role = "lambda-middleware"
  }
}

# ── Lambda permission — allow API GW to invoke the function ───
resource "aws_lambda_permission" "apigw" {
  count = var.enable_lambda_middleware ? 1 : 0

  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.middleware[0].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.middleware[0].execution_arn}/*/*"
}

# ── CloudWatch Log Group ──────────────────────────────────────
resource "aws_cloudwatch_log_group" "lambda_middleware" {
  count = var.enable_lambda_middleware ? 1 : 0

  name              = "/aws/lambda/${local.name_prefix}-middleware-lambda"
  retention_in_days = 7

  tags = {
    Name = "${local.name_prefix}-lambda-logs"
    Role = "lambda-middleware"
  }
}
