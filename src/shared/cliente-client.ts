/**
 * Cliente HTTP do OS Service (dono do cadastro de clientes). A Lambda NÃO acessa mais o
 * banco: lê `GET /internal/clientes/by-cpf/:cpf` no ALB interno (ADR-015), autenticada por
 * `x-internal-token`. A rota `/internal/*` não é publicada no API Gateway.
 *
 * Config (injetada pelo Terraform): `INTERNAL_BASE_URL` (ex.: `http://<dns-do-alb>`) e
 * `INTERNAL_API_TOKEN` (o mesmo valor dos serviços).
 */

export interface ClienteRow {
  id: string;
  nome: string;
  ativo: boolean;
}

export interface ClienteClientOptions {
  baseUrl?: string;
  token?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

/**
 * Devolve o cliente, ou `null` se o OS responder 404. Qualquer outra falha (timeout,
 * rede, 401/5xx) lança — o handler responde 500, nunca 404/403, para não confundir
 * indisponibilidade com "CPF inexistente".
 */
export async function findClienteByCpf(
  cpf: string,
  options: ClienteClientOptions = {},
): Promise<ClienteRow | null> {
  const baseUrl = options.baseUrl ?? process.env.INTERNAL_BASE_URL;
  const token = options.token ?? process.env.INTERNAL_API_TOKEN;
  if (!baseUrl) throw new Error('INTERNAL_BASE_URL não configurada no ambiente da Lambda');
  if (!token) throw new Error('INTERNAL_API_TOKEN não configurado no ambiente da Lambda');

  const fetchImpl = options.fetchImpl ?? fetch;
  const response = await fetchImpl(
    `${baseUrl.replace(/\/$/, '')}/internal/clientes/by-cpf/${encodeURIComponent(cpf)}`,
    {
      headers: { 'x-internal-token': token },
      signal: AbortSignal.timeout(options.timeoutMs ?? 5000),
    },
  );

  if (response.status === 404) return null;
  if (!response.ok) {
    throw new Error(`OS Service respondeu ${response.status} ao buscar cliente por CPF`);
  }
  const body = (await response.json()) as Partial<ClienteRow>;
  if (typeof body.id !== 'string' || typeof body.ativo !== 'boolean') {
    throw new Error('Resposta do OS Service sem id/ativo');
  }
  return { id: body.id, nome: body.nome ?? '', ativo: body.ativo };
}
