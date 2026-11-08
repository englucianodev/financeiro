"use client";
import {useCallback,useEffect,useRef,useState} from 'react';
import type {SupabaseClient} from '@supabase/supabase-js';
import type {CreditData} from '@/lib/credit';
import {brl} from '@/lib/money';
import {monthLabel} from '@/lib/finance-view';
import {errorMessage} from '@/lib/errors';
type ImportRecord={id:string;card_id:string;invoice_id:string;file_name:string;created_at:string;status:'active'|'undone';provenance_version:number;summary:{identified?:number;imported?:number;linked?:number;total?:number;rows?:{amount:number;decision:string}[]}};
type Impact={import_id:string;safe:boolean;reasons:string[];created_lines:number;created_purchases:number;linked_lines:number;invoice_ids:string[];bank_delta:number};
export default function ImportHistory({db,household,data,cardId,reload,onChange}:{db:SupabaseClient;household:string;data:CreditData;cardId?:string;reload:()=>Promise<void>;onChange?:()=>Promise<void>}){
 const [history,setHistory]=useState<ImportRecord[]>([]),[error,setError]=useState(''),[busy,setBusy]=useState(false),[preview,setPreview]=useState<Impact|null>(null);
 const lock=useRef(false),keys=useRef(new Map<string,string>());
 const load=useCallback(async()=>{let q=db.from('cc_imports').select('*').eq('household_id',household).order('created_at',{ascending:false});if(cardId)q=q.eq('card_id',cardId);const r=await q;if(r.error)throw r.error;setHistory(r.data??[])},[db,household,cardId]);
 useEffect(()=>{let active=true;void load().catch(e=>{if(active)setError(errorMessage(e))});return()=>{active=false}},[load,data]);
 async function act(action:'preview_undo_import'|'undo_import',id:string){
  if(lock.current)return;lock.current=true;setBusy(true);setError('');
  const payload={import_id:id,...(action==='undo_import'?{confirmed:true}:{})};const signature=JSON.stringify([action,payload]);let key=keys.current.get(signature);if(!key){key=crypto.randomUUID();keys.current.set(signature,key)}
  try{const r=await db.rpc('cc_action',{p_id:key,p_household:household,p_action:action,p_data:payload});if(r.error)throw r.error;
   if(action==='preview_undo_import')setPreview(r.data as Impact);else{setPreview(null);await reload();await load();await onChange?.()}
   keys.current.delete(signature);
  }catch(e){setError(errorMessage(e));if(action==='undo_import')setPreview(null)}finally{lock.current=false;setBusy(false)}
 }
 const invoiceText=(id:string)=>{const i=data.invoices.find(i=>i.id===id);return i?monthLabel(i.cycle.slice(0,7)):'Fatura não disponível'};
 return <section className="card space-y-3 import-history" aria-label="Histórico de importações"><h3>Histórico de importações</h3><p className="muted">O período exibido é o da importação original. Desfazer remove somente compras e parcelas cuja origem foi registrada com segurança; itens apenas vinculados são preservados.</p>
 {history.map(h=>{const total=h.summary.total??(h.summary.rows?h.summary.rows.filter(r=>r.decision==='new').reduce((s,r)=>s+Math.round(Number(r.amount)*100),0)/100:null);return <article className="credit-invoice" key={h.id}>
 <h4>{data.cards.find(c=>c.id===h.card_id)?.name??'Cartão anterior'} · {h.file_name}</h4>
 <p>Data: {new Date(h.created_at).toLocaleString('pt-BR',{timeZone:'America/Fortaleza'})} · Fatura: {invoiceText(h.invoice_id)}</p>
 <p>{h.summary.identified??0} lançamentos identificados · {h.summary.imported??0} importados · {h.summary.linked??0} vinculados · Total importado nesta fatura: {total===null?'Não informado (legado)':brl(Number(total))}</p>
 <p>Status: {h.status==='undone'?'Desfeita':h.provenance_version===1?'Concluída':'Revisão necessária (legado)'}</p><small>ID: {h.id}</small>
 {h.status!=='undone'&&<button disabled={busy} onClick={()=>void act('preview_undo_import',h.id)}>Desfazer importação</button>}
 </article>})}{!history.length&&<p>Nenhuma importação registrada.</p>}
 {preview&&<section role="group" aria-label="Revisar desfazimento da importação" className="credit-invoice"><h4>Impactos do desfazimento</h4>
 <p>{preview.created_purchases} compras e {preview.created_lines} lançamentos/parcelas criados serão removidos. {preview.linked_lines} registros preexistentes vinculados serão preservados.</p>
 <p>Faturas afetadas: {preview.invoice_ids.slice().sort((a,b)=>(data.invoices.find(i=>i.id===a)?.cycle??'').localeCompare(data.invoices.find(i=>i.id===b)?.cycle??'')).map(invoiceText).join(', ')||'Nenhuma identificada com segurança'}. Saldo bancário: sem alteração.</p>
 {preview.reasons.map(reason=><p role="alert" key={reason}>{reason}</p>)}
 {preview.safe&&<button disabled={busy} onClick={()=>{if(window.confirm('Desfazer integralmente esta importação, inclusive parcelas futuras e períodos retroativos? Somente os registros criados por ela serão removidos; o histórico e a auditoria serão preservados.'))void act('undo_import',preview.import_id)}}>Confirmar desfazimento integral</button>}
 <button disabled={busy} onClick={()=>setPreview(null)}>Cancelar desfazimento</button></section>}
 {error&&<p role="alert">{error}</p>}
 </section>;
}
