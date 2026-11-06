"use client";
import {useEffect,useRef,useState} from 'react';
import type {SupabaseClient} from '@supabase/supabase-js';
import type {ViewAccount,ViewEvent} from '@/lib/finance-view';
import {brl,today} from '@/lib/money';import {errorMessage} from '@/lib/errors';
export type PaymentMode='confirm'|'correct'|'undo';
export default function PaymentDialog({db,event,mode,accounts,previousAccounts,paidDate,reload,onClose}:{db:SupabaseClient;event:ViewEvent;mode:PaymentMode;accounts:ViewAccount[];previousAccounts:string[];paidDate?:string;reload:()=>Promise<void>;onClose:()=>void}){
 const dialog=useRef<HTMLDialogElement>(null),lock=useRef(false),keys=useRef(new Map<string,string>());
 const remaining=(Math.round(Number(event.amount)*100)-Math.round(Number(event.paid_amount??0)*100))/100;
 const [account,setAccount]=useState(mode==='correct'?(previousAccounts.length===1?previousAccounts[0]:previousAccounts.length>1?'':event.account_id):event.account_id);
 const [amount,setAmount]=useState(String(mode==='correct'?Number(event.paid_amount):remaining)),[date,setDate]=useState(mode==='correct'?(paidDate??today()):today()),[partial,setPartial]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState('');
 useEffect(()=>{const el=dialog.current;if(el&&!el.open)el.showModal();return()=>{el?.close()}},[]);
 async function save(action:'confirm'|'correct'|'close'|'undo'){
  if(lock.current)return;lock.current=true;setBusy(true);setError('');
  const params={p_event:event.id,p_action:action,p_account:action==='close'||action==='undo'?null:account,p_amount:action==='close'||action==='undo'?null:Number(amount),p_date:action==='close'||action==='undo'?null:date,p_expected_version:event.edit_version??0,p_partial:action==='confirm'&&partial};
  const signature=JSON.stringify(params);let key=keys.current.get(signature);if(!key){key=crypto.randomUUID();keys.current.set(signature,key)}
  try{const result=await db.rpc('manage_event_payment',{p_id:key,...params});if(result.error)throw result.error;await reload();onClose()}catch(e){setError(errorMessage(e))}finally{lock.current=false;setBusy(false)}
 }
 const title=mode==='undo'?(event.kind==='income'?'Desfazer recebimento':'Desfazer pagamento'):mode==='correct'?'Corrigir pagamento':'Confirmar movimentação';
 return <dialog ref={dialog} className="account-dialog payment-dialog" aria-label={title} onCancel={e=>{if(busy)e.preventDefault();else onClose()}}>
  <h2>{title}</h2><h3>{event.title}</h3>
  {mode==='undo'?<div className="space-y-4"><p>{event.credit_state==='paid'?'A anotação voltará para “A pagar no cartão”, sem movimentar a conta.':event.kind==='income'?`O recebimento de ${brl(Number(event.paid_amount))} será retirado do saldo das contas em que foi registrado. A transação voltará a ficar pendente.`:`O pagamento de ${brl(Number(event.paid_amount))} será devolvido às contas em que foi registrado. A transação voltará a ficar pendente.`}</p><p className="muted">O histórico será preservado. Você poderá corrigir os dados e confirmar o pagamento novamente.</p><div className="button-row"><button disabled={busy} onClick={()=>void save('undo')}>Confirmar desfazer</button><button disabled={busy} onClick={onClose}>Cancelar</button></div></div>:<form className="space-y-4" onSubmit={e=>{e.preventDefault();void save(mode)}}>
   <p className="muted">{mode==='correct'?'Informe o total realmente pago. O pagamento anterior será estornado e substituído por este valor, sem duplicar o débito.':partial?'Somente parte do valor será paga; o restante continuará pendente.':'O valor efetivo quita este lançamento. A previsão será ajustada ao total realmente pago, sem deixar diferença pendente.'}</p>
   {mode==='confirm'&&Number(event.paid_amount)>0&&<section className="close-payment"><h3>Encerrar sem novo pagamento</h3><p className="muted">Se {brl(Number(event.paid_amount))} já é o total correto, encerre a transação sem outro débito.</p><button type="button" disabled={busy} onClick={()=>void save('close')}>Quitar pelo valor já pago · {brl(Number(event.paid_amount))}</button></section>}
   {mode==='correct'&&previousAccounts.length>1&&<p className="muted">Os pagamentos anteriores foram feitos em contas diferentes. Selecione a conta em que ficará o pagamento corrigido.</p>}
   <label>Conta efetiva<select required value={account} onChange={e=>setAccount(e.target.value)}><option value="">Selecione</option>{accounts.map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select></label>
   <label>{mode==='correct'?'Valor total pago':Number(event.paid_amount)>0?'Valor a pagar agora':'Valor efetivo'}<input autoFocus type="number" inputMode="decimal" min=".01" step=".01" max={mode==='confirm'&&partial?remaining:undefined} value={amount} required onChange={e=>setAmount(e.target.value)}/></label>
   <label>Data efetiva<input type="date" max={today()} required value={date} onChange={e=>setDate(e.target.value)}/></label>
   {mode==='confirm'&&<label className="check"><input type="checkbox" checked={partial} onChange={e=>setPartial(e.target.checked)}/>Pagamento parcial (manter restante pendente)</label>}
   <div className="button-row"><button disabled={busy}>{mode==='correct'?'Salvar correção':'Confirmar'}</button><button type="button" disabled={busy} onClick={onClose}>Cancelar</button></div>

  </form>}{error&&<p className="payment-error" role="alert">{error}</p>}
 </dialog>
}
