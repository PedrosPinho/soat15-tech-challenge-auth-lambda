# Lambdas de autenticação por CPF: emissão de token e authorizer.
#
# Role de execução: `LabRole` (var.lab_role_arn) — IAM está bloqueado no Learner Lab,
# não é possível criar uma role de execução dedicada por Lambda. Ver ADR-006 no
# repositório da aplicação principal.
#
# Rede: as duas Lambdas ficam nas subnets privadas exportadas pelo `db-infra` (mesma
# VPC). A de token alcança o ALB interno (OS Service) pela rede da VPC; ela NÃO acessa
# mais o RDS. Sem NAT Gateway na VPC — por isso os segredos (JWT_SECRET) são lidos do SSM Parameter Store apenas no momento do
# `terraform apply` (`data "aws_ssm_parameter"` em `ssm.tf`) e injetados como
# variáveis de ambiente da Lambda, em vez de a Lambda precisar alcançar o SSM em
# runtime através de um VPC Endpoint de Interface. Ver README para a justificativa
# completa dessa escolha.

# Security group das Lambdas: NÃO é criado neste repositório. O `db-infra` já cria um
# SG placeholder dedicado (`aws_security_group.lambda_auth`, ver
# db-infra/security_groups.tf) e o SG do RDS já libera ingress na porta 5432 para ele
# desde a criação — porque db-infra é aplicado antes deste repositório, e só ele
# resolve sem dependência circular (se o SG vivesse aqui, o SG do RDS teria que ser
# atualizado depois que este repositório existisse). Este repositório só anexa a
# função Lambda a esse SG via `lambda_auth_security_group_id` do remote state.
locals {
  lambda_security_group_id = data.terraform_remote_state.db_infra.outputs.lambda_auth_security_group_id

  # Sem ALB (enable_vpc_link_integration = false) não há URL interna: a Lambda de token
  # sobe sem ela e responde 500 até a fase 2 do apply (o ALB só existe depois do deploy
  # dos serviços).
  internal_base_url = var.enable_vpc_link_integration ? "http://${data.aws_lb.eks_internal_alb[0].dns_name}" : ""

  token_lambda_env = {
    INTERNAL_BASE_URL  = local.internal_base_url
    INTERNAL_API_TOKEN = var.internal_api_token
    JWT_SECRET         = aws_ssm_parameter.jwt_secret.value
    JWT_EXPIRES_IN     = var.jwt_expires_in
  }
}

resource "aws_cloudwatch_log_group" "token" {
  name              = "/aws/lambda/${var.project_name}-auth-token"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "authorizer" {
  name              = "/aws/lambda/${var.project_name}-authorizer"
  retention_in_days = 14
}

resource "aws_lambda_function" "token" {
  function_name = "${var.project_name}-auth-token"
  description   = "Emite JWT a partir do CPF do cliente (POST /auth/token), consultando o OS Service via ALB interno"

  filename         = "${path.module}/../dist/token.zip"
  source_code_hash = fileexists("${path.module}/../dist/token.zip") ? filebase64sha256("${path.module}/../dist/token.zip") : null

  handler = "index.handler"
  runtime = "nodejs20.x"
  role    = var.lab_role_arn

  timeout                        = 10
  memory_size                    = 256
  reserved_concurrent_executions = var.lambda_reserved_concurrency

  vpc_config {
    subnet_ids         = data.terraform_remote_state.db_infra.outputs.private_subnet_ids
    security_group_ids = [local.lambda_security_group_id]
  }

  environment {
    variables = local.token_lambda_env
  }

  depends_on = [aws_cloudwatch_log_group.token]
}

resource "aws_lambda_function" "authorizer" {
  function_name = "${var.project_name}-authorizer"
  description   = "Lambda Authorizer (REQUEST) das rotas /api/* -- valida JWT (scope cliente ou interno)"

  filename         = "${path.module}/../dist/authorizer.zip"
  source_code_hash = fileexists("${path.module}/../dist/authorizer.zip") ? filebase64sha256("${path.module}/../dist/authorizer.zip") : null

  handler = "index.handler"
  runtime = "nodejs20.x"
  role    = var.lab_role_arn

  timeout                        = 10
  memory_size                    = 256
  reserved_concurrent_executions = var.lambda_reserved_concurrency

  # O authorizer não consulta o RDS (só valida assinatura/expiração do JWT), mas fica
  # na mesma VPC/SG por simplicidade operacional -- não precisa de acesso à internet
  # de qualquer forma, já que jsonwebtoken.verify é 100% local.
  vpc_config {
    subnet_ids         = data.terraform_remote_state.db_infra.outputs.private_subnet_ids
    security_group_ids = [local.lambda_security_group_id]
  }

  environment {
    variables = {
      JWT_SECRET = aws_ssm_parameter.jwt_secret.value
    }
  }

  depends_on = [aws_cloudwatch_log_group.authorizer]
}
