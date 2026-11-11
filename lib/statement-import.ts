// Regras puras da importação de faturas: mês de referência, classificação dos itens,
// totais e montagem do pedido ao banco. Sem React e sem acesso ao banco, para facilitar
// testes e, no futuro, importar várias faturas de uma vez (um ImportDraft por arquivo).
import {cleanDescription, normal, type FutureInstallment, type StatementRow} from './statements';
import type {Card, CreditData, Invoice, Line} from './credit';
import type {StatementHeader} from './statement-banks';

export type ImportGroup = 'avista' | 'parcela-nova' | 'existente' | 'revisar' | 'ignorado';
export type ImportRow = StatementRow & {group: ImportGroup; note: string; estimated: boolean; repeated: number; amounts: number[] | null};
export type ReferenceOption = {cycle: string; label: string; closing: string; due: string; invoice?: Invoice};
export type ImportDraft = {
  fileName: string; hash: string; header: StatementHeader; rows: ImportRow[];
  cycle: string; suggestedCycle: string; reason: string; adjust: boolean;
};

const cents = (n: number) => Math.round(Number(n) * 100);
const sum = (values: number[]) => values.reduce((s, v) => s + cents(v), 0) / 100;
export const merchant = (s: string) => normal(cleanDescription(s).replace(/\b\d{1,3}\s*\/\s*\d{1,3}\b/g, ''));
const months = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
export const dateBR = (iso: string) => iso ? iso.split('-').reverse().join('/') : '';
export function cycleLabel(cycle: string) {
  const [y, m] = cycle.split('-').map(Number);
  return months[m - 1].replace(/^./, c => c.toUpperCase()) + '/' + y;
}
function addMonths(cycle: string, n: number) {
  const d = new Date(cycle.slice(0, 7) + '-01T12:00:00Z');
  d.setUTCMonth(d.getUTCMonth() + n);
  return d.toISOString().slice(0, 10);
}
function dayIn(cycle: string, day: number) {
  const d = new Date(cycle.slice(0, 7) + '-01T12:00:00Z');
  const last = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate();
  return cycle.slice(0, 8) + String(Math.min(day, last)).padStart(2, '0');
}
const daysBetween = (a: string, b: string) => Math.abs(Date.parse(a + 'T12:00:00Z') - Date.parse(b + 'T12:00:00Z')) / 86400000;

/** Datas previstas de uma fatura, com a mesma regra do banco de dados (cc_invoice). */
export function invoiceDates(root: Card, cycle: string) {
  const closing = dayIn(cycle, root.closing_day);
  const due = dayIn(addMonths(cycle, root.due_day <= root.closing_day ? 1 : 0), root.due_day);
  return {closing, due};
}

/** Sugere a fatura (mês de referência = mês do fechamento) a partir do que foi lido no PDF. */
export function suggestReference(invoices: Invoice[], root: Card, header: Pick<StatementHeader, 'due' | 'closing'>, current: string): {cycle: string; reason: string} {
  const own = invoices.filter(i => i.card_id === root.id);
  if (header.due) {
    const exact = own.find(i => i.due_date === header.due);
    if (exact) return {cycle: exact.cycle, reason: 'pelo vencimento ' + dateBR(header.due) + ' lido no PDF'};
    const near = own.filter(i => daysBetween(i.due_date, header.due) <= 7).sort((a, b) => daysBetween(a.due_date, header.due) - daysBetween(b.due_date, header.due))[0];
    if (near) return {cycle: near.cycle, reason: 'pelo vencimento ' + dateBR(header.due) + ' lido no PDF'};
    const cycle = addMonths(header.due.slice(0, 7) + '-01', root.due_day <= root.closing_day ? -1 : 0);
    return {cycle, reason: 'pelo vencimento ' + dateBR(header.due) + ' lido no PDF'};
  }
  if (header.closing) {
    const near = own.filter(i => daysBetween(i.closing_date, header.closing) <= 6).sort((a, b) => daysBetween(a.closing_date, header.closing) - daysBetween(b.closing_date, header.closing))[0];
    return {cycle: near?.cycle ?? header.closing.slice(0, 7) + '-01', reason: 'pelo fechamento ' + dateBR(header.closing) + ' lido no PDF'};
  }
  const closed = own.filter(i => i.closing_date <= current).sort((a, b) => b.cycle.localeCompare(a.cycle))[0];
  if (closed) return {cycle: closed.cycle, reason: 'pela última fatura fechada (o PDF não informa datas)'};
  return {cycle: current.slice(0, 7) + '-01', reason: 'pelo mês atual (o PDF não informa datas)'};
}

