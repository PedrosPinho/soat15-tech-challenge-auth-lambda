import { findClienteByCpf } from '../../src/shared/cliente-client';

const resp = (status: number, body?: unknown): Response =>
  ({ ok: status >= 200 && status < 300, status, json: async () => body }) as Response;

describe('findClienteByCpf (OS Service via ALB interno)', () => {
  const fetchImpl = jest.fn();
  const opts = { baseUrl: 'http://alb.internal/', token: 'tok', fetchImpl: fetchImpl as never };
  beforeEach(() => fetchImpl.mockReset());

  it('chama a rota interna com o token e devolve o cliente', async () => {
    fetchImpl.mockResolvedValue(resp(200, { id: 'c1', nome: 'Maria', cpfCnpj: '1', ativo: true }));
    expect(await findClienteByCpf('52998224725', opts)).toEqual({ id: 'c1', nome: 'Maria', ativo: true });
    const [url, init] = fetchImpl.mock.calls[0];
    expect(url).toBe('http://alb.internal/internal/clientes/by-cpf/52998224725');
    expect(init.headers).toEqual({ 'x-internal-token': 'tok' });
  });

  it('404 → null (CPF não cadastrado)', async () => {
    fetchImpl.mockResolvedValue(resp(404));
    expect(await findClienteByCpf('1', opts)).toBeNull();
  });

  it.each([401, 500, 503])('%s lança (indisponibilidade ≠ CPF inexistente)', async (status) => {
    fetchImpl.mockResolvedValue(resp(status));
    await expect(findClienteByCpf('1', opts)).rejects.toThrow(String(status));
  });

  it('resposta malformada lança; nome ausente vira string vazia', async () => {
    fetchImpl.mockResolvedValueOnce(resp(200, { nome: 'x' }));
    await expect(findClienteByCpf('1', opts)).rejects.toThrow('sem id/ativo');
    fetchImpl.mockResolvedValueOnce(resp(200, { id: 'c', ativo: false }));
    expect(await findClienteByCpf('1', opts)).toEqual({ id: 'c', nome: '', ativo: false });
  });

  it('erro de rede propaga; config ausente lança', async () => {
    fetchImpl.mockRejectedValue(new Error('ECONNREFUSED'));
    await expect(findClienteByCpf('1', opts)).rejects.toThrow('ECONNREFUSED');
    const env = { ...process.env };
    delete process.env.INTERNAL_BASE_URL;
    delete process.env.INTERNAL_API_TOKEN;
    await expect(findClienteByCpf('1')).rejects.toThrow('INTERNAL_BASE_URL');
    await expect(findClienteByCpf('1', { baseUrl: 'http://x' })).rejects.toThrow('INTERNAL_API_TOKEN');
    process.env = env;
  });

  it('usa as variáveis de ambiente por padrão', async () => {
    process.env.INTERNAL_BASE_URL = 'http://env-alb';
    process.env.INTERNAL_API_TOKEN = 'env-tok';
    const original = global.fetch;
    global.fetch = jest.fn().mockResolvedValue(resp(404)) as never;
    expect(await findClienteByCpf('9')).toBeNull();
    expect((global.fetch as jest.Mock).mock.calls[0][0]).toBe('http://env-alb/internal/clientes/by-cpf/9');
    global.fetch = original;
  });
});
