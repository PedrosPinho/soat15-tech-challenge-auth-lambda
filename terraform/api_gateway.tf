# API Gateway (HTTP API) -- rota pública de emissão de token e rota protegida que
# encaminha para os serviços no EKS (via ALB interno).
#
# *** IMPORTANTE: apply em duas fases -- leia antes de rodar `terraform apply` ***
#
# Existe uma dependência circular de ordem entre este repositório e os serviços:
#   - O VPC Link precisa apontar para o listener do Application Load Balancer (ALB)
#     interno que expõe os 3 serviços (OS, Billing, Execution) no EKS (Fase 4, ADR-013).
#   - Esse ALB só é criado pelo AWS Load Balancer Controller quando os Ingress do grupo
#     `oficina-<env>` (manifests `k8s/ingress.yaml` de cada serviço) são aplicados -- o
#     que só acontece DEPOIS que os repositórios de infra (db-infra, k8s-infra) e ao menos
#     um serviço já estiverem de pé.
#
# Resolvido com `var.enable_vpc_link_integration` + `data "aws_lb"` filtrando o ALB por
# tag (`ingress.k8s.aws/stack = <group.name>`), em vez de referenciar um recurso de outro
# repositório que ainda não existe:
#
#   FASE 1 (`enable_vpc_link_integration = false`): `terraform apply` cria a API Gateway,
#     as Lambdas e a rota pública `POST /auth/token` (a Lambda de token só consegue emitir
#     depois da fase 2, pois consulta o OS Service pelo ALB). Sem VPC Link nem rotas /api/*.
#
#   >> Entre as fases: aplicar `db-infra`, `k8s-infra` e fazer o deploy dos serviços.
#
#   FASE 2 (`enable_vpc_link_integration = true`, o default): cria o VPC Link, a integração
#     `HTTP_PROXY` para o listener do ALB e as rotas:
#       - `ANY /api/{proxy+}`                        protegida pelo Lambda Authorizer;
#       - `POST /api/auth/login`                     pública (primeiro token `interno`);
#       - `POST /api/pagamentos/webhooks/mercadopago` pública (assinatura HMAC no Billing);
#       - `GET /health/ready`                        pública (Synthetics do New Relic).
#     O roteamento por serviço (/api/ordens-servico -> OS, /api/orcamentos -> Billing,
#     /api/execucoes -> Execution...) é feito pelo Ingress/ALB, não por rotas do API Gateway.
#     `/internal/*` NÃO tem rota aqui: só é alcançável de dentro da VPC (Lambda de token).
#
# Correção prática à ordem do PHASE_3_PLAN.md -- registrada para revisão.

resource "aws_apigatewayv2_api" "http_api" {
  name          = "${var.project_name}-auth-api"
  protocol_type = "HTTP"
  description   = "API Gateway HTTP API: emissao de token por CPF + proxy autenticado para a aplicacao no EKS"
}

resource "aws_cloudwatch_log_group" "api_gateway_access_logs" {
  name              = "/aws/apigateway/${var.project_name}-auth-api"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit   = var.throttling_burst_limit
    throttling_rate_limit    = var.throttling_rate_limit
    detailed_metrics_enabled = true
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway_access_logs.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      ip               = "$context.identity.sourceIp"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      protocol         = "$context.protocol"
      responseLength   = "$context.responseLength"
      integrationError = "$context.integration.error"
    })
  }
}

# ---------------------------------------------------------------------------
# Rota pública: POST /auth/token (integração Lambda direta)
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_integration" "token" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.token.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 10000
}

resource "aws_apigatewayv2_route" "token" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /auth/token"
  target    = "integrations/${aws_apigatewayv2_integration.token.id}"
}

resource "aws_lambda_permission" "apigw_invoke_token" {
  statement_id  = "AllowAPIGatewayInvokeToken"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.token.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# Lambda Authorizer (REQUEST, payload 1.0 -- resposta em formato de politica IAM)
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_authorizer" "jwt" {
  api_id                            = aws_apigatewayv2_api.http_api.id
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
  authorizer_payload_format_version = "1.0"
  identity_sources                  = ["$request.header.Authorization"]
  authorizer_result_ttl_in_seconds  = var.authorizer_cache_ttl_seconds
  name                              = "${var.project_name}-jwt-authorizer"
}

resource "aws_lambda_permission" "apigw_invoke_authorizer" {
  statement_id  = "AllowAPIGatewayInvokeAuthorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/authorizers/${aws_apigatewayv2_authorizer.jwt.id}"
}

