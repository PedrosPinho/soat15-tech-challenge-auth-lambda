# soat15-tech-challenge-auth-lambda

Autenticação serverless por CPF da Fase 3 do Tech Challenge (SOAT): duas Lambdas
Node.js/TypeScript (emissão de token e authorizer) e o API Gateway (HTTP API) que as
expõe, provisionados por Terraform em `terraform/`.

## Escopo deste repositório

- `POST /auth/token`: recebe `{ cpf }`, valida os dígitos verificadores, consulta o
  cliente no RDS (via `db-infra`) e emite um JWT (`scope: cliente`)
- Lambda Authorizer (`REQUEST`, cache 300s): valida o JWT nas rotas `/api/*`
  (aceita tanto `scope: cliente` quanto `scope: interno`), repassadas via VPC Link
  para o NLB interno do EKS (`k8s-infra`)
- API Gateway HTTP API: rotas públicas `POST /auth/token`, `POST
  /api/auth/login` (proxy do login interno da aplicação) e `GET
  /health/ready` (fora do prefixo `/api/`, usada pelo Synthetics monitor de
  uptime do New Relic — ver `k8s-infra`), e rota protegida `ANY /api/{proxy+}`

## Status

Aplicado e validado de ponta a ponta contra a AWS real (`homolog`), endpoint
público: `https://8vp6dbqs8g.execute-api.us-east-1.amazonaws.com`

```bash
# Cliente por CPF
curl -X POST "$ENDPOINT/auth/token" -H "Content-Type: application/json" -d '{"cpf":"52998224725"}'
# Login interno
curl -X POST "$ENDPOINT/api/auth/login" -H "Content-Type: application/json" -d '{"email":"admin@oficina.com","senha":"senha123"}'
# Healthcheck
curl "$ENDPOINT/health/ready"
```

