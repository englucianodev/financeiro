"use client";
import {useEffect,useRef,useState,type FormEvent} from 'react';
import type {SupabaseClient} from '@supabase/supabase-js';
import type {ViewAccount,ViewEvent} from '@/lib/finance-view';
import type {PropertyRecord} from './properties-panel';
import {errorMessage} from '@/lib/errors';

export default function EventEditor({db,event,accounts,properties,reload,onClose}:{db:SupabaseClient;event:ViewEvent;accounts:ViewAccount[];properties:PropertyRecord[];reload:()=>Promise<void>;onClose:()=>void}){
 const dialog=useRef<HTMLDialogElement>(null),lock=useRef(false),keys=useRef(new Map<string,string>());
 const [account,setAccount]=useState(accounts.some(a=>a.id===event.account_id&&a.owner_id===event.owner_id)?event.account_id:''),[amount,setAmount]=useState(String(event.amount)),[due,setDue]=useState(event.due_date);
 const [scope,setScope]=useState('single'),[changeRecurrence,setChangeRecurrence]=useState(false),[unit,setUnit]=useState('months'),[every,setEvery]=useState(1),[end,setEnd]=useState('');
 const [property,setProperty]=useState(event.property_id??''),[installment,setInstallment]=useState(event.is_property_installment??false);
 const [busy,setBusy]=useState(false),[error,setError]=useState(''),[confirmDelete,setConfirmDelete]=useState(false),[rulesReady,setRulesReady]=useState(false);
 const eligible=event.kind==='expense'&&properties.some(p=>p.id===property&&p.tenure==='owned'&&p.payment_status==='financed');
 useEffect(()=>{const el=dialog.current;if(el&&!el.open)el.showModal();return()=>{el?.close()}},[]);
 useEffect(()=>{let active=true;db.rpc('get_event_recurrence',{p_event:event.id}).then(({data,error})=>{if(!active)return;if(error){setError(errorMessage(error));return}if(data&&['once','days','months'].includes(data.unit)){setUnit(data.unit);setEvery(data.every??1);setEnd(data.end_date??'')}setRulesReady(true)});return()=>{active=false}},[db,event.id]);
 async function save(action:'edit'|'cancel'){
  if(lock.current)return;lock.current=true;setBusy(true);setError('');
  const params={p_event:event.id,p_scope:scope,p_action:action,p_account:account,p_amount:Number(amount),p_due:due,p_property:event.kind==='expense'?(property||null):null,p_installment:eligible&&installment,p_change_recurrence:changeRecurrence,p_unit:unit,p_every:every,p_end:end||null,p_expected_version:event.edit_version??0};
  const signature=JSON.stringify(params);let key=keys.current.get(signature);if(!key){key=crypto.randomUUID();keys.current.set(signature,key)}
  try{const r=await db.rpc('revise_events',{p_id:key,...params});if(r.error)throw r.error;await reload();onClose()}catch(e){setError(errorMessage(e))}finally{lock.current=false;setBusy(false)}
 }
 return <dialog ref={dialog} className="account-dialog" aria-label="Editar lançamento" onCancel={e=>{if(busy)e.preventDefault();else onClose()}}>
  <form className="form-grid" onSubmit={(e:FormEvent)=>{e.preventDefault();setConfirmDelete(false);void save('edit')}}>
   <h2 className="form-title">Editar · {event.title}</h2>
   <label>{event.kind==='expense'?'Conta que será debitada':'Conta de recebimento'}<select required value={account} onChange={e=>setAccount(e.target.value)}><option value="">Selecione uma conta</option>{accounts.filter(a=>a.owner_id===event.owner_id).map(a=><option value={a.id} key={a.id}>{a.name}</option>)}</select></label>
   <label>Valor<input type="number" inputMode="decimal" required min=".01" step=".01" value={amount} onChange={e=>setAmount(e.target.value)}/></label>
   <label>Vencimento<input type="date" required value={due} onChange={e=>setDue(e.target.value)}/></label>
   {event.kind==='expense'&&<><label>Imóvel vinculado<select value={property} onChange={e=>{setProperty(e.target.value);setInstallment(false)}}><option value="">Sem imóvel</option>{properties.map(p=><option value={p.id} key={p.id}>{p.name}</option>)}</select></label>{eligible&&<label className="check"><input type="checkbox" checked={installment} onChange={e=>setInstallment(e.target.checked)}/>Parcela do financiamento</label>}</>}
   <fieldset className="form-title space-y-2"><legend>Aplicar a alteração ou exclusão</legend><label className="check"><input name="scope" type="radio" checked={scope==='single'} onChange={()=>{setScope('single');setChangeRecurrence(false);setConfirmDelete(false)}}/>Só este lançamento</label><label className="check"><input name="scope" type="radio" checked={scope==='future'} onChange={()=>{setScope('future');setConfirmDelete(false)}}/>Este e os próximos</label></fieldset>
   <label className="check form-title"><input type="checkbox" disabled={!rulesReady} checked={changeRecurrence} onChange={e=>{setChangeRecurrence(e.target.checked);setConfirmDelete(false);if(e.target.checked)setScope('future')}}/>Alterar recorrência</label>
   {changeRecurrence&&<><p className="muted form-title">A nova recorrência começa neste vencimento. Os próximos lançamentos sem pagamento serão substituídos; os anteriores e os pagamentos registrados serão preservados.</p><label>Nova recorrência<select aria-label="Nova recorrência" value={unit} onChange={e=>setUnit(e.target.value)}><option value="once">Sem repetição</option><option value="months">A cada número de meses</option><option value="days">A cada número de dias</option></select></label>{unit!=='once'&&<><label>Intervalo<input type="number" min="1" max="365" required value={every} onChange={e=>setEvery(Number(e.target.value))}/></label><label>Repetir até (opcional)<input type="date" min={due} value={end} onChange={e=>setEnd(e.target.value)}/></label><small>Sem término: um ano de previsões.</small></>}</>}
   <button disabled={busy}>Salvar alterações</button><button type="button" disabled={busy} onClick={()=>setConfirmDelete(v=>!v)}>Excluir lançamento</button>
   {confirmDelete&&<section className="form-title space-y-3" aria-label="Confirmar exclusão"><p>{scope==='future'?'Excluir este lançamento e os próximos sem pagamento?':'Excluir somente este lançamento?'}</p><button type="button" disabled={busy} onClick={()=>void save('cancel')}>Confirmar exclusão</button><button type="button" disabled={busy} onClick={()=>setConfirmDelete(false)}>Voltar à edição</button></section>}
   <button type="button" disabled={busy} onClick={onClose}>Fechar</button><p className="muted form-title">Pagamentos já registrados e lançamentos parcialmente pagos não serão alterados.</p>
   {error&&<p role="alert" className="form-title">{error}</p>}
  </form>
 </dialog>
}
