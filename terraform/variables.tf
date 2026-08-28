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
