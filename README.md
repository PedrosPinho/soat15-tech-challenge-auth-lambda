# soat15-tech-challenge-auth-lambda

Autenticação serverless por CPF da Fase 3 do Tech Challenge (SOAT): duas Lambdas
Node.js/TypeScript (emissão de token e authorizer) e o API Gateway (HTTP API) que as
expõe, provisionados por Terraform em `terraform/`.

## Escopo deste repositório

- `POST /auth/token`: recebe `{ cpf }`, valida os dígitos verificadores, consulta o
  cliente no RDS (via `db-infra`) e emite um JWT (`scope: cliente`)
- Lambda Authorizer (`REQUEST`, cache 300s): valida o JWT nas rotas `/api/*`,
  repassadas via VPC Link para o NLB interno do EKS (`k8s-infra`)
- API Gateway HTTP API: rotas públicas (`/auth/token`, `/health`, `/api/docs`) e
  protegidas (`/api/*`)

Justificativa completa da estratégia (por que Lambda + JWT em vez de Cognito, por que
duas linhas de defesa) em
[`RFC-003`](https://github.com/PedrosPinho/soat15-tech-challenge-01/blob/main/docs/architecture/rfcs/RFC-003-autenticacao.md)
no repositório da aplicação, com o diagrama de sequência completo em
[`sequence-auth.md`](https://github.com/PedrosPinho/soat15-tech-challenge-01/blob/main/docs/architecture/sequence-auth.md).

## Dependências

- [`db-infra`](https://github.com/PedrosPinho/soat15-tech-challenge-db-infra) — endpoint
  e credenciais do RDS
- [`k8s-infra`](https://github.com/PedrosPinho/soat15-tech-challenge-k8s-infra) — NLB
  interno para o VPC Link

Aplicar **depois** dos dois.

## Estrutura

```
terraform/     # API Gateway, Lambdas, IAM (LabRole), VPC Link
src/
  token/       # handler POST /auth/token
  authorizer/  # handler do Lambda Authorizer
  shared/      # validação de CPF, cliente SSM/RDS
```

## Uso

```bash
npm install
npm run build   # empacota com esbuild
cd terraform && terraform init && terraform plan -out=tfplan && terraform apply tfplan
```

## Ciclo de sessão do Learner Lab

Role de execução é a `LabRole` compartilhada (sem IRSA/role dedicada — IAM bloqueado
no Learner Lab). `terraform apply` no início da sessão, `terraform destroy` ao final —
ver
[`PHASE_3_EXECUTION_GUIDE.md`](https://github.com/PedrosPinho/soat15-tech-challenge-01/blob/main/docs/PHASE_3_EXECUTION_GUIDE.md)
no repositório da aplicação.
