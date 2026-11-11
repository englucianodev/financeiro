// Identifica o banco da fatura e lê o cabeçalho (fechamento, vencimento, total, final do cartão).
// Para incluir um banco novo, acrescente um item em BANKS com o padrão de identificação
// e, se necessário, padrões próprios de cabeçalho. A leitura das linhas continua em statements.ts.
import {money} from './statements';

export type BankId = 'c6' | 'itau' | 'generico';
export type StatementHeader = {
  bank: BankId;
  bankLabel: string;
  due: string;      // vencimento AAAA-MM-DD ('' se não encontrado)
  closing: string;  // fechamento/emissão AAAA-MM-DD ('' se não encontrado)
  total: number | null; // total impresso no PDF
  last4: string;
};

type BankProfile = {id: BankId; label: string; detect: RegExp; closing: RegExp[]; due: RegExp[]; total: RegExp[]};

const DATE = '(\\d{2}\\/\\d{2}\\/\\d{2,4})';
const AMOUNT = '(-?\\s*(?:R\\$\\s*)?[\\d.]+,\\d{2})';
const common = {
  due: [new RegExp('(?:data\\s+de\\s+)?vencimento[^0-9\\n]{0,40}' + DATE, 'i')],
  total: [
    new RegExp('total\\s+(?:desta|da)\\s+fatura[^0-9\\n-]{0,30}' + AMOUNT, 'i'),
    new RegExp('valor\\s+(?:total\\s+)?da\\s+fatura[^0-9\\n-]{0,30}' + AMOUNT, 'i'),
    new RegExp('(?:total|valor)\\s+a\\s+pagar[^0-9\\n-]{0,30}' + AMOUNT, 'i'),
  ],
};

export const BANKS: BankProfile[] = [
  {
    id: 'c6', label: 'C6 Bank',
    detect: /\bC6\s*(?:Bank|Carbon|Black|Platinum)?\b|transa[cç][oõ]es\s+feitas\s+at[eé]/i,
    closing: [new RegExp('transa[cç][oõ]es\\s+feitas\\s+at[eé]\\s*' + DATE, 'i')],
    due: common.due, total: common.total,
  },
  {
    id: 'itau', label: 'Azul Itaucard / Itaú',
    detect: /itaucard|ita[uú]|\bazul\b|VALOR EM R\$/i,
    closing: [new RegExp('emiss[aã]o\\s*:?\\s*' + DATE, 'i')],
    due: common.due, total: common.total,
  },
];

export function isoDate(text: string) {
  const m = text.match(/^(\d{2})\/(\d{2})\/(\d{2}|\d{4})$/);
  if (!m) return '';
  const year = m[3].length === 2 ? '20' + m[3] : m[3];
  const iso = `${year}-${m[2]}-${m[1]}`;
  const d = new Date(iso + 'T12:00:00Z');
  return Number.isFinite(d.getTime()) && d.toISOString().slice(0, 10) === iso ? iso : '';
}

function first(text: string, patterns: RegExp[]) {
  for (const p of patterns) {
    const m = text.match(p);
    if (m?.[1]) return m[1];
  }
  return '';
}

// "Fechamento" genérico, ignorando "previsão do próximo fechamento".
function genericClosing(text: string) {
  const re = new RegExp('fechamento(?:\\s+da\\s+fatura)?[^0-9\\n]{0,25}' + DATE, 'gi');
  for (const m of text.matchAll(re)) {
    const before = text.slice(Math.max(0, (m.index ?? 0) - 25), m.index).toLowerCase();
    if (/pr[oó]x|previs/.test(before)) continue;
    return m[1];
  }
  return '';
}

export function detectBank(text: string): BankProfile | null {
  return BANKS.find(b => b.detect.test(text)) ?? null;
}

export function readHeader(text: string): StatementHeader {
  const profile = detectBank(text);
  const closingText = (profile && first(text, profile.closing)) || genericClosing(text) || first(text, [new RegExp('emiss[aã]o\\s*:?\\s*' + DATE, 'i')]);
  const dueText = first(text, profile?.due ?? common.due);
  const totalText = first(text, profile?.total ?? common.total);
  const closing = closingText ? isoDate(closingText) : '';
  let due = dueText ? isoDate(dueText) : '';
  // Coerência: o vencimento vem depois do fechamento.
  if (closing && due && due <= closing) due = '';
  const total = totalText ? Math.abs(money(totalText)) : NaN;
  const last4 = text.match(/final\s*:?\s*(\d{4})\b/i)?.[1] ?? text.match(/(?:\*{2,}|x{4}|\.{4})\s?(\d{4})\b/i)?.[1] ?? '';
  return {
    bank: profile?.id ?? 'generico',
    bankLabel: profile?.label ?? 'Banco não identificado',
    due, closing,
    total: Number.isFinite(total) ? total : null,
    last4,
  };
}
