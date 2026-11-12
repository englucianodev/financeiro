"use client";
// Visualização de um cartão: uma fatura por vez, compras à vista separadas das parceladas,
// só o essencial na tela. Tocar num lançamento abre a edição (categoria e, se for compra, a compra completa).
import {useEffect, useMemo, useRef, useState} from 'react';
import type {SupabaseClient} from '@supabase/supabase-js';
import {ChevronLeft, ChevronRight, Upload, Pencil} from 'lucide-react';
import {brl, today} from '@/lib/money';
import {type Card, type CreditData, type Line, cardLimit, invoiceTotals, rootCard} from '@/lib/credit';
import type {ViewAccount, ViewEvent} from '@/lib/finance-view';
import {errorMessage} from '@/lib/errors';

type Member = {user_id: string; display_name: string};
type Category = {name: string; kind: string; active: boolean};
type Operation = {action: string; purchase_id?: string; invoice_id?: string; payment_id?: string};
const months = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro'];
const monthName = (cycle: string) => months[Number(cycle.slice(5, 7)) - 1] + ' ' + cycle.slice(0, 4);
const dm = (iso: string) => iso.slice(8, 10) + '/' + iso.slice(5, 7);
const sum = (rows: {amount: number}[]) => rows.reduce((s, r) => s + Math.round(Number(r.amount) * 100), 0) / 100;
const statusClass: Record<string, string> = {'Paga': 'ok', 'Crédito': 'ok', 'Vencida': 'late', 'Parcialmente paga': 'warn', 'Fechada': 'warn', 'Aberta': 'neutral'};

