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

  // Obrigatório com pg.Pool: o timer de idleTimeoutMillis do pool não roda enquanto o
  // container da Lambda está congelado, então o RDS derruba a conexão (idle_session_timeout
  // acima) antes do pool conseguir reciclá-la sozinho. Sem este listener, o erro do client
  // ocioso derruba o processo inteiro no próximo cold-restart do container (visto em
  // produção: "Invalid request ID" seguido de "Internal Server Error" na chamada seguinte).
  // O pg-pool já remove o client com erro da pool sozinho; só precisamos não deixar o
  // evento sem listener.
  newPool.on('error', (err) => {
    console.error('Erro em client ocioso do pool (conexão será recriada na próxima query)', err);
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
