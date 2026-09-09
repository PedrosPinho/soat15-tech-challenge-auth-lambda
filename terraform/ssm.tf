# Segredos consumidos pelas Lambdas.
#
# Estratégia escolhida (documentada no README): em vez de dar às Lambdas acesso em
# runtime ao SSM Parameter Store (o que exigiria um VPC Endpoint de Interface, já que
# não há NAT Gateway nas subnets privadas), os valores são lidos do SSM apenas no
# momento do `terraform apply` via `data "aws_ssm_parameter"` e injetados como
# variáveis de ambiente da Lambda (`lambdas.tf`). Isso evita o custo/operação extra do
# VPC Endpoint, ao custo de a Lambda precisar ser reimplantada (novo `apply`) sempre
# que o segredo rotacionar — aceitável neste projeto, dado o ciclo de
# destroy/apply por sessão do Learner Lab.

# Senha do RDS, criada pelo repositório `db-infra` (SecureString). O nome do parâmetro
# é exposto no remote state daquele repositório (`db_secret_param_name`).
data "aws_ssm_parameter" "db_password" {
  name            = data.terraform_remote_state.db_infra.outputs.db_secret_param_name
  with_decryption = true
}

# JWT_SECRET: o MESMO segredo é usado pela Lambda de emissão de token (para assinar),
# pelo Lambda Authorizer (para validar) e pela aplicação principal no EKS (para
# validar de novo, na "defesa em profundidade" descrita na RFC-003). Por isso ele vive
# aqui — no repositório da Lambda, que é quem o gera — e é lido pela aplicação
# principal a partir do mesmo parâmetro SSM (ver README, seção "JWT_SECRET
# compartilhado").
#
# Gerado uma única vez com `random_password`. O provider `random` só recalcula
# `result` se os argumentos de entrada (`length`, `special`, ...) mudarem ou se um
# `keepers` mudar — não a cada `apply` — então o valor permanece estável entre
# sessões do Learner Lab sem precisar de `lifecycle.ignore_changes`.
resource "random_password" "jwt_secret" {
  length  = 48
  special = true
}

resource "aws_ssm_parameter" "jwt_secret" {
  name        = "/${var.project_name}/${terraform.workspace}/jwt-secret"
  description = "JWT_SECRET compartilhado entre as Lambdas de autenticação e a aplicação principal (defesa em profundidade, RFC-003)"
  type        = "SecureString"
  value       = random_password.jwt_secret.result
}
