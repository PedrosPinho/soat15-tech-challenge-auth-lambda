import { Pool, PoolClient } from 'pg';

/**
 * Client PostgreSQL compartilhado entre invocações da Lambda no mesmo container
 * (reuso de execution context da AWS).
 *
 * Decisão registrada no PHASE_3_PLAN.md (Etapa 2.1): pool de tamanho 1 com
 * `idle_session_timeout` em vez de RDS Proxy — o volume de conexões concorrentes desta
 * Lambda não justifica o custo por hora do Proxy; risco de esgotamento de conexões em
 * rajada é aceito e documentado no README/ADR deste repositório.
 *
 * A connection string é lida de `DATABASE_URL`, injetada como variável de ambiente da
 * Lambda pelo Terraform (`lambdas.tf`) a partir do SSM Parameter Store no momento do
 * `terraform apply` — a Lambda em si nunca precisa alcançar o SSM em runtime (não há
 * NAT na subnet privada).
 */

let pool: Pool | undefined;

function buildPool(): Pool {
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    throw new Error('DATABASE_URL não configurada no ambiente da Lambda');
  }

  const newPool = new Pool({
    connectionString,
    max: 1,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 5_000,
    ssl: process.env.DATABASE_SSL === 'false' ? undefined : { rejectUnauthorized: false },
  });

  newPool.on('connect', (client: PoolClient) => {
    // Evita que a sessão fique presa/vazando no RDS caso a Lambda seja congelada e
    // retomada pela AWS sem encerrar a conexão de forma limpa.
    client.query('SET idle_session_timeout = 60000').catch(() => {
      // Best-effort: algumas versões/engines podem não suportar o parâmetro; não deve
      // impedir a Lambda de operar.
    });
  });

  return newPool;
}

/**
 * Retorna o pool de conexões, criando-o na primeira invocação do container.
 */
export function getPool(): Pool {
  if (!pool) {
    pool = buildPool();
  }
  return pool;
}

export interface ClienteRow {
  id: string;
  nome: string;
  ativo: boolean;
}

/**
 * Busca um cliente pelo CPF/CNPJ normalizado (somente dígitos).
 */
export async function findClienteByCpf(cpf: string): Promise<ClienteRow | null> {
  const client = getPool();
  const result = await client.query<ClienteRow>(
    'SELECT id, nome, ativo FROM clientes WHERE cpf_cnpj = $1 LIMIT 1',
    [cpf],
  );
  return result.rows[0] ?? null;
}