export function CardDetail({card, data, members, accounts, legacy = [], onBack, onEditCard, onImport, onOperation, onEditLine}: {
  card: Card; data: CreditData; members: Member[]; accounts: ViewAccount[]; legacy?: ViewEvent[];
  onBack: () => void; onEditCard: () => void; onImport: () => void; onOperation: (op: Operation) => void; onEditLine: (line: Line) => void;
}) {
  const root = rootCard(data.cards, card);
  const limit = cardLimit(data, card, legacy);
  const invoices = useMemo(() => data.invoices.filter(i => i.card_id === root.id).sort((a, b) => a.cycle.localeCompare(b.cycle)), [data.invoices, root.id]);
  const withLines = invoices.filter(i => data.lines.some(l => l.invoice_id === i.id));
  // Fatura inicial: a próxima a vencer com saldo; senão, a mais recente com lançamentos.
  const initial = () => {
    const current = today();
    const due = invoices.find(i => i.due_date >= current && invoiceTotals(i, data.lines).balance > 0);
    return (due ?? withLines.at(-1) ?? invoices.find(i => i.closing_date >= current) ?? invoices.at(-1))?.id ?? '';
  };
  const [invoiceId, setInvoiceId] = useState(initial);
  useEffect(() => {if (!invoices.some(i => i.id === invoiceId)) setInvoiceId(initial())}, [invoices]);
  const index = invoices.findIndex(i => i.id === invoiceId), invoice = invoices[index];
  const totals = invoice ? invoiceTotals(invoice, data.lines) : null;
  const purchases = new Map(data.purchases.map(p => [p.id, p]));
  const lines = invoice ? data.lines.filter(l => l.invoice_id === invoice.id && !(l.line_type === 'principal' && l.installment === null && Number(l.amount) === 0)).sort((a, b) => a.charge_date.localeCompare(b.charge_date) || a.title.localeCompare(b.title, 'pt-BR')) : [];
  const count = (l: Line) => purchases.get(l.purchase_id ?? '')?.installments ?? 1;
  const parceladas = lines.filter(l => l.line_type === 'principal' && count(l) > 1);
  const avista = lines.filter(l => l.line_type === 'principal' && count(l) <= 1);
  const outros = lines.filter(l => l.line_type !== 'principal');
  const payments = invoice ? data.payments.filter(p => p.invoice_id === invoice.id) : [];
  const owner = members.find(m => m.user_id === card.owner_id)?.display_name;
  const [more, setMore] = useState(false);
  const usedPct = Math.min(100, Math.max(0, limit.percent));

  const row = (l: Line) => <li key={l.id}>
    <button type="button" className="ccv-line" onClick={() => onEditLine(l)} aria-label={'Editar ' + l.title}>
      <span className="ccv-date">{dm(l.charge_date)}</span>
      <span className="ccv-desc"><span className="ccv-title">{l.title}</span><span className="ccv-cat">{l.category}</span></span>
      {l.installment && count(l) > 1 && <span className="ccv-parc">{l.installment}/{count(l)}</span>}
      <span className={'ccv-amount' + (Number(l.amount) < 0 ? ' credit' : '')}>{brl(Number(l.amount))}</span>
    </button>
  </li>;
  const section = (title: string, list: Line[], empty?: string) => (list.length > 0 || empty) && <section className="ccv-section">
    <header><h4>{title} <span className="ccv-count">{list.length}</span></h4><strong>{brl(sum(list))}</strong></header>
    {list.length ? <ul>{list.map(row)}</ul> : <p className="ccv-empty">{empty}</p>}
  </section>;

  return <div className="ccv">
    <div className="ccv-top">
      <button type="button" className="btn ghost sm" onClick={onBack}><ChevronLeft size={16}/>Cartões</button>
      <div className="ccv-actions">
        <button type="button" className="btn ghost sm" onClick={onImport}><Upload size={15}/>Importar fatura</button>
        <button type="button" className="btn ghost sm" onClick={onEditCard}><Pencil size={14}/>Editar cartão</button>
      </div>
    </div>
    <div className="ccv-card" style={{borderColor: card.color ?? undefined}}>
      <div><h3>{card.name}</h3><p>{owner}{card.parent_card_id ? ' · adicional de ' + root.name : ''}</p></div>
      <div className="ccv-limit">
        <div className="ccv-limit-text"><span>Disponível</span><strong>{brl(limit.available)}</strong><span>de {brl(limit.total)}</span></div>
        <div className="ccv-bar" role="img" aria-label={`Limite usado ${usedPct.toFixed(0)}%`}><i style={{width: usedPct + '%'}}/></div>
      </div>
    </div>

    {invoice && totals ? <>
      <nav className="ccv-nav" aria-label="Escolher fatura">
        <button type="button" className="btn ghost icon" aria-label="Fatura anterior" disabled={index <= 0} onClick={() => setInvoiceId(invoices[index - 1].id)}><ChevronLeft size={18}/></button>
        <select aria-label="Fatura" value={invoice.id} onChange={e => setInvoiceId(e.target.value)}>
          {invoices.map(i => <option key={i.id} value={i.id}>Fatura de {monthName(i.due_date)}</option>)}
        </select>
        <button type="button" className="btn ghost icon" aria-label="Próxima fatura" disabled={index >= invoices.length - 1} onClick={() => setInvoiceId(invoices[index + 1].id)}><ChevronRight size={18}/></button>
      </nav>

      <div className="ccv-summary">
        <div className="ccv-total"><span>Total da fatura</span><strong>{brl(totals.total)}</strong>
          {totals.paid > 0 && <small>Pago {brl(totals.paid)} · falta {brl(Math.max(0, totals.balance))}</small>}</div>
        <dl><div><dt>Vence</dt><dd>{dm(invoice.due_date)}</dd></div><div><dt>Fecha</dt><dd>{dm(invoice.closing_date)}</dd></div><div><dt>Situação</dt><dd><span className={'chip ' + (statusClass[totals.status] ?? 'neutral')}>{totals.status}</span></dd></div></dl>
        <div className="ccv-pay">
          {totals.balance > 0 && <button type="button" className="btn" onClick={() => onOperation({action: 'pay_invoice', invoice_id: invoice.id})}>Pagar fatura</button>}
          <button type="button" className="btn ghost" aria-expanded={more} onClick={() => setMore(v => !v)}>Mais ações</button>
        </div>
        {more && <div className="ccv-more">
          <button type="button" className="btn ghost sm" onClick={() => onOperation({action: 'fee', invoice_id: invoice.id})}>Juros ou multa</button>
          <button type="button" className="btn ghost sm" onClick={() => onOperation({action: 'refund', invoice_id: invoice.id})}>Estorno</button>
          <button type="button" className="btn ghost sm" onClick={() => onOperation({action: 'anticipate', invoice_id: invoice.id})}>Antecipar parcela</button>
          {totals.balance < 0 && <button type="button" className="btn ghost sm" onClick={() => onOperation({action: 'transfer_credit', invoice_id: invoice.id})}>Usar crédito em outra fatura</button>}
        </div>}
      </div>

      {section('À vista', avista, lines.length ? undefined : 'Nenhum lançamento nesta fatura.')}
      {section('Parceladas', parceladas)}
      {section('Encargos, estornos e ajustes', outros)}

      {payments.length > 0 && <section className="ccv-section">
        <header><h4>Pagamentos</h4></header>
        <ul>{payments.map(p => <li key={p.id} className="ccv-payment">
          <span>{dm(p.paid_date)} · {accounts.find(a => a.id === p.account_id)?.name ?? 'Conta'}{p.reversed_at && ' · desfeito'}</span>
          <strong>{brl(Number(p.amount))}</strong>
          {!p.reversed_at && <button type="button" className="btn ghost sm" onClick={() => onOperation({action: 'undo_payment', payment_id: p.id})}>Desfazer</button>}
        </li>)}</ul>
      </section>}
      <p className="ccv-hint">Toque num lançamento para mudar a categoria ou corrigir a compra.</p>
    </> : <p className="ccv-empty">Este cartão ainda não tem faturas.</p>}
  </div>;
}

