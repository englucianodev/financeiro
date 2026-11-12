"use client";
import {useEffect, useMemo, useRef, useState} from 'react';
import type {SupabaseClient} from '@supabase/supabase-js';
import {type Card, type CreditData, invoiceTotals, rootCard} from '@/lib/credit';
import {parseStatement, type StatementRow} from '@/lib/statements';
import {readStatementFile, recognizeProtectedPages} from '@/lib/statement-file';
import {readHeader} from '@/lib/statement-banks';
import {classifyRows, cycleLabel, dateBR, referenceLabel, importPayload, importTotals, pending, referenceOptions, suggestReference, type ImportDraft, type ImportGroup, type ImportRow} from '@/lib/statement-import';
import {brl, today} from '@/lib/money';
import {errorMessage} from '@/lib/errors';
import ImportHistory from './import-history';

type Props = {db: SupabaseClient; household: string; data: CreditData; card: Card; categories?: {name: string; kind: string; active: boolean}[]; reload: () => Promise<void>; onClose: () => void};

const GROUPS: {id: ImportGroup; title: string; hint: string; open: boolean}[] = [
  {id: 'revisar', title: 'Precisam da sua decisão', hint: 'Possíveis duplicados ou dados incompletos.', open: true},
  {id: 'avista', title: 'À vista, encargos e estornos', hint: 'Serão lançados um a um.', open: true},
  {id: 'parcela-nova', title: 'Parcelamentos novos', hint: 'Lança a parcela desta fatura e as seguintes.', open: true},
  {id: 'existente', title: 'Já lançados', hint: 'Não serão lançados de novo.', open: false},
  {id: 'ignorado', title: 'Ignorados', hint: 'Pagamentos da fatura anterior.', open: false},
];
const KINDS: [StatementRow['kind'], string][] = [['purchase', 'Compra'], ['fee', 'Encargo / IOF'], ['refund', 'Estorno'], ['credit', 'Crédito'], ['payment', 'Pagamento anterior']];

