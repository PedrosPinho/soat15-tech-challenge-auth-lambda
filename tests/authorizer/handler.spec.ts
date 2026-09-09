import type { APIGatewayRequestAuthorizerEvent } from 'aws-lambda';
import jwt from 'jsonwebtoken';
import { decodeAndValidateToken, handler } from '../../src/authorizer/handler';

jest.mock('jsonwebtoken');
const mockedJwt = jwt as jest.Mocked<typeof jwt>;

const RESOURCE_ARN =
  'arn:aws:execute-api:us-east-1:442534931336:abc123/$default/GET/api/ordens-servico/buscar';

function buildEvent(authorizationHeader?: string): APIGatewayRequestAuthorizerEvent {
  return {
    type: 'REQUEST',
    methodArn: RESOURCE_ARN,
    resource: '/api/{proxy+}',
    path: '/api/ordens-servico/buscar',
    httpMethod: 'GET',
    headers: authorizationHeader ? { Authorization: authorizationHeader } : {},
    multiValueHeaders: {},
    pathParameters: null,
    queryStringParameters: null,
    multiValueQueryStringParameters: null,
    stageVariables: null,
    requestContext: { requestId: 'test-request-id' } as APIGatewayRequestAuthorizerEvent['requestContext'],
  } as unknown as APIGatewayRequestAuthorizerEvent;
}

describe('authorizer decodeAndValidateToken', () => {
  beforeEach(() => jest.resetAllMocks());

  it('retorna claims de cliente para token com scope=cliente', () => {
    mockedJwt.verify.mockReturnValue({ sub: 'cliente-1', cpf: '52998224725', scope: 'cliente' } as never);
    const claims = decodeAndValidateToken('token', 'secret');
    expect(claims).toEqual({ sub: 'cliente-1', cpf: '52998224725', scope: 'cliente' });
  });

  it('retorna claims de usuário interno para token com scope=interno', () => {
    mockedJwt.verify.mockReturnValue({ sub: 'user-1', scope: 'interno' } as never);
    const claims = decodeAndValidateToken('token', 'secret');
    expect(claims).toEqual({ sub: 'user-1', scope: 'interno' });
  });

  it('retorna null para escopo desconhecido', () => {
    mockedJwt.verify.mockReturnValue({ sub: 'x', scope: 'outro' } as never);
    expect(decodeAndValidateToken('token', 'secret')).toBeNull();
  });

  it('retorna null quando jwt.verify lança (assinatura inválida/expirado)', () => {
    mockedJwt.verify.mockImplementation(() => {
      throw new Error('jwt expired');
    });
    expect(decodeAndValidateToken('token', 'secret')).toBeNull();
  });
});

describe('authorizer handler', () => {
  const originalSecret = process.env.JWT_SECRET;

  beforeEach(() => {
    jest.resetAllMocks();
    process.env.JWT_SECRET = 'test-secret';
  });

  afterAll(() => {
    process.env.JWT_SECRET = originalSecret;
  });

  it('nega acesso quando não há header Authorization', async () => {
    const result = await handler(buildEvent());
    expect(result.policyDocument.Statement[0].Effect).toBe('Deny');
  });

  it('nega acesso quando o header não é Bearer', async () => {
    const result = await handler(buildEvent('Basic abc123'));
    expect(result.policyDocument.Statement[0].Effect).toBe('Deny');
  });

  it('nega acesso quando o token é inválido', async () => {
    mockedJwt.verify.mockImplementation(() => {
      throw new Error('invalid');
    });
    const result = await handler(buildEvent('Bearer bad-token'));
    expect(result.policyDocument.Statement[0].Effect).toBe('Deny');
  });

  it('permite acesso e injeta contexto para scope=cliente', async () => {
    mockedJwt.verify.mockReturnValue({ sub: 'cliente-1', cpf: '52998224725', scope: 'cliente' } as never);
    const result = await handler(buildEvent('Bearer good-token'));
    expect(result.policyDocument.Statement[0].Effect).toBe('Allow');
    expect(result.context).toEqual({ scope: 'cliente', clienteId: 'cliente-1', cpf: '52998224725' });
  });

  it('permite acesso e injeta contexto para scope=interno', async () => {
    mockedJwt.verify.mockReturnValue({ sub: 'user-1', scope: 'interno' } as never);
    const result = await handler(buildEvent('Bearer good-token'));
    expect(result.policyDocument.Statement[0].Effect).toBe('Allow');
    expect(result.context).toEqual({ scope: 'interno', userId: 'user-1' });
  });

  it('nega acesso quando JWT_SECRET não está configurado', async () => {
    delete process.env.JWT_SECRET;
    const result = await handler(buildEvent('Bearer good-token'));
    expect(result.policyDocument.Statement[0].Effect).toBe('Deny');
  });
});
