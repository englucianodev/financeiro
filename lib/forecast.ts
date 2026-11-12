// Previsão por média: quanto se gasta, em média, por categoria nos meses anteriores,
// para completar os meses futuros onde ainda não há lançamentos suficientes.
import {isConsumptionEvent, type ViewEvent} from './finance-view';
import {today} from './money';

export type CategoryAverage = {category: string; average: number; months: number};
export type AverageFlow = {id: string; title: string; category: string; account_id: string; amount: number; due_date: string; status: 'pending'; average: true};

function addMonths(ym: string, n: number) {const d = new Date(ym + '-01T12:00:00Z'); d.setUTCMonth(d.getUTCMonth() + n); return d.toISOString().slice(0, 7)}
const name = (e: {category?: string}) => e.category?.trim() || 'Outros';
const counts = (e: ViewEvent) => isConsumptionEvent(e) && e.status !== 'cancelled' && e.kind === 'expense';

/**
 * Média mensal de despesas por categoria nos `lookback` meses completos anteriores ao mês atual.
 * Divide pelos meses que tiveram alguma despesa (um app recém-começado não dilui a média com meses vazios).
 */
export function categoryAverages(events: ViewEvent[], lookback = 3, current = today()): CategoryAverage[] {
  const start = addMonths(current.slice(0, 7), -lookback), end = current.slice(0, 7);
  const past = events.filter(e => counts(e) && e.due_date.slice(0, 7) >= start && e.due_date.slice(0, 7) < end);
  const months = new Set(past.map(e => e.due_date.slice(0, 7))).size;
  if (!months) return [];
  const totals = new Map<string, number>();
  for (const e of past) totals.set(name(e), (totals.get(name(e)) ?? 0) + Math.round(Number(e.amount) * 100));
  return Array.from(totals, ([category, c]) => ({category, average: Math.round(c / months) / 100, months}))
    .filter(a => a.average > 0).sort((a, b) => b.average - a.average);
}

/**
 * Lançamentos estimados (não gravados) para os próximos `horizon` meses, incluindo o atual.
 * Em cada mês e categoria só entra a diferença entre a média e o que já está lançado
 * (pago, previsto ou no cartão), para não contar duas vezes.
 */
export function averageFlows(events: ViewEvent[], accountId: string, horizon = 12, lookback = 3, current = today()): AverageFlow[] {
  if (!accountId) return [];
  const averages = categoryAverages(events, lookback, current);
  const out: AverageFlow[] = [];
  const first = current.slice(0, 7);
  for (let i = 0; i < horizon; i++) {
    const ym = addMonths(first, i);
    for (const a of averages) {
      const known = events.filter(e => counts(e) && name(e) === a.category && e.due_date.slice(0, 7) === ym).reduce((s, e) => s + Math.round(Number(e.amount) * 100), 0);
      const missing = Math.round(a.average * 100) - known;
      if (missing <= 0) continue;
      const mid = ym + '-15', due = i === 0 && mid < current ? current : mid;
      out.push({id: `avg-${a.category}-${ym}`, title: 'Média · ' + a.category, category: a.category, account_id: accountId, amount: -missing / 100, due_date: due, status: 'pending', average: true});
    }
  }
  return out;
}
