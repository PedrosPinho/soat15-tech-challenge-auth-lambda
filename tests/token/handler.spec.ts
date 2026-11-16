import type { APIGatewayProxyEventV2 } from 'aws-lambda';
import jwt from 'jsonwebtoken';

jest.mock('../../src/shared/cliente-client');
import { findClienteByCpf } from '../../src/shared/cliente-client';
import { handler } from '../../src/token/handler';

const mocked = findClienteByCpf as jest.Mock;
const CPF_VALIDO = '52998224725';

const evento = (body?: unknown, base64 = false): APIGatewayProxyEventV2 =>
  ({
    body: body === undefined ? undefined : base64 ? Buffer.from(JSON.stringify(body)).toString('base64') : JSON.stringify(body),
    isBase64Encoded: base64,
    headers: {},
    requestContext: { requestId: 'req-1' },
  }) as unknown as APIGatewayProxyEventV2;

const resultado = async (e: APIGatewayProxyEventV2): Promise<{ statusCode: number; body: Record<string, unknown> }> => {
  const r = (await handler(e)) as { statusCode: number; body: string };
  return { statusCode: r.statusCode, body: JSON.parse(r.body) };
};

describe('POST /auth/token', () => {
  beforeEach(() => {
    mocked.mockReset();
    process.env.JWT_SECRET = 'segredo';
    delete process.env.JWT_EXPIRES_IN;
    jest.spyOn(console, 'log').mockImplementation(() => undefined);
  });

  it('400 para CPF inválido, ausente ou corpo ilegível — sem consultar o OS', async () => {
    expect((await resultado(evento({ cpf: '111.111.111-11' }))).statusCode).toBe(400);
    expect((await resultado(evento({}))).statusCode).toBe(400);
    expect((await resultado(evento(undefined))).statusCode).toBe(400);
    expect((await resultado({ ...evento(), body: '{nao-json' } as APIGatewayProxyEventV2)).statusCode).toBe(400);
    expect(mocked).not.toHaveBeenCalled();
  });

  it('404 e 403 têm corpo idêntico (sem enumeração de CPFs)', async () => {
    mocked.mockResolvedValueOnce(null);
    const nao = await resultado(evento({ cpf: CPF_VALIDO }));
    mocked.mockResolvedValueOnce({ id: 'c', nome: 'M', ativo: false });
    const inativo = await resultado(evento({ cpf: CPF_VALIDO }));
    expect(nao.statusCode).toBe(404);
    expect(inativo.statusCode).toBe(403);
    expect(nao.body).toEqual(inativo.body);
  });

  it('200 emite JWT scope cliente com sub e cpf; aceita corpo em base64', async () => {
    mocked.mockResolvedValue({ id: 'cliente-1', nome: 'Maria', ativo: true });
    const r = await resultado(evento({ cpf: '529.982.247-25' }, true));
    expect(r.statusCode).toBe(200);
    const claims = jwt.verify(r.body.token as string, 'segredo') as jwt.JwtPayload;
    expect(claims).toMatchObject({ sub: 'cliente-1', cpf: CPF_VALIDO, scope: 'cliente' });
    expect(mocked).toHaveBeenCalledWith(CPF_VALIDO);
  });

  it('500 quando o OS Service está indisponível (nunca 404) ou sem JWT_SECRET', async () => {
    mocked.mockRejectedValueOnce(new Error('timeout'));
    expect((await resultado(evento({ cpf: CPF_VALIDO }))).statusCode).toBe(500);
    mocked.mockRejectedValueOnce('texto');
    expect((await resultado(evento({ cpf: CPF_VALIDO }))).statusCode).toBe(500);

    mocked.mockResolvedValue({ id: 'c', nome: 'M', ativo: true });
    delete process.env.JWT_SECRET;
    expect((await resultado(evento({ cpf: CPF_VALIDO }))).statusCode).toBe(500);
  });
});
