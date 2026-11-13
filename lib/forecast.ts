// Previsão pela média dos CARTÕES DE CRÉDITO.
// Despesas fora do cartão (fixas, recorrentes, avulsas) entram só como estão cadastradas: não se tira média delas.
// Os cartões variam muito; por isso cada fatura futura é completada até a média das faturas anteriores
// daquele cartão (à vista + parcelas + encargos), descontando o que já está lançado nela (parcelas futuras etc.).
import {invoiceMonth, invoiceTotals, type Card, type CreditData} from './credit';
import {today} from './money';

export type CardAverage = {card_id: string; name: string; average: number; invoices: number};
export type AverageFlow = {id: string; title: string; card_id: string; account_id: string; amount: number; due_date: string; status: 'pending'; average: true};

function addMonths(ym: string, n: number) {const d = new Date(ym + '-01T12:00:00Z'); d.setUTCMonth(d.getUTCMonth() + n); return d.toISOString().slice(0, 7)}
const cents = (n: number) => Math.round(Number(n) * 100);
function dueIn(ym: string, day: number) {
  const [y, m] = ym.split('-').map(Number), last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  return ym + '-' + String(Math.min(day, last)).padStart(2, '0');
}
/** Cartões principais (o adicional divide a fatura com o principal). */
const roots = (data: CreditData) => data.cards.filter(c => !c.parent_card_id && c.card_status !== 'archived');

/**
 * Média das faturas de cada cartão nos `lookback` meses anteriores ao atual (pelo mês do vencimento).
 * Divide pelas faturas que tiveram lançamentos, para um cartão novo não ter a média diluída por meses vazios.
 */
export function cardAverages(data: CreditData, lookback = 3, current = today()): CardAverage[] {
  const start = addMonths(current.slice(0, 7), -lookback), end = current.slice(0, 7);
  return roots(data).map(card => {
    const past = data.invoices.filter(i => i.card_id === card.id && invoiceMonth(i) >= start && invoiceMonth(i) < end && data.lines.some(l => l.invoice_id === i.id));
    const total = past.reduce((s, i) => s + cents(invoiceTotals(i, data.lines, current).total), 0);
    return {card_id: card.id, name: card.name, average: past.length ? Math.round(total / past.length) / 100 : 0, invoices: past.length};
  }).filter(a => a.average > 0).sort((a, b) => b.average - a.average);
}

/**
 * Valores estimados (não gravados) para as faturas dos próximos `horizon` meses, incluindo o atual.
 * Para cada cartão e mês: média − o que já está na fatura. Fatura já fechada não recebe estimativa.
 * O valor entra na data de vencimento da fatura, na conta que paga o cartão.
 */
export function cardAverageFlows(data: CreditData, horizon = 12, lookback = 3, current = today()): AverageFlow[] {
  const averages = cardAverages(data, lookback, current), out: AverageFlow[] = [];
  for (const a of averages) {
    const card = data.cards.find(c => c.id === a.card_id) as Card;
    for (let i = 0; i < horizon; i++) {
      const ym = addMonths(current.slice(0, 7), i);
      const invoice = data.invoices.find(v => v.card_id === card.id && invoiceMonth(v) === ym);
      const due = invoice?.due_date ?? dueIn(ym, card.due_day);
      if (due < current || (invoice && invoice.closing_date < current)) continue; // já venceu ou já fechou: valor conhecido
      const known = invoice ? cents(invoiceTotals(invoice, data.lines, current).total) : 0;
      const missing = cents(a.average) - known;
      if (missing <= 0) continue;
      out.push({id: `avg-${card.id}-${ym}`, title: 'Média · ' + card.name, card_id: card.id, account_id: card.account_id, amount: -missing / 100, due_date: due, status: 'pending', average: true});
    }
  }
  return out;
}
