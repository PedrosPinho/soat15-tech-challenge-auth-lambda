import { normalizeCpf, validateCpf } from '../../src/shared/cpf-validator';

describe('cpf-validator', () => {
  describe('normalizeCpf', () => {
    it('remove caracteres não numéricos', () => {
      expect(normalizeCpf('529.982.247-25')).toBe('52998224725');
    });

    it('mantém string já normalizada', () => {
      expect(normalizeCpf('52998224725')).toBe('52998224725');
    });
  });

  describe('validateCpf', () => {
    it('aceita um CPF válido conhecido', () => {
      // CPF de teste com dígitos verificadores corretos (amplamente usado em fixtures).
      const result = validateCpf('529.982.247-25');
      expect(result.valid).toBe(true);
      expect(result.digits).toBe('52998224725');
    });

    it('aceita um CPF válido já sem formatação', () => {
      const result = validateCpf('11144477735');
      expect(result.valid).toBe(true);
      expect(result.digits).toBe('11144477735');
    });

    it('rejeita CPF com dígito verificador incorreto', () => {
      const result = validateCpf('52998224700');
      expect(result.valid).toBe(false);
      expect(result.digits).toBeUndefined();
    });

    it('rejeita CPF com todos os dígitos iguais', () => {
      expect(validateCpf('11111111111').valid).toBe(false);
      expect(validateCpf('00000000000').valid).toBe(false);
    });

    it('rejeita CPF com menos de 11 dígitos', () => {
      expect(validateCpf('123456789').valid).toBe(false);
    });

    it('rejeita CPF com mais de 11 dígitos', () => {
      expect(validateCpf('123456789012').valid).toBe(false);
    });

    it('rejeita string vazia', () => {
      expect(validateCpf('').valid).toBe(false);
    });

    it('rejeita entrada não numérica', () => {
      expect(validateCpf('abcdefghijk').valid).toBe(false);
    });
  });
});