# ---------------------------------------------------------------------------
# FASE 2 -- rota protegida ANY /api/{proxy+} via VPC Link para o ALB do EKS.
# Só existe quando var.enable_vpc_link_integration = true. Ver nota no topo do
# arquivo.
# ---------------------------------------------------------------------------

resource "aws_security_group" "vpc_link" {
  name        = "${var.project_name}-vpc-link-sg"
  description = "Security group do VPC Link do API Gateway em direcao ao ALB interno do EKS"
  vpc_id      = data.terraform_remote_state.db_infra.outputs.vpc_id

  egress {
    description = "Trafego para o ALB interno do EKS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-vpc-link-sg"
  }
}

# Localiza o ALB interno único criado pelo AWS Load Balancer Controller a partir dos
# Ingress dos 3 serviços (mesmo `group.name`, ADR-013). O controller tageia o ALB do grupo
# com `ingress.k8s.aws/stack = <group.name>`.
data "aws_lb" "eks_internal_alb" {
  count = var.enable_vpc_link_integration ? 1 : 0

  tags = {
    "ingress.k8s.aws/stack" = var.eks_ingress_group
  }
}

data "aws_lb_listener" "eks_internal_alb" {
  count = var.enable_vpc_link_integration ? 1 : 0

  load_balancer_arn = data.aws_lb.eks_internal_alb[0].arn
  port              = var.eks_alb_listener_port
}

resource "aws_apigatewayv2_vpc_link" "eks" {
  count = var.enable_vpc_link_integration ? 1 : 0

  name               = "${var.project_name}-eks-vpc-link"
  subnet_ids         = data.terraform_remote_state.db_infra.outputs.private_subnet_ids
  security_group_ids = [aws_security_group.vpc_link.id]
}

resource "aws_apigatewayv2_integration" "eks_proxy" {
  count = var.enable_vpc_link_integration ? 1 : 0

  api_id               = aws_apigatewayv2_api.http_api.id
  integration_type     = "HTTP_PROXY"
  integration_method   = "ANY"
  integration_uri      = data.aws_lb_listener.eks_internal_alb[0].arn
  connection_type      = "VPC_LINK"
  connection_id        = aws_apigatewayv2_vpc_link.eks[0].id
  timeout_milliseconds = 29000
}

resource "aws_apigatewayv2_route" "api_proxy" {
  count = var.enable_vpc_link_integration ? 1 : 0

  api_id             = aws_apigatewayv2_api.http_api.id
  route_key          = "ANY /api/{proxy+}"
  target             = "integrations/${aws_apigatewayv2_integration.eks_proxy[0].id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.jwt.id
}

# Rota pública, sem autorizador -- login interno (e-mail/senha) da aplicacao
# principal (`POST /api/auth/login`, ja implementado la e coberto pelos testes
# daquele repositorio). Precisa ser publica pela natureza da coisa: e como um
# usuario interno consegue o primeiro token, antes de ter qualquer token.
# Rotas exatas tem prioridade sobre o catch-all `{proxy+}` acima, entao esta
# rota mais especifica intercepta so esse path (mesma integracao HTTP_PROXY,
# que encaminha o path original sem alteracao para o ALB).
resource "aws_apigatewayv2_route" "auth_login" {
  count = var.enable_vpc_link_integration ? 1 : 0

  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /api/auth/login"
  target    = "integrations/${aws_apigatewayv2_integration.eks_proxy[0].id}"
}

# Rota pública, sem autorizador -- expõe /health/ready fora do prefixo /api/
# (o catch-all acima só cobre /api/{proxy+}) para o Synthetics monitor de
# uptime do New Relic (ver newrelic_alerts.tf em k8s-infra) conseguir checar o
# healthcheck de fora da VPC, sem precisar de um JWT.
resource "aws_apigatewayv2_route" "health_ready" {
  count = var.enable_vpc_link_integration ? 1 : 0

  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "GET /health/ready"
  target    = "integrations/${aws_apigatewayv2_integration.eks_proxy[0].id}"
}

# Rota pública, sem autorizador -- webhook do Mercado Pago (Billing Service). O MP não
# envia JWT; a autenticidade é garantida pela validação da assinatura HMAC `x-signature`
# dentro do próprio Billing (ADR-014). Rota exata tem prioridade sobre o catch-all
# `ANY /api/{proxy+}`; o ALB roteia `/api/pagamentos` para o Billing Service pelo Ingress.
resource "aws_apigatewayv2_route" "mercadopago_webhook" {
  count = var.enable_vpc_link_integration ? 1 : 0

  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /api/pagamentos/webhooks/mercadopago"
  target    = "integrations/${aws_apigatewayv2_integration.eks_proxy[0].id}"
}