/** Opções do seletor: meses ao redor da sugestão, com as faturas que já existem. */
export function referenceOptions(invoices: Invoice[], root: Card, around: string): ReferenceOption[] {
  const own = invoices.filter(i => i.card_id === root.id);
  const cycles = new Set<string>();
  for (let n = -6; n <= 2; n++) cycles.add(addMonths(around, n));
  return Array.from(cycles).sort().reverse().map(cycle => {
    const invoice = own.find(i => i.cycle === cycle);
    const dates = invoice ? {closing: invoice.closing_date, due: invoice.due_date} : invoiceDates(root, cycle);
    return {cycle, invoice, ...dates, label: `${cycleLabel(cycle)} · fecha ${dateBR(dates.closing).slice(0, 5)} · vence ${dateBR(dates.due).slice(0, 5)}`};
  });
}

function guessCategory(row: StatementRow, lines: Line[]) {
  if (row.kind === 'fee') return 'Encargos';
  const key = merchant(row.description);
  const previous = lines.filter(l => merchant(l.title) === key && l.category && l.category !== 'Ajuste de Fatura').sort((a, b) => b.charge_date.localeCompare(a.charge_date))[0];
  return previous?.category ?? row.category ?? 'Outros';
}

/**
 * Classifica cada item do PDF comparando com o que já existe no cartão:
 * - parcela que já existe (mesma loja, mesma parcela, mesmo nº de parcelas, valor ±0,05) → vincular, não lança de novo;
 * - à vista idêntico a um lançamento existente → "revisar" (você decide);
 * - pagamentos da fatura anterior → ignorados.
 */
export function classifyRows(rows: StatementRow[], data: CreditData, cardId: string, future: FutureInstallment[] = []): ImportRow[] {
  const lines = data.lines.filter(l => l.card_id === cardId && l.line_type !== 'adjustment');
  const purchases = new Map(data.purchases.map(p => [p.id, p]));
  const invoices = new Map(data.invoices.map(i => [i.id, i]));
  const used = new Set<string>();
  const key = (r: StatementRow) => [merchant(r.description), r.date, cents(r.amount), r.installment, r.count].join('|');
  const repeats = new Map<string, number>();
  for (const r of rows) repeats.set(key(r), (repeats.get(key(r)) ?? 0) + 1);
  const where = (l: Line) => {const i = invoices.get(l.invoice_id); return i ? cycleLabel(i.cycle) : 'outra fatura'};

  return rows.map(raw => {
    const row: ImportRow = {...raw, category: guessCategory(raw, data.lines.filter(l => l.card_id === cardId)), group: 'avista', note: raw.card_final ? 'Cartão final ' + raw.card_final : '', estimated: false, repeated: repeats.get(key(raw)) ?? 1, decision: '', match_id: '', amounts: null};
    const withNote = (text: string) => row.note ? text + ' · ' + row.note : text;
    const take = (l: Line) => {used.add(l.id); return l};
    if (row.kind === 'payment') return {...row, group: 'ignorado', decision: 'skip', note: 'Pagamento da fatura anterior'};
    if (!row.date || !Number.isFinite(row.amount) || row.amount === 0 || !row.description) return {...row, group: 'revisar', note: 'Data, valor ou descrição incompletos: corrija em Editar'};
    if (row.bank_id) {
      const same = lines.find(l => !used.has(l.id) && (l as Line & {bank_transaction_id?: string}).bank_transaction_id === row.bank_id);
      if (same) return {...row, group: 'existente', decision: 'link', match_id: take(same).id, note: 'Já lançado (mesmo identificador do banco) · ' + where(same)};
    }
    if (row.kind === 'purchase' && row.count > 1) {
      const candidates = lines.filter(l => !used.has(l.id) && l.line_type === 'principal' && l.installment === row.installment && purchases.get(l.purchase_id ?? '')?.installments === row.count && Math.abs(cents(l.amount) - cents(row.amount)) <= 5);
      const same = candidates.find(l => merchant(l.title) === merchant(row.description));
      if (same) return {...row, group: 'existente', decision: 'link', match_id: take(same).id, note: withNote(`Parcela ${row.installment}/${row.count} já lançada · ${where(same)}`)};
      if (candidates.length) return {...row, group: 'revisar', match_id: candidates[0].id, note: `Parecida com "${candidates[0].title}" ${row.installment}/${row.count} já lançada · ${where(candidates[0])}. É a mesma compra?`};
      const sibling = lines.find(l => l.line_type === 'principal' && merchant(l.title) === merchant(row.description) && purchases.get(l.purchase_id ?? '')?.installments === row.count);
      if (sibling) return {...row, group: 'revisar', note: `Já existe a compra "${sibling.title}" em ${row.count}x, mas sem a parcela ${row.installment}. Confira antes de lançar.`};
      // Valor das próximas parcelas: lido em "Compras parceladas - próximas faturas" quando o PDF informa.
      const next = future.find(f => f.count === row.count && f.installment === row.installment + 1 && merchant(f.description) === merchant(row.description) && (!row.date || f.day === dateBR(row.date).slice(0, 5)));
      const rest = row.count - row.installment, following = next ? Math.abs(next.amount) : Math.abs(row.amount);
      const amounts = [Math.abs(row.amount), ...Array.from({length: rest}, () => following)];
      const total = (cents(Math.abs(row.amount)) * row.installment + cents(following) * rest) / 100;
      return {...row, group: 'parcela-nova', decision: 'new', estimated: !next && rest > 0, amounts, total_amount: total,
        note: withNote(`Lança as parcelas ${row.installment} a ${row.count}` + (rest > 0 ? ` · próximas de ${following.toFixed(2).replace('.', ',')}${next ? ' (lido no PDF)' : ' (estimado)'}` : ''))};
    }
    const twin = lines.find(l => !used.has(l.id) && l.charge_date === row.date && cents(l.amount) === cents(row.amount) && merchant(l.title) === merchant(row.description));
    if (twin) return {...row, group: 'revisar', match_id: twin.id, note: withNote('Possível duplicado: já existe lançamento igual · ' + where(twin))};
    const total_amount = row.kind === 'purchase' ? Math.abs(row.amount) : row.total_amount;
    return {...row, group: 'avista', decision: 'new', total_amount, note: row.repeated > 1 ? withNote(`Aparece ${row.repeated} vezes no PDF`) : row.note};
  });
}

