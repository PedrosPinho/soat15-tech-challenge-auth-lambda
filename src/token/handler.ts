import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2 } from 'aws-lambda';
import jwt from 'jsonwebtoken';
import { validateCpf } from '../shared/cpf-validator';
import { findClienteByCpf } from '../shared/db';

/**
 * Handler `POST /auth/token` — emissão de JWT a partir do CPF do cliente.
 *
 * Fluxo e respostas seguem exatamente `docs/architecture/sequence-auth.md` do
 * repositório da aplicação principal:
 *   - 400: CPF com formato/dígitos verificadores inválidos
 *   - 404: CPF bem formado, mas nenhum cliente cadastrado
 *   - 403: cliente cadastrado, porém inativo
 *   - 200: { token }
 *
 * Importante (RFC-003): a mensagem pública de 404 e 403 é intencionalmente idêntica e
 * genérica — a diferença "não cadastrado" vs. "inativo" existe *apenas* no log
 * estruturado, nunca no corpo da resposta, para não permitir enumeração de CPFs
 * cadastrados a partir das respostas da API.
 */

interface TokenRequestBody {
  cpf?: unknown;
}

const GENERIC_AUTH_ERROR_MESSAGE = 'Cliente não encontrado ou não autorizado a autenticar.';

function jsonResponse(statusCode: number, body: Record<string, unknown>): APIGatewayProxyResultV2 {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  };
}

function logStructured(level: 'info' | 'warn' | 'error', message: string, meta: Record<string, unknown> = {}): void {
  // eslint-disable-next-line no-console
  console.log(
    JSON.stringify({
      level,
      message,
      handler: 'token',
      timestamp: new Date().toISOString(),
      ...meta,
    }),
  );
}

function parseBody(event: APIGatewayProxyEventV2): TokenRequestBody {
  if (!event.body) return {};
  const raw = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf-8') : event.body;
  try {
    return JSON.parse(raw) as TokenRequestBody;
  } catch {
    return {};
  }
}

export async function handler(event: APIGatewayProxyEventV2): Promise<APIGatewayProxyResultV2> {
  const correlationId = event.headers?.['x-correlation-id'] ?? event.requestContext.requestId;

  const body = parseBody(event);
  const rawCpf = typeof body.cpf === 'string' ? body.cpf : '';

  const { valid, digits } = validateCpf(rawCpf);
  if (!valid || !digits) {
    logStructured('warn', 'CPF com formato inválido', { correlationId });
    return jsonResponse(400, { message: 'CPF inválido' });
  }

  let cliente;
  try {
    cliente = await findClienteByCpf(digits);
  } catch (error) {
    logStructured('error', 'Falha ao consultar cliente no RDS', {
      correlationId,
      error: error instanceof Error ? error.message : String(error),
    });
    return jsonResponse(500, { message: 'Erro interno ao processar autenticação' });
  }

  if (!cliente) {
    logStructured('warn', 'Tentativa de login: cliente não cadastrado', { correlationId, cpf: digits });
    return jsonResponse(404, { message: GENERIC_AUTH_ERROR_MESSAGE });
  }

  if (!cliente.ativo) {
    logStructured('warn', 'Tentativa de login: cliente inativo', {
      correlationId,
      cpf: digits,
      clienteId: cliente.id,
    });
    return jsonResponse(403, { message: GENERIC_AUTH_ERROR_MESSAGE });
  }

  const jwtSecret = process.env.JWT_SECRET;
  if (!jwtSecret) {
    logStructured('error', 'JWT_SECRET não configurado no ambiente da Lambda', { correlationId });
    return jsonResponse(500, { message: 'Erro interno ao processar autenticação' });
  }

  const expiresIn = process.env.JWT_EXPIRES_IN ?? '15m';

  const token = jwt.sign(
    {
      sub: cliente.id,
      cpf: digits,
      scope: 'cliente',
    },
    jwtSecret,
    { expiresIn } as jwt.SignOptions,
  );

  logStructured('info', 'Token emitido com sucesso', { correlationId, clienteId: cliente.id });

  return jsonResponse(200, { token });
}
