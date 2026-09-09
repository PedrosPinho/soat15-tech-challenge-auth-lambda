import type {
  APIGatewayAuthorizerResult,
  APIGatewayRequestAuthorizerEvent,
  APIGatewayAuthorizerResultContext,
} from 'aws-lambda';
import jwt from 'jsonwebtoken';

/**
 * Lambda Authorizer (`REQUEST`) que protege as rotas `/api/*` do API Gateway.
 *
 * Aceita dois tipos de token, conforme RFC-003:
 *   - `scope: "cliente"`: emitido pela Lambda `POST /auth/token` deste repositório —
 *     cliente autenticado por CPF, só acessa os próprios dados.
 *   - `scope: "interno"`: emitido pelo fluxo já existente `POST /api/auth/login` da
 *     aplicação principal (usuário interno da oficina, e-mail/senha).
 *
 * Retorna uma política IAM `Allow`/`Deny` (formato compatível com REST API e com HTTP
 * API em modo de payload 1.0/IAM policy) e injeta no contexto os dados necessários
 * para a aplicação (`clienteId`/`cpf` para `scope: cliente`, `userId` para
 * `scope: interno`) — o API Gateway repassa esse contexto como headers ao backend.
 *
 * Cache de autorização (300s) é configurado no Terraform (`api_gateway.tf`), não aqui.
 *
 * Defesa em profundidade (RFC-003): mesmo com esta validação na borda, o
 * `authMiddleware` da aplicação principal valida a assinatura do JWT de novo,
 * localmente — este Authorizer não é o único guardião.
 */

interface ClienteTokenClaims {
  sub: string;
  cpf: string;
  scope: 'cliente';
}

interface InternoTokenClaims {
  sub: string;
  scope: 'interno';
}

type TokenClaims = ClienteTokenClaims | InternoTokenClaims;

function isClienteClaims(claims: jwt.JwtPayload | string): claims is ClienteTokenClaims {
  return typeof claims === 'object' && claims !== null && claims.scope === 'cliente';
}

function isInternoClaims(claims: jwt.JwtPayload | string): claims is InternoTokenClaims {
  return typeof claims === 'object' && claims !== null && claims.scope === 'interno';
}

function logStructured(level: 'info' | 'warn' | 'error', message: string, meta: Record<string, unknown> = {}): void {
  // eslint-disable-next-line no-console
  console.log(
    JSON.stringify({
      level,
      message,
      handler: 'authorizer',
      timestamp: new Date().toISOString(),
      ...meta,
    }),
  );
}

function extractToken(event: APIGatewayRequestAuthorizerEvent): string | null {
  const header = event.headers?.Authorization ?? event.headers?.authorization;
  if (!header) return null;
  const [scheme, token] = header.split(' ');
  if (scheme?.toLowerCase() !== 'bearer' || !token) return null;
  return token;
}

/**
 * Verifica a assinatura/expiração do token e devolve claims tipadas quando o token é
 * de um escopo reconhecido (`cliente` ou `interno`). Não lança — chamadores tratam
 * `null` como token inválido/expirado/escopo desconhecido.
 */
export function decodeAndValidateToken(token: string, secret: string): TokenClaims | null {
  let claims: jwt.JwtPayload | string;
  try {
    claims = jwt.verify(token, secret);
  } catch {
    return null;
  }

  if (isClienteClaims(claims)) {
    return { sub: claims.sub as unknown as string, cpf: claims.cpf, scope: 'cliente' };
  }
  if (isInternoClaims(claims)) {
    return { sub: claims.sub as unknown as string, scope: 'interno' };
  }
  return null;
}

function buildPolicy(
  principalId: string,
  effect: 'Allow' | 'Deny',
  resource: string,
  context?: APIGatewayAuthorizerResultContext,
): APIGatewayAuthorizerResult {
  return {
    principalId,
    policyDocument: {
      Version: '2012-10-17',
      Statement: [
        {
          Action: 'execute-api:Invoke',
          Effect: effect,
          Resource: resource,
        },
      ],
    },
    context,
  };
}

export async function handler(event: APIGatewayRequestAuthorizerEvent): Promise<APIGatewayAuthorizerResult> {
  const correlationId = event.headers?.['x-correlation-id'] ?? event.requestContext?.requestId;
  const resource = event.methodArn;

  const token = extractToken(event);
  if (!token) {
    logStructured('warn', 'Requisição sem Authorization Bearer token', { correlationId });
    return buildPolicy('anonymous', 'Deny', resource);
  }

  const jwtSecret = process.env.JWT_SECRET;
  if (!jwtSecret) {
    logStructured('error', 'JWT_SECRET não configurado no ambiente do Authorizer', { correlationId });
    return buildPolicy('anonymous', 'Deny', resource);
  }

  const claims = decodeAndValidateToken(token, jwtSecret);
  if (!claims) {
    logStructured('warn', 'Token inválido, expirado ou com escopo desconhecido', { correlationId });
    return buildPolicy('anonymous', 'Deny', resource);
  }

  if (claims.scope === 'cliente') {
    logStructured('info', 'Acesso autorizado (scope=cliente)', { correlationId, clienteId: claims.sub });
    return buildPolicy(claims.sub, 'Allow', resource, {
      scope: 'cliente',
      clienteId: claims.sub,
      cpf: claims.cpf,
    });
  }

  logStructured('info', 'Acesso autorizado (scope=interno)', { correlationId, userId: claims.sub });
  return buildPolicy(claims.sub, 'Allow', resource, {
    scope: 'interno',
    userId: claims.sub,
  });
}
