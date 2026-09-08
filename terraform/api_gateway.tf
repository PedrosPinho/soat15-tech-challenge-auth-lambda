# API Gateway (HTTP API) -- rota pública de emissão de token e rota protegida que
# encaminha para a aplicação no EKS.
#
# *** IMPORTANTE: apply em duas fases -- leia antes de rodar `terraform apply` ***
#
# Existe uma dependência circular de ordem entre este repositório e a aplicação:
#   - O VPC Link precisa apontar para o Network Load Balancer (NLB) interno que expõe
#     a API do EKS.
#   - Esse NLB só é criado pelo AWS Load Balancer Controller quando o `Service`
#     Kubernetes tipo LoadBalancer (definido no repositório da aplicação, `k8s/`) é
#     aplicado -- o que só acontece DEPOIS que os 3 repositórios de infra (db-infra,
#     k8s-infra, este) já estiverem de pé.
#
# Ou seja: não dá para criar o VPC Link/integração de `/api/*` na mesma vez em que se
# cria o restante deste Terraform, porque o NLB alvo ainda não existe.
#
# Resolvido com `var.enable_vpc_link_integration` (default `false`) + `data "aws_lb"`
# filtrando pelo NLB por tag, em vez de tentar referenciar um recurso Terraform de
# outro repositório que ainda não existe:
#
#   FASE 1 (`enable_vpc_link_integration = false`, valor padrão):
#     `terraform apply` cria a API Gateway, as duas Lambdas e a rota pública
#     `POST /auth/token`. Já é suficiente para emitir tokens e testar a autenticação
#     isoladamente. A rota `ANY /api/{proxy+}` e o VPC Link NÃO são criados nesta fase
#     (não haveria alvo válido).
#
#   >> Entre as fases: aplicar `db-infra`, `k8s-infra` e então fazer o deploy da
#      aplicação no cluster (`kubectl apply` dos manifestos `k8s/` do repositório
#      principal, incluindo o `Service` LoadBalancer). Só depois disso o NLB existe.
#
#   FASE 2 (`terraform apply -var="enable_vpc_link_integration=true"`, ou ajustando o
#     default/terraform.tfvars): com o `Service` já ativo no cluster, `data "aws_lb"`
#     abaixo localiza o NLB pela tag que o AWS Load Balancer Controller aplica
#     automaticamente (`kubernetes.io/service-name`). Este segundo apply cria o VPC
#     Link, a integração `HTTP_PROXY` e a rota `ANY /api/{proxy+}` (protegida pelo
#     Lambda Authorizer).
#
# Esta é uma correção prática à ordem sugerida originalmente no PHASE_3_PLAN.md (que
# assumia a Lambda pronta antes do deploy da aplicação) -- registrar para revisão.

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
# FASE 2 -- rota protegida ANY /api/{proxy+} via VPC Link para o NLB do EKS.
# Só existe quando var.enable_vpc_link_integration = true. Ver nota no topo do
# arquivo.
# ---------------------------------------------------------------------------

resource "aws_security_group" "vpc_link" {
  name        = "${var.project_name}-vpc-link-sg"
  description = "Security group do VPC Link do API Gateway em direcao ao NLB interno do EKS"
  vpc_id      = data.terraform_remote_state.db_infra.outputs.vpc_id

  egress {
    description = "Trafego para o NLB interno do EKS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_name}-vpc-link-sg"
  }
}

# Localiza dinamicamente o NLB interno criado pelo AWS Load Balancer Controller a
# partir do Service Kubernetes tipo LoadBalancer da aplicacao (repositorio principal,
# k8s/service.yaml). A tag `kubernetes.io/service-name` e aplicada automaticamente
# pelo controller no formato "<namespace>/<nome-do-service>".
data "aws_lb" "eks_internal_nlb" {
  count = var.enable_vpc_link_integration ? 1 : 0

  tags = {
    "kubernetes.io/service-name" = var.eks_service_tag_value
  }
}

data "aws_lb_listener" "eks_internal_nlb" {
  count = var.enable_vpc_link_integration ? 1 : 0

  load_balancer_arn = data.aws_lb.eks_internal_nlb[0].arn
  port              = var.eks_nlb_listener_port
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
  integration_uri      = data.aws_lb_listener.eks_internal_nlb[0].arn
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
