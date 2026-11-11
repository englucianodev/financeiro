"use client";
import {useCallback, useEffect, useRef, useState} from 'react';
import type {SupabaseClient} from '@supabase/supabase-js';
import type {CreditData} from '@/lib/credit';
import {brl} from '@/lib/money';
import {monthLabel} from '@/lib/finance-view';
import {errorMessage} from '@/lib/errors';

type ImportRecord = {id: string; card_id: string; invoice_id: string; file_name: string; created_at: string; status: 'active' | 'undone'; provenance_version: number; effects?: Record<string, unknown>;
  summary: {identified?: number; imported?: number; linked?: number; total?: number; statement_total?: number | null; adjustment?: number | null; rows?: {amount: number; decision: string}[]}};
type Impact = {import_id: string; safe: boolean; reasons: string[]; warnings?: string[]; needs_confirmation?: boolean; orphan?: boolean; legacy?: boolean; remaining?: number;
  created_lines: number; created_purchases: number; linked_lines: number; invoice_ids: string[]; bank_delta: number};
type Action = 'preview_undo_import' | 'undo_import' | 'adopt_legacy_import' | 'force_clear_import';

export default function ImportHistory({db, household, data, cardId, reload, onChange}: {db: SupabaseClient; household: string; data: CreditData; cardId?: string; reload: () => Promise<void>; onChange?: () => Promise<void>}) {
  const [history, setHistory] = useState<ImportRecord[]>([]), [listError, setListError] = useState(''), [busy, setBusy] = useState(false);
  const [open, setOpen] = useState<string | null>(null), [preview, setPreview] = useState<Impact | null>(null), [error, setError] = useState(''), [accept, setAccept] = useState(false), [notice, setNotice] = useState('');
  const lock = useRef(false), keys = useRef(new Map<string, string>());
  const load = useCallback(async () => {
    let q = db.from('cc_imports').select('*').eq('household_id', household).order('created_at', {ascending: false});
    if (cardId) q = q.eq('card_id', cardId);
    const r = await q; if (r.error) throw r.error; setHistory(r.data ?? []);
  }, [db, household, cardId]);
  useEffect(() => {let active = true; void load().catch(e => {if (active) setListError(errorMessage(e))}); return () => {active = false}}, [load, data]);

  async function act(action: Action, id: string, extra: Record<string, unknown> = {}) {
    if (lock.current) return; lock.current = true; setBusy(true); setError(''); setNotice('');
    const payload = {import_id: id, ...extra}, signature = JSON.stringify([action, payload]);
    let key = keys.current.get(signature); if (!key) {key = crypto.randomUUID(); keys.current.set(signature, key)}
    try {
      const r = await db.rpc('cc_action', {p_id: key, p_household: household, p_action: action, p_data: payload});
      if (r.error) throw r.error;
      keys.current.delete(signature);
      if (action === 'preview_undo_import' || action === 'adopt_legacy_import') {setPreview(r.data as Impact); setAccept(false)}
      else {
        setPreview(null); setOpen(null);
        setNotice(action === 'force_clear_import' ? 'Importação retirada do histórico ativo. O arquivo pode ser importado de novo.' : 'Importação desfeita. O arquivo pode ser importado de novo.');
        await reload(); await load(); await onChange?.();
      }
    } catch (e) {
      const message = errorMessage(e);
      // Banco sem as migrations novas: a ação não existe e antes o erro passava despercebido.
      setError(/Operação inválida|Could not find|does not exist/i.test(message) ? 'O banco ainda não tem a atualização de importações (migrations 023 a 026). Aplique-as no Supabase e tente de novo.' : message);
    } finally {lock.current = false; setBusy(false)}
  }

  function start(id: string) {setOpen(id); setPreview(null); setError(''); setNotice(''); void act('preview_undo_import', id)}
  const invoiceText = (id: string) => {const i = data.invoices.find(i => i.id === id); return i ? monthLabel(i.cycle.slice(0, 7)) : 'Fatura não disponível'};
  const unique = (list: string[] = []) => Array.from(new Set(list));

  return <section className="card space-y-3 import-history" aria-label="Histórico de importações">
    <h3>Histórico de importações</h3>
    {notice && <p role="status" className="import-done">{notice}</p>}
    {history.map(h => {
      const total = h.summary.total ?? (h.summary.rows ? h.summary.rows.filter(r => r.decision === 'new').reduce((s, r) => s + Math.round(Number(r.amount) * 100), 0) / 100 : null);
      const cleared = Boolean(h.effects?.force_cleared || h.effects?.released_orphan);
      return <article className="credit-invoice" key={h.id}>
        <h4>{data.cards.find(c => c.id === h.card_id)?.name ?? 'Cartão anterior'} · {h.file_name}</h4>
        <p>Importada em {new Date(h.created_at).toLocaleString('pt-BR', {timeZone: 'America/Fortaleza'})} · Fatura: {invoiceText(h.invoice_id)}</p>
        <p>{h.summary.imported ?? 0} lançados · {h.summary.linked ?? 0} já existentes · Total: {total === null ? '—' : brl(Number(total))}{h.summary.statement_total != null && ' · PDF: ' + brl(Number(h.summary.statement_total))}{h.summary.adjustment != null && ' · Ajuste: ' + brl(Number(h.summary.adjustment))}</p>
        <p>Situação: <b>{h.status === 'undone' ? (cleared ? 'Limpa (sem lançamentos)' : 'Desfeita') : 'Ativa'}</b></p>
        {h.status !== 'undone' && open !== h.id && <button disabled={busy} onClick={() => start(h.id)}>Desfazer importação</button>}

        {open === h.id && <section role="group" aria-label="Desfazer importação" className="undo-panel">
          {busy && !preview && <p>Conferindo o que será removido…</p>}
          {preview && <>
            {preview.orphan ? <p>Esta importação não tem mais lançamentos no app (foram apagados). Ela só está travando a reimportação do arquivo.</p>
              : <p>Serão removidos {preview.created_lines} lançamento(s)/parcela(s) e {preview.created_purchases} compra(s) criados por esta importação. {preview.linked_lines > 0 && `${preview.linked_lines} lançamento(s) que já existiam serão mantidos. `}Faturas: {preview.invoice_ids.map(invoiceText).join(', ') || '—'}. Saldo bancário não muda.</p>}
            {unique(preview.reasons).filter(r => !(preview.legacy && /antiga/.test(r))).map(r => <p role="alert" key={r}>{r}</p>)}
            {preview.legacy && <p className="muted">Importação feita antes da atualização. Para desfazer, primeiro identifique os lançamentos pelo registro da própria importação (nada é buscado pela descrição).</p>}
            {unique(preview.warnings).map(w => <p className="warning" key={w}>{w}</p>)}
            {preview.needs_confirmation && preview.safe && <label className="check"><input type="checkbox" checked={accept} onChange={e => setAccept(e.target.checked)}/>Entendi e quero desfazer mesmo assim</label>}
            <div className="button-row">
              {preview.legacy && h.status === 'active' && <button disabled={busy} onClick={() => void act('adopt_legacy_import', h.id)}>Identificar lançamentos</button>}
              {preview.orphan && <button disabled={busy} onClick={() => {if (window.confirm('Retirar esta importação do histórico ativo? Nenhum lançamento será apagado (não há nenhum).')) void act('force_clear_import', h.id, {confirmed: true})}}>Limpar do histórico</button>}
              {!preview.orphan && preview.safe && <button disabled={busy || (preview.needs_confirmation && !accept)} onClick={() => {if (window.confirm('Desfazer esta importação? Os lançamentos criados por ela serão removidos.')) void act('undo_import', h.id, {confirmed: true, ...(preview.needs_confirmation ? {confirm_warnings: true} : {})})}}>Confirmar desfazer</button>}
              <button disabled={busy} onClick={() => {setOpen(null); setPreview(null); setError('')}}>Cancelar</button>
            </div>
          </>}
          {error && <p role="alert" className="payment-error">{error}</p>}
        </section>}
      </article>;
    })}
    {!history.length && <p>Nenhuma importação registrada.</p>}
    {listError && <p role="alert">{listError}</p>}
  </section>;
}