/** Totais para conferir com o PDF antes de gravar. */
export function importTotals(rows: ImportRow[], data: CreditData, invoice: Invoice | undefined, statementTotal: number | null) {
  const items = sum(rows.filter(r => r.kind !== 'payment' && r.decision !== 'skip').map(r => r.amount));
  const current = invoice ? sum(data.lines.filter(l => l.invoice_id === invoice.id).map(l => l.amount)) : 0;
  const added = sum(rows.filter(r => r.decision === 'new').map(r => r.amount));
  const after = (cents(current) + cents(added)) / 100;
  const linkedIds = new Set(rows.filter(r => r.decision === 'link').map(r => r.match_id));
  const onlyInSystem = invoice ? data.lines.filter(l => l.invoice_id === invoice.id && !linkedIds.has(l.id) && !(l.line_type === 'principal' && l.installment === null && Number(l.amount) === 0)) : [];
  return {
    items, current, added, after, statementTotal, onlyInSystem,
    pdfDifference: statementTotal === null ? null : (cents(statementTotal) - cents(items)) / 100,
    adjustment: statementTotal === null ? null : (cents(statementTotal) - cents(after)) / 100,
  };
}

export const pending = (rows: ImportRow[]) => rows.filter(r => !r.decision || (r.decision === 'new' && r.kind === 'purchase' && (!r.total_amount || r.installment < 1 || r.installment > r.count || r.count > 120)));

/** Pedido enviado ao banco (ação import_statement com mês de referência). */
export function importPayload(draft: ImportDraft, cardId: string, invoice: Invoice | undefined) {
  const rows = draft.rows.map(r => ({original: r.original, description: r.description.trim(), date: r.date, amount: r.amount, category: r.category.trim() || 'Outros', installment: r.installment, count: r.count, total_amount: r.total_amount, bank_id: r.bank_id, kind: r.kind, decision: r.decision, match_id: r.decision === 'link' ? r.match_id : '', ...(r.decision === 'new' && r.amounts && r.amounts.length > 1 ? {amounts: r.amounts} : {})}));
  const suspect = draft.rows.some(r => r.decision === 'new' && (r.group === 'revisar' || r.repeated > 1));
  return {
    card_id: cardId, cycle: draft.cycle, invoice_id: invoice?.id ?? null, revision: invoice?.revision ?? null,
    rows, confirmed: true, confirm_duplicates: suspect, keep_target: false,
    file_hash: draft.hash, file_name: draft.fileName,
    statement: {bank: draft.header.bank, due: draft.header.due || null, closing: draft.header.closing || null, total: draft.header.total},
    adjust_to_statement: draft.adjust && draft.header.total !== null,
    metadata: {institution: draft.header.bankLabel, due: dateBR(draft.header.due), closing: dateBR(draft.header.closing), total: draft.header.total === null ? '' : String(draft.header.total), cycle: draft.cycle.slice(0, 7), suggested: draft.suggestedCycle.slice(0, 7)},
  };
}