Justificativa completa da estratégia (por que Lambda + JWT em vez de Cognito, por que
duas linhas de defesa) em
[`RFC-003`](https://github.com/PedrosPinho/soat15-tech-challenge-01/blob/main/docs/architecture/rfcs/RFC-003-autenticacao.md)
no repositório da aplicação, com o diagrama de sequência completo em
[`sequence-auth.md`](https://github.com/PedrosPinho/soat15-tech-challenge-01/blob/main/docs/architecture/sequence-auth.md).

## Dependências

- [`db-infra`](https://github.com/PedrosPinho/soat15-tech-challenge-db-infra) —
  VPC, endpoint/porta/nome do RDS, senha do RDS (SSM), security group já pronto para
  a Lambda (`lambda_auth_security_group_id`, com o SG do RDS já liberando ingress
  5432 para ele)
- [`k8s-infra`](https://github.com/PedrosPinho/soat15-tech-challenge-k8s-infra) — NLB
  interno para o VPC Link (só necessário na fase 2 do apply, ver abaixo)

Aplicar (fase 1) **depois** de `db-infra`. A fase 2 (VPC Link) só depois que a
aplicação principal já estiver rodando no EKS — ver a seção seguinte.

---

## ⚠️ Apply em duas fases (leia antes de rodar `terraform apply`)

Existe uma dependência circular de ordem entre este repositório e a aplicação
principal:

- O VPC Link do API Gateway precisa apontar para o **Network Load Balancer (NLB)
  interno** que expõe a API do EKS.
- Esse NLB só é criado pelo **AWS Load Balancer Controller** quando o `Service`
  Kubernetes tipo `LoadBalancer` (definido no repositório da aplicação, `k8s/`) é
  aplicado — e isso só acontece **depois** que os 3 repositórios de infraestrutura
  (`db-infra`, `k8s-infra`, este) já estiverem de pé.

Ou seja: **não é possível criar o VPC Link e a integração de `/api/*` no mesmo
`apply` que cria o resto deste Terraform**, porque o NLB alvo ainda não existe nesse
momento. Isso é uma correção prática à ordem sugerida originalmente no
`PHASE_3_PLAN.md` do repositório principal (que assumia a Lambda pronta antes do
deploy da aplicação) — destacada aqui para revisão.

A solução adotada (`terraform/api_gateway.tf`) usa a flag
`var.enable_vpc_link_integration` e um `data "aws_lb"` que localiza o NLB
**dinamicamente**, pela tag `service.k8s.aws/stack` que o AWS Load Balancer
Controller v3.x aplica automaticamente (formato `<namespace>/<nome-do-service>`)
— em vez de tentar referenciar um recurso Terraform de outro repositório que
ainda não existe.

**Fase 1** — `terraform apply` com `enable_vpc_link_integration = false`: cria
a API Gateway, as duas Lambdas, a rota pública `POST /auth/token` e a rota
pública `POST /api/auth/login` (proxy direto para o login interno da
aplicação — precisa ser pública, é como se emite o primeiro token `interno`).
Já é suficiente para emitir e validar tokens isoladamente (testes de fumaça,
Postman etc). A rota `ANY /api/{proxy+}` e o VPC Link **não são criados**
nesta fase.

**Entre as fases**: aplicar `db-infra`, `k8s-infra`, e então fazer o deploy da
aplicação no cluster (`kubectl apply` dos manifestos `k8s/` do repositório principal,
incluindo o `Service` LoadBalancer). Só depois disso o NLB existe e pode ser
localizado pela tag.

**Fase 2** — com o `Service` já ativo no cluster:

```bash
terraform apply -var="enable_vpc_link_integration=true"
```

Isso cria o VPC Link, a integração `HTTP_PROXY` e a rota `ANY /api/{proxy+}`
(protegida pelo Lambda Authorizer). O pipeline (`ci-cd.yml`) já calcula
`TF_VAR_eks_service_tag_value` (`oficina-${ENV}/oficina-api`) a partir do
workspace/branch — o default de `var.eks_service_tag_value` no `variables.tf`
é só um fallback para apply manual. Confira também `var.eks_nlb_listener_port`
(default `3001`, batendo com `k8s/service.yaml` do repositório principal).

**Nesta execução real (`homolog`)**, `enable_vpc_link_integration` já está
`true` por padrão em `variables.tf` — a fase 2 está ativa e validada em
produção (ver "Status" abaixo).

---

## Segredos: SSM lido em tempo de `apply`, não em runtime pela Lambda

Decisão registrada no `PHASE_3_PLAN.md` (Etapa 2.1): sem NAT Gateway na VPC, uma
Lambda em subnet privada não alcança o SSM Parameter Store em runtime a menos que
exista um VPC Endpoint de Interface (que tem custo por hora e mais uma peça
operacional para manter).

Em vez disso, este repositório usa `data "aws_ssm_parameter"` (`terraform/ssm.tf`)
para ler a senha do RDS (criada pelo `db-infra`) **apenas no momento do
`terraform apply`**, e injeta o valor já resolvido como variável de ambiente da
Lambda (`DATABASE_URL` completa, montada em `lambdas.tf`). A Lambda em si nunca
precisa alcançar o SSM em runtime — mais simples e sem custo adicional de VPC
Endpoint, ao custo de precisar de um novo `apply` sempre que a senha do RDS rotacionar
(aceitável neste projeto, dado o ciclo destroy/apply por sessão do Learner Lab).

## `JWT_SECRET` compartilhado entre este repositório e a aplicação principal

O mesmo `JWT_SECRET` é usado em três lugares:

1. **Lambda `token`** (aqui) — assina o JWT na emissão.
2. **Lambda `authorizer`** (aqui) — valida a assinatura na borda.
3. **Aplicação principal no EKS** — valida a assinatura de novo, localmente, no
   `authMiddleware` (**defesa em profundidade**, RFC-003: o Service do EKS nunca deve
   confiar cegamente na borda).

Este repositório é quem **gera** o segredo: `terraform/ssm.tf` cria um
`random_password` uma única vez e grava em `aws_ssm_parameter.jwt_secret`
(`SecureString`, nome exposto no output `jwt_secret_param_name`). A aplicação
principal deve ler **o mesmo parâmetro SSM** (não gerar o seu próprio) — isso fica
documentado também no `README`/Terraform da aplicação principal como uma dependência
cross-repositório explícita. Se o valor divergir entre os dois lados, a validação
local da aplicação rejeita tokens legítimos emitidos pela Lambda.

## Usuário do RDS

`var.db_username` (default `"oficina"`) precisa bater com o `db_username` real
provisionado pelo `db-infra` (`soat15-tech-challenge-db-infra/variables.tf`, também
default `"oficina"`) — o `db-infra` não expõe o username como output porque é uma
convenção fixa entre os dois repositórios, não um segredo.

## Security group da Lambda

O security group das Lambdas **não é criado neste repositório**. O `db-infra` já cria
um SG placeholder dedicado (`aws_security_group.lambda_auth`, em
`db-infra/security_groups.tf`) e o SG do RDS já libera ingress na porta 5432 para ele
desde a criação — porque `db-infra` é aplicado primeiro, e só essa ordem evita uma
dependência circular (se o SG vivesse aqui, o SG do RDS teria que ser atualizado
depois que este repositório existisse). Este repositório só anexa as funções Lambda a
esse SG via `data.terraform_remote_state.db_infra.outputs.lambda_auth_security_group_id`.

## Respostas de erro de autenticação

`POST /auth/token` nunca diferencia "CPF não cadastrado" (`404`) de "cliente
inativo" (`403`) na **mensagem** de erro pública (ambas retornam o mesmo texto
genérico) — só no log estruturado (JSON, com `correlationId`), para não permitir
enumeração de CPFs cadastrados a partir das respostas da API. Ver `RFC-003` e
`sequence-auth.md` no repositório principal.

## Estrutura

```
terraform/
  backend.tf, provider.tf, versions.tf, variables.tf, remote_state.tf  # bootstrap
  lambdas.tf       # Lambdas (token + authorizer), role LabRole, VPC config
  api_gateway.tf   # HTTP API, rotas, authorizer, VPC Link (fase 2), throttling
  ssm.tf           # segredos (senha do RDS via data source, JWT_SECRET gerado)
  outputs.tf
src/
  token/handler.ts       # handler POST /auth/token
  authorizer/handler.ts  # handler do Lambda Authorizer (REQUEST)
  shared/
    cpf-validator.ts     # validação de dígitos verificadores (portado de cpf-cnpj.vo.ts)
    db.ts                 # client pg (pool de tamanho 1)
tests/            # Jest -- validação de CPF e decisão do authorizer
```

## Uso

```bash
npm install
npm run build     # empacota cada handler com esbuild (dist/token, dist/authorizer)
npm run package   # build + zip (dist/token.zip, dist/authorizer.zip -- consumidos pelo Terraform)
npm test          # Jest

cd terraform
terraform init
terraform apply              # fase 1 -- ver secao acima
# ... aplicar db-infra, k8s-infra, deploy da aplicacao no cluster ...
terraform apply -var="enable_vpc_link_integration=true"   # fase 2
```

Sem credenciais AWS neste ambiente de desenvolvimento: validação local usa
`terraform init -backend=false` + `terraform validate` + `terraform fmt` (sem
`plan`/`apply`).

## CI/CD

Pipeline em `.github/workflows/ci-cd.yml`: `test` (type-check + unitários) →
`build` (esbuild, artefato `lambda-dist`) → `terraform-fmt-validate` → `plan`
(em PR, comentado no PR) → `apply` (push em `homolog`/`main`) + teste de
fumaça (invoca a Lambda de token com um CPF de fixture, aceita
`200`/`400`/`403`/`404` — não exige seed de dados). O job `apply` reempacota
as Lambdas (`npm ci && npm run package`) porque cada job do GitHub Actions
roda num runner isolado — artefato de outro job não fica disponível de graça.

**Secrets do GitHub**: `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/
`AWS_SESSION_TOKEN` — credenciais temporárias do Learner Lab, renovadas por
`scripts/refresh-aws-secrets.sh` (repositório da aplicação) nos 4
repositórios de uma vez.

## Ciclo de sessão do Learner Lab

Role de execução é a `LabRole` compartilhada (sem IRSA/role dedicada — IAM bloqueado
no Learner Lab). `terraform apply` no início da sessão, `terraform destroy` ao final —
ver
[`PHASE_3_EXECUTION_GUIDE.md`](https://github.com/PedrosPinho/soat15-tech-challenge-01/blob/main/docs/PHASE_3_EXECUTION_GUIDE.md)
no repositório da aplicação.