export default function StatementTools({db, household, data, card, categories = [], reload, onClose}: Props) {
  const dialog = useRef<HTMLDialogElement>(null), lock = useRef(false), requestId = useRef(''), passwordReply = useRef<((v: {password: string; save: boolean} | null) => void) | null>(null);
  const root = rootCard(data.cards, card);
  const invoices = useMemo(() => data.invoices.filter(i => i.card_id === root.id).sort((a, b) => b.cycle.localeCompare(a.cycle)), [data.invoices, root.id]);
  const [draft, setDraft] = useState<ImportDraft | null>(null);
  const [busy, setBusy] = useState(false), [progress, setProgress] = useState(''), [error, setError] = useState(''), [done, setDone] = useState('');
  const [editing, setEditing] = useState<number | null>(null);
  const [passwordNeeded, setPasswordNeeded] = useState(false), [password, setPassword] = useState(''), [savePassword, setSavePassword] = useState(false);
  const [history, setHistory] = useState<{file_hash?: string; status?: string}[]>([]);

  useEffect(() => {dialog.current?.showModal(); void loadHistory()}, []);
  async function loadHistory() {const r = await db.from('cc_imports').select('file_hash,status').eq('card_id', card.id); if (!r.error) setHistory(r.data ?? [])}

  const options = useMemo(() => draft ? referenceOptions(invoices, root, draft.suggestedCycle) : [], [draft?.suggestedCycle, invoices, root]);
  const selected = options.find(o => o.cycle === draft?.cycle) ?? (draft ? {cycle: draft.cycle, label: referenceLabel(invoices, root, draft.cycle), closing: '', due: '', invoice: invoices.find(i => i.cycle === draft.cycle)} : undefined);
  const totals = draft ? importTotals(draft.rows, data, selected?.invoice, draft.header.total) : null;
  const waiting = draft ? pending(draft.rows) : [];
  const newCount = draft?.rows.filter(r => r.decision === 'new').length ?? 0;
  const duplicateFile = draft ? history.some(h => h.file_hash === draft.hash && h.status !== 'undone') : false;

  async function protectedReader(file: File) {
    const token = (await db.auth.getSession()).data.session?.access_token;
    if (!token) throw new Error('Entre novamente para abrir o PDF protegido.');
    let supplied: {password: string; save: boolean} | null = {password: '', save: false};
    while (supplied) {
      const body = new FormData(); body.set('file', file); body.set('card', card.id); body.set('password', supplied.password); body.set('save', String(supplied.save));
      const response = await fetch('/api/statements/unlock', {method: 'POST', headers: {Authorization: 'Bearer ' + token}, body, cache: 'no-store'});
      const result = await response.json();
      if (result.needsPassword) {
        setSavePassword(Boolean(result.hasSaved)); setPassword(''); setPasswordNeeded(true);
        supplied = await new Promise(resolve => {passwordReply.current = resolve});
        setPasswordNeeded(false); continue;
      }
      if (!response.ok) throw new Error(result.error ?? 'Não foi possível abrir o PDF.');
      return recognizeProtectedPages(result.pages);
    }
    throw new Error('Leitura cancelada.');
  }

  async function read(file: File) {
    setBusy(true); setError(''); setDone(''); setDraft(null); setEditing(null);
    try {
      const extracted = await readStatementFile(file, setProgress, protectedReader);
      const header = readHeader(extracted.text);
      const suggestion = suggestReference(invoices, root, header, today());
      const reference = header.closing || invoices.find(i => i.cycle === suggestion.cycle)?.closing_date || '';
      const parsed = parseStatement(extracted.text, extracted.format, reference);
      if (!parsed.rows.length) throw new Error('Nenhum lançamento reconhecido neste arquivo. Se for um PDF escaneado, tente novamente; se persistir, use o CSV do banco.');
      requestId.current = crypto.randomUUID();
      setDraft({fileName: file.name, hash: extracted.hash, header, rows: classifyRows(parsed.rows, data, card.id, parsed.future), cycle: suggestion.cycle, suggestedCycle: suggestion.cycle, reason: suggestion.reason, adjust: header.total !== null});
    } catch (e) {setError(errorMessage(e))} finally {setBusy(false); setProgress('')}
  }

  function updateRow(n: number, patch: Partial<ImportRow>) {
    requestId.current = crypto.randomUUID();
    setDraft(d => d && {...d, rows: d.rows.map((r, i) => {
      if (i !== n) return r;
      const row = {...r, ...patch};
      if (patch.count !== undefined || patch.amount !== undefined || patch.installment !== undefined) {
        // Mudou a parcela: volta à divisão em partes iguais (os valores lidos no PDF deixam de valer).
        row.amounts = null;
        row.total_amount = row.count === 1 ? Math.abs(row.amount) : Math.round(Math.abs(row.amount) * 100) * row.count / 100;
      }
      if (patch.total_amount !== undefined) row.amounts = null;
      if (patch.decision === 'new' && row.group === 'revisar') row.note = 'Você decidiu lançar mesmo assim.';
      return row;
    })});
  }

  async function confirm() {
    if (!draft || lock.current) return;
    const summary = `Importar ${newCount} lançamento(s) na fatura de ${referenceLabel(invoices, root, draft.cycle)}?` + (draft.adjust && totals?.adjustment ? `\nAjuste para o total do PDF: ${brl(totals.adjustment)}.` : '') + '\nVocê poderá desfazer pelo histórico de importações.';
    if (!window.confirm(summary)) return;
    lock.current = true; setBusy(true); setError('');
    try {
      const payload = importPayload(draft, card.id, selected?.invoice);
      const r = await db.rpc('cc_action', {p_id: requestId.current, p_household: household, p_action: 'import_statement', p_data: payload});
      if (r.error) {await db.rpc('record_cc_import_error', {p_household: household, p_data: {file_name: draft.fileName, error: r.error.message}}); throw r.error}
      await reload(); await loadHistory();
      setDone(`Importação concluída: ${r.data?.imported ?? newCount} lançado(s), ${r.data?.linked ?? 0} já existente(s) na fatura de ${referenceLabel(invoices, root, draft.cycle)}.`);
      setDraft(null);
    } catch (e) {setError(errorMessage(e))} finally {lock.current = false; setBusy(false)}
  }

  const rowView = (r: ImportRow, n: number) => (
    <li key={n} className={'import-row' + (r.decision === '' ? ' needs-decision' : '')}>
      <div className="import-row-main">
        <span className="import-date">{dateBR(r.date).slice(0, 5) || '??/??'}</span>
        <span className="import-desc">{r.description}{r.count > 1 && <em> {r.installment}/{r.count}</em>}{r.note && <small>{r.note}</small>}{r.kind !== 'payment' && <small className="import-cat">Categoria: <b>{r.category || 'Outros'}</b>{r.category_hint && ' · ' + r.category_hint}</small>}</span>
        <strong className={r.amount < 0 ? 'positive' : ''}>{brl(r.amount)}</strong>
      </div>
      <div className="import-row-actions">
        <select aria-label={'Decisão para ' + r.description} value={r.decision} onChange={e => updateRow(n, {decision: e.target.value as ImportRow['decision']})}>
          <option value="">Decidir…</option>
          <option value="new">Lançar</option>
          {r.match_id && <option value="link">Já existe (não lançar)</option>}
          <option value="skip">Ignorar</option>
        </select>
        <button type="button" className="link-button" onClick={() => setEditing(editing === n ? null : n)}>{editing === n ? 'Fechar' : 'Editar'}</button>
      </div>
      {editing === n && <div className="form-grid import-editor">
        <label>Descrição<input value={r.description} maxLength={200} onChange={e => updateRow(n, {description: e.target.value})}/></label>
        <label>Data da compra<input type="date" max={today()} value={r.date} onChange={e => updateRow(n, {date: e.target.value})}/></label>
        <label>Valor nesta fatura<input type="number" step=".01" value={Number.isFinite(r.amount) ? r.amount : ''} onChange={e => updateRow(n, {amount: Number(e.target.value)})}/></label>
        <label>Categoria<input list="import-categories" value={r.category} maxLength={100} onChange={e => updateRow(n, {category: e.target.value, category_hint: ''})}/></label>
        <label>Tipo<select value={r.kind} onChange={e => updateRow(n, {kind: e.target.value as ImportRow['kind']})}>{KINDS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select></label>
        <label>Parcela<span className="inline-pair"><input aria-label="Parcela atual" type="number" min="1" max="120" value={r.installment} onChange={e => updateRow(n, {installment: Number(e.target.value)})}/> de <input aria-label="Total de parcelas" type="number" min="1" max="120" value={r.count} onChange={e => updateRow(n, {count: Number(e.target.value)})}/></span></label>
        {r.kind === 'purchase' && r.count > 1 && <label>Valor total da compra<input type="number" step=".01" min=".01" value={r.total_amount ?? ''} onChange={e => updateRow(n, {total_amount: e.target.value === '' ? null : Number(e.target.value), estimated: false})}/>{r.estimated && <small>Estimado: parcela × {r.count}. Ajuste se souber o total exato.</small>}</label>}
      </div>}
    </li>
  );

  return <dialog className="account-dialog statement-dialog" ref={dialog} aria-label="Importar fatura" onCancel={e => {if (busy) e.preventDefault(); else onClose()}}>
    <header className="import-header"><h2>Importar fatura · {card.name}</h2><button type="button" className="link-button" disabled={busy} onClick={onClose}>Fechar</button></header>
    <datalist id="import-categories">{categories.filter(c => c.kind === 'expense' && c.active).map(c => <option key={c.name} value={c.name}/>)}<option value="Encargos"/></datalist>

    {!draft && <section className="import-pick">
      <label className="file-drop">
        <span>{busy ? (progress || 'Lendo arquivo…') : 'Escolha o PDF da fatura'}</span>
        <small>PDF (com ou sem senha), CSV ou OFX. Nada é gravado antes da sua confirmação.</small>
        <input aria-label="Arquivo da fatura" type="file" accept=".pdf,.csv,.ofx" disabled={busy} onChange={e => {const f = e.target.files?.[0]; e.target.value = ''; if (f) void read(f)}}/>
      </label>
      {passwordNeeded && <form className="import-password" onSubmit={e => {e.preventDefault(); passwordReply.current?.({password, save: savePassword}); setPassword('')}}>
        <h3>PDF protegido</h3>
        <label>Senha do PDF<input type="password" autoFocus autoComplete="off" value={password} onChange={e => setPassword(e.target.value)}/></label>
        <label className="check"><input type="checkbox" checked={savePassword} onChange={e => setSavePassword(e.target.checked)}/>Lembrar a senha deste cartão (fica criptografada)</label>
        <div className="button-row"><button disabled={!password}>Abrir</button><button type="button" onClick={() => passwordReply.current?.(null)}>Cancelar</button></div>
      </form>}
      {done && <p role="status" className="import-done">{done}</p>}
    </section>}

    {draft && totals && <section className="import-review">
      <p className="muted">{draft.header.bankLabel} · {draft.fileName}{draft.header.last4 && ' · final ' + draft.header.last4}</p>
      {duplicateFile && <p className="warning">Este arquivo já tem uma importação ativa neste cartão. Se ela não tiver mais lançamentos, será liberada automaticamente ao importar; se tiver, desfaça-a antes no histórico.</p>}

      <label className="import-reference">Fatura de referência (mês do vencimento)
        <select value={draft.cycle} onChange={e => {requestId.current = crypto.randomUUID(); setDraft({...draft, cycle: e.target.value})}}>
          {options.map(o => <option key={o.cycle} value={o.cycle}>{o.label}{o.cycle === draft.suggestedCycle ? ' (sugerida)' : ''}</option>)}
        </select>
        <small>{draft.cycle === draft.suggestedCycle ? 'Sugerida ' + draft.reason + '.' : 'Você trocou a sugestão (fatura de ' + referenceLabel(invoices, root, draft.suggestedCycle) + ').'}{draft.header.due && selected?.due && selected.due !== draft.header.due && ` O PDF vence em ${dateBR(draft.header.due)}; esta fatura vence em ${dateBR(selected.due)} no app.`}</small>
      </label>

      <div className="import-totals">
        <div><span>Itens do PDF</span><strong>{brl(totals.items)}</strong></div>
        <div><span>Total impresso no PDF</span><strong>{totals.statementTotal === null ? '—' : brl(totals.statementTotal)}</strong></div>
        <div><span>Fatura no app após importar</span><strong>{brl(totals.after)}</strong></div>
        <div className={totals.adjustment ? 'has-difference' : 'no-difference'}><span>Diferença</span><strong>{totals.adjustment === null ? '—' : brl(totals.adjustment)}</strong></div>
      </div>
      {totals.adjustment !== null && totals.adjustment !== 0 && <label className="check import-adjust"><input type="checkbox" checked={draft.adjust} onChange={e => {requestId.current = crypto.randomUUID(); setDraft({...draft, adjust: e.target.checked})}}/>Ajustar a fatura para {brl(totals.statementTotal ?? 0)} (lança “{totals.adjustment > 0 ? 'Complemento' : 'Redução'} de Fatura” de {brl(totals.adjustment)}, desfeito junto com a importação)</label>}
      {totals.pdfDifference !== null && totals.pdfDifference !== 0 && <p className="muted">Os itens lidos somam {brl(totals.items)} e o PDF informa {brl(totals.statementTotal ?? 0)}. A diferença pode ser saldo anterior, pagamento parcial ou uma linha não reconhecida.</p>}

      {GROUPS.map(g => {const list = draft.rows.map((r, n) => [r, n] as const).filter(([r]) => r.group === g.id); return list.length > 0 && <details key={g.id} className={'import-group group-' + g.id} open={g.open}>
        <summary><b>{g.title}</b> <span className="count">{list.length}</span> <small>{g.hint}</small></summary>
        <ul>{list.map(([r, n]) => rowView(r, n))}</ul>
      </details>})}
      {totals.onlyInSystem.length > 0 && <details className="import-group"><summary><b>Só no app, nesta fatura</b> <span className="count">{totals.onlyInSystem.length}</span> <small>Lançamentos do app que não aparecem no PDF. Nada será alterado neles.</small></summary>
        <ul>{totals.onlyInSystem.map(l => <li key={l.id} className="import-row"><div className="import-row-main"><span className="import-date">{dateBR(l.charge_date).slice(0, 5)}</span><span className="import-desc">{l.title}</span><strong>{brl(Number(l.amount))}</strong></div></li>)}</ul>
      </details>}

      <footer className="import-footer">
        {waiting.length > 0 && <p role="status">Falta decidir {waiting.length} item(ns).</p>}
        <div className="button-row">
          <button disabled={busy || waiting.length > 0 || (newCount === 0 && !draft.adjust)} onClick={() => void confirm()}>{busy ? 'Importando…' : `Importar ${newCount} lançamento(s)`}</button>
          <button type="button" disabled={busy} onClick={() => setDraft(null)}>Escolher outro arquivo</button>
        </div>
      </footer>
    </section>}
    {error && <p role="alert" className="payment-error">{error}</p>}

    {!draft && <ManualAdjust db={db} household={household} data={data} invoices={invoices} reload={reload}/>}
    {!draft && <details className="import-history-box"><summary>Histórico de importações</summary><ImportHistory db={db} household={household} data={data} cardId={card.id} reload={reload} onChange={loadHistory}/></details>}
  </dialog>;
}

/** Ajuste manual do total de uma fatura (sem importar arquivo). */
function ManualAdjust({db, household, data, invoices, reload}: {db: SupabaseClient; household: string; data: CreditData; invoices: CreditData['invoices']; reload: () => Promise<void>}) {
  const closed = invoices.filter(i => i.closing_date <= today());
  const [invoice, setInvoice] = useState(closed[0]?.id ?? invoices[0]?.id ?? ''), [total, setTotal] = useState(''), [busy, setBusy] = useState(false), [error, setError] = useState('');
  const keys = useRef(new Map<string, string>());
  const selected = invoices.find(i => i.id === invoice), current = selected ? invoiceTotals(selected, data.lines).total : 0;
  async function save(action: 'adjust_invoice' | 'reverse_adjustment', payload: Record<string, unknown>, question: string) {
    if (!selected || !window.confirm(question)) return;
    const p = {invoice_id: selected.id, revision: selected.revision, ...payload}, signature = JSON.stringify([action, p]);
    let id = keys.current.get(signature); if (!id) {id = crypto.randomUUID(); keys.current.set(signature, id)}
    setBusy(true); setError('');
    try {const r = await db.rpc('cc_action', {p_id: id, p_household: household, p_action: action, p_data: p}); if (r.error) throw r.error; setTotal(''); await reload()} catch (e) {setError(errorMessage(e))} finally {setBusy(false)}
  }
  return <details className="manual-adjust"><summary>Ajustar o total de uma fatura manualmente</summary>
    <div className="form-grid">
      <label>Fatura<select value={invoice} onChange={e => setInvoice(e.target.value)}>{invoices.map(i => <option key={i.id} value={i.id}>Fatura de {cycleLabel(i.due_date)} · vence {dateBR(i.due_date)}</option>)}</select></label>
      <label>Total correto<input type="number" step=".01" value={total} placeholder={String(current)} onChange={e => setTotal(e.target.value)}/></label>
    </div>
    <p className="muted">No app: {brl(current)}{total !== '' && ` → ajuste de ${brl(Number(total) - current)}`}. Compras e pagamentos não mudam.</p>
    <button disabled={busy || !selected || total === ''} onClick={() => void save('adjust_invoice', {total: Number(total)}, 'Lançar ajuste de ' + brl(Number(total) - current) + ' nesta fatura?')}>Lançar ajuste</button>
    {data.lines.filter(l => l.invoice_id === invoice && l.line_type === 'adjustment').map(l => <p key={l.id} className="transaction"><span>{l.title} · {brl(Number(l.amount))}</span><button disabled={busy} onClick={() => void save('reverse_adjustment', {line_id: l.id}, 'Reverter este ajuste com um lançamento compensatório?')}>Reverter</button></p>)}
    {error && <p role="alert">{error}</p>}
  </details>;
}
