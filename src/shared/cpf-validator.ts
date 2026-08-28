/**
 * Validação de dígitos verificadores de CPF.
 *
 * Portado de `src/domain/value-objects/cpf-cnpj.vo.ts` do repositório da aplicação
 * principal (soat15-tech-challenge-01), como função pura, sem depender de classes ou
 * value objects do domínio original — decisão registrada na RFC-003 (cópia em vez de
 * pacote npm compartilhado, já que os dois repositórios não compartilham dependências).
 *
 * Apenas CPF é validado aqui: a Lambda de autenticação por CPF (RFC-003) atende
 * somente clientes pessoa física; CNPJ não faz parte do escopo desta Lambda.
 */

export interface CpfValidationResult {
  valid: boolean;
  /** CPF normalizado (somente dígitos), presente apenas quando `valid` é `true`. */
  digits?: string;
}

/**
 * Remove qualquer caractere não numérico do CPF informado.
 */
export function normalizeCpf(raw: string): string {
  return raw.replace(/\D/g, '');
}

/**
 * Valida o formato e os dígitos verificadores de um CPF.
 *
 * Regras (idênticas à lógica original de `cpf-cnpj.vo.ts`):
 * - precisa ter exatamente 11 dígitos após a normalização;
 * - rejeita sequências de dígito repetido (ex.: "11111111111");
 * - recalcula os dois dígitos verificadores pelo módulo 11.
 */
export function validateCpf(raw: string): CpfValidationResult {
  const digits = normalizeCpf(raw);

  if (digits.length !== 11) {
    return { valid: false };
  }

  if (/^(\d)\1+$/.test(digits)) {
    return { valid: false };
  }

  let sum = 0;
  for (let i = 0; i < 9; i++) sum += parseInt(digits[i], 10) * (10 - i);
  let remainder = sum % 11;
  const digit1 = remainder < 2 ? 0 : 11 - remainder;
  if (parseInt(digits[9], 10) !== digit1) {
    return { valid: false };
  }

  sum = 0;
  for (let i = 0; i < 10; i++) sum += parseInt(digits[i], 10) * (11 - i);
  remainder = sum % 11;
  const digit2 = remainder < 2 ? 0 : 11 - remainder;
  if (parseInt(digits[10], 10) !== digit2) {
    return { valid: false };
  }

  return { valid: true, digits };
}
