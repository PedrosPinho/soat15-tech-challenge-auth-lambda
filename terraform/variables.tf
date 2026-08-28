variable "aws_region" {
  description = "Região AWS (fixa, restrição do Learner Lab)"
  type        = string
  default     = "us-east-1"
}

variable "lab_role_arn" {
  description = "ARN da LabRole pré-criada pelo AWS Academy Learner Lab (role de execução das Lambdas)"
  type        = string
  default     = "arn:aws:iam::442534931336:role/LabRole"
}

variable "project_name" {
  description = "Prefixo usado no nome dos recursos"
  type        = string
  default     = "soat15-tc"
}

variable "jwt_expires_in" {
  description = "Expiração do JWT emitido para clientes autenticados por CPF"
  type        = string
  default     = "15m"
}

variable "db_username" {
  description = "Usuário master do RDS PostgreSQL (a senha vem do SSM, ver ssm.tf). O db-infra não expõe o username como output; valor precisa bater com o default de `db_username` em soat15-tech-challenge-db-infra/variables.tf (\"oficina\")."
  type        = string
  default     = "oficina"
}

variable "lambda_reserved_concurrency" {
  description = "Concorrência reservada das Lambdas de autenticação, para não esgotar as conexões do RDS (pool de tamanho 1 por execução)"
  type        = number
  default     = 5
}

variable "authorizer_cache_ttl_seconds" {
  description = "TTL do cache de autorização do API Gateway para o Lambda Authorizer (RFC-003: um cliente desativado pode continuar autorizado pela borda até este TTL expirar)"
  type        = number
  default     = 300
}

variable "throttling_burst_limit" {
  description = "Throttling (burst) do API Gateway -- segunda linha de defesa, além do express-rate-limit da aplicação"
  type        = number
  default     = 10
}

variable "throttling_rate_limit" {
  description = "Throttling (rate, req/s) do API Gateway"
  type        = number
  default     = 5
}

variable "eks_service_tag_value" {
  description = <<-EOT
    Valor da tag `kubernetes.io/service-name` usada para localizar dinamicamente
    (via `data "aws_lb"`) o Network Load Balancer interno criado pelo AWS Load
    Balancer Controller a partir do Service Kubernetes da aplicacao principal.

    Formato aplicado automaticamente pelo controller: "<namespace>/<nome-do-service>".
    Confirmar o valor exato (namespace e nome do Service definidos em
    k8s-infra/repositorio da aplicacao) antes da fase 2 do apply -- ver README.
  EOT
  type        = string
  default     = "oficina/oficina-api"
}

variable "eks_nlb_listener_port" {
  description = "Porta do listener do NLB interno do EKS usado como alvo do VPC Link (fase 2 do apply)"
  type        = number
  default     = 80
}

variable "enable_vpc_link_integration" {
  description = <<-EOT
    Controla se a rota `ANY /api/{proxy+}` é integrada ao VPC Link/NLB do EKS.

    Fica `false` até a aplicação principal já estar rodando no cluster com o Service
    LoadBalancer ativo (o NLB só existe depois disso -- ver a seção "Apply em duas
    fases" do README). Definir como `true` e rodar `terraform apply` novamente é a
    fase 2 do apply deste repositório.
  EOT
  type        = bool
  default     = false
}