/** Edição rápida de um lançamento do cartão: categoria (com opção de aplicar à compra inteira). */
export function LineEditor({db, household, data, line, categories, reload, onClose, onEditPurchase}: {
  db: SupabaseClient; household: string; data: CreditData; line: Line; categories: Category[];
  reload: () => Promise<void>; onClose: () => void; onEditPurchase: (purchaseId: string) => void;
}) {
  const dialog = useRef<HTMLDialogElement>(null), key = useRef(crypto.randomUUID());
  const purchase = data.purchases.find(p => p.id === line.purchase_id);
  const options = Array.from(new Set([line.category, ...categories.filter(c => c.kind === 'expense' && c.active).map(c => c.name)])).sort((a, b) => a.localeCompare(b, 'pt-BR'));
  const [category, setCategory] = useState(line.category), [all, setAll] = useState(true), [busy, setBusy] = useState(false), [error, setError] = useState('');
  useEffect(() => {dialog.current?.showModal()}, []);
  async function save() {
    setBusy(true); setError('');
    try {
      const r = await db.rpc('cc_action', {p_id: key.current, p_household: household, p_action: 'set_category', p_data: {line_id: line.id, category, scope: purchase && all ? 'purchase' : 'line'}});
      if (r.error) throw r.error;
      await reload(); onClose();
    } catch (e) {
      const message = errorMessage(e);
      setError(/Operação inválida/.test(message) ? 'O banco ainda não tem a atualização 028. Aplique-a no Supabase e tente de novo.' : message);
      key.current = crypto.randomUUID();
    } finally {setBusy(false)}
  }
  return <dialog ref={dialog} className="account-dialog ccv-dialog" aria-label="Editar lançamento do cartão" onCancel={e => {if (busy) e.preventDefault(); else onClose()}}>
    <h2>{line.title}</h2>
    <p className="ccv-dialog-meta">{dm(line.charge_date)} · {brl(Number(line.amount))}{line.installment && purchase && purchase.installments > 1 ? ` · parcela ${line.installment}/${purchase.installments}` : ''}</p>
    <label>Categoria
      <select value={category} onChange={e => setCategory(e.target.value)}>{options.map(c => <option key={c}>{c}</option>)}</select>
    </label>
    {purchase && purchase.installments > 1 && <label className="check"><input type="checkbox" checked={all} onChange={e => setAll(e.target.checked)}/>Aplicar a todas as parcelas desta compra</label>}
    {error && <p role="alert" className="payment-error">{error}</p>}
    <div className="ccv-dialog-actions">
      <button type="button" className="btn" disabled={busy || !category || category === line.category} onClick={() => void save()}>{busy ? 'Salvando…' : 'Salvar categoria'}</button>
      <button type="button" className="btn ghost" disabled={busy} onClick={onClose}>Cancelar</button>
    </div>
    {purchase && <button type="button" className="btn link" disabled={busy} onClick={() => {onClose(); onEditPurchase(purchase.id)}}>Corrigir valor, data ou parcelas da compra</button>}
  </dialog>;
}
