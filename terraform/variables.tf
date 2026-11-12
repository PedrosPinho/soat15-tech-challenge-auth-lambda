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

variable "internal_api_token" {
  description = "Token serviço-a-serviço (`x-internal-token`) do OS Service — o MESMO valor dos 3 serviços (GitHub Secret INTERNAL_API_TOKEN, exportado como TF_VAR_internal_api_token pelo CI)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "lambda_reserved_concurrency" {
  description = "Concorrência reservada das Lambdas de autenticação, para limitar a carga sobre o OS Service"
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

variable "eks_ingress_group" {
  description = <<-EOT
    Nome do IngressGroup (`alb.ingress.kubernetes.io/group.name`) dos 3 serviços:
    "oficina-homolog" / "oficina-prod". O AWS Load Balancer Controller funde os Ingress do
    grupo em UM ALB interno e o tageia com `ingress.k8s.aws/stack = <grupo>` (ADR-013);
    é por essa tag que o ALB é localizado. O pipeline exporta TF_VAR_eks_ingress_group a
    partir do workspace.
  EOT
  type        = string
  default     = "oficina-homolog"
}

variable "eks_alb_listener_port" {
  description = "Porta do listener do ALB interno (HTTP 80, ver annotation listen-ports nos Ingress dos serviços)"
  type        = number
  default     = 80
}

variable "enable_vpc_link_integration" {
  description = <<-EOT
    Controla se a rota `ANY /api/{proxy+}` é integrada ao VPC Link/ALB do EKS.

    Fica `false` até os serviços já estarem rodando no cluster com os Ingress ativos
    (o ALB só existe depois disso -- ver a seção "Apply em duas
    fases" do README). Definir como `true` e rodar `terraform apply` novamente é a
    fase 2 do apply deste repositório.
  EOT
  type        = bool
  default     = true
}
