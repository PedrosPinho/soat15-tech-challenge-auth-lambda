output "api_gateway_endpoint" {
  description = "Endpoint invocavel do API Gateway (stage $default)"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "token_function_name" {
  description = "Nome da Lambda que emite o JWT a partir do CPF"
  value       = aws_lambda_function.token.function_name
}

output "authorizer_function_arn" {
  description = "ARN da Lambda Authorizer usada pelas rotas /api/*"
  value       = aws_lambda_function.authorizer.arn
}

output "jwt_secret_param_name" {
  description = "Nome do parametro SSM (SecureString) com o JWT_SECRET compartilhado entre as Lambdas e a aplicacao principal"
  value       = aws_ssm_parameter.jwt_secret.name
}

output "vpc_link_enabled" {
  description = "Indica se a fase 2 do apply (VPC Link + rota /api/{proxy+}) esta ativa neste state"
  value       = var.enable_vpc_link_integration
}
