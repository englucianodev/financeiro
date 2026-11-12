"use client";
import {useRef,useState,useEffect,type FormEvent} from 'react';
import type {SupabaseClient} from '@supabase/supabase-js';
import {Wallet,Pencil} from 'lucide-react';
import {brl,today,type ScheduledTransfer} from '@/lib/money';
import {palette} from '@/lib/identity';
import {type ViewAccount} from '@/lib/finance-view';
import {errorMessage} from '@/lib/errors';

export default function AccountsPanel({db,household,accounts,members,reload,scheduled=[],transferRequest=0}:{scheduled?:ScheduledTransfer[];transferRequest?:number;db:SupabaseClient;household:string;accounts:ViewAccount[];members:{user_id:string;display_name:string}[];reload:()=>Promise<void>}){
 const dialog=useRef<HTMLDialogElement>(null),nameField=useRef<HTMLInputElement>(null),balanceField=useRef<HTMLInputElement>(null),transferField=useRef<HTMLInputElement>(null);
 const [editing,setEditing]=useState<ViewAccount|null>(null),[form,setForm]=useState(false),[balanceOnly,setBalanceOnly]=useState(false),[busy,setBusy]=useState(false),[error,setError]=useState('');
 const [view,setView]=useState<'details'|'transfer'>('details'),[transferHint,setTransferHint]=useState(false);
 const lock=useRef(false),keys=useRef(new Map<string,string>());
 useEffect(()=>{if(transferRequest)setTransferHint(true)},[transferRequest]);
 useEffect(()=>{
  const el=dialog.current;if(!el)return;
  if(form){if(!el.open)el.showModal();if(balanceOnly){balanceField.current?.focus();balanceField.current?.select()}else if(view==='transfer')transferField.current?.focus();else nameField.current?.focus()}
  else if(el.open)el.close();
 },[form,balanceOnly,view]);
 function open(account:ViewAccount|null,onlyBalance=false){setError('');setEditing(account?{...account}:null);setBalanceOnly(onlyBalance);setView(account&&!onlyBalance&&transferHint?'transfer':'details');if(account&&!onlyBalance)setTransferHint(false);setForm(true)}
 async function save(e:FormEvent<HTMLFormElement>){
  e.preventDefault();if(lock.current)return;
  const fd=new FormData(e.currentTarget),balance=Number(fd.get('balance'));
  const params={p_name:String(fd.get('name')),p_owner:String(fd.get('owner')),p_color:String(fd.get('color')),p_primary:fd.get('primary')==='on',p_type:String(fd.get('type')),p_balance:balance,p_expected_balance:editing?.balance??balance};
  const signature=JSON.stringify(balanceOnly?['balance',editing?.id,balance,editing?.balance]:[editing?.id??'new',params]);
  let key=keys.current.get(signature);if(!key){key=crypto.randomUUID();keys.current.set(signature,key)}
  lock.current=true;setBusy(true);setError('');
  try{
   if(balanceOnly){
    if(!editing)throw new Error('Selecione uma conta.');
    const r=await db.rpc('adjust_account_balance',{p_id:key,p_account:editing.id,p_balance:balance,p_expected_balance:editing.balance});if(r.error)throw r.error;
   }else{
    let account=editing?.id;
    if(!account){account=key;const r=await db.rpc('create_account',{p_id:account,p_household:household,p_owner:params.p_owner,p_name:params.p_name,p_balance:params.p_balance});if(r.error)throw r.error}
    const r=await db.rpc('save_account',{p_id:key,p_account:account,...params});if(r.error)throw r.error;
   }
   keys.current.delete(signature);await reload();setForm(false);setEditing(null);
  }catch(e){setError(errorMessage(e))}finally{lock.current=false;setBusy(false)}
 }
 async function send(e:FormEvent<HTMLFormElement>){
  e.preventDefault();if(lock.current||!editing)return;const fd=new FormData(e.currentTarget),to=String(fd.get('destination')),amount=Number(fd.get('transfer_amount')),date=String(fd.get('transfer_date'));
  const signature=JSON.stringify(['transfer',editing.id,to,amount,date]);let key=keys.current.get(signature);if(!key){key=crypto.randomUUID();keys.current.set(signature,key)}
  lock.current=true;setBusy(true);setError('');try{const future=date>today();const r=await db.rpc(future?'schedule_transfer':'transfer_funds',{p_from:editing.id,p_to:to,p_amount:amount,...(future?{p_id:key,p_date:date}:{p_key:key,p_date:date})});if(r.error)throw r.error;keys.current.delete(signature);await reload();setForm(false);setEditing(null)}catch(e){setError(errorMessage(e))}finally{lock.current=false;setBusy(false)}
 }
 async function confirmScheduled(id:string){if(lock.current)return;lock.current=true;setBusy(true);setError('');try{const r=await db.rpc('execute_transfer',{p_id:id});if(r.error)throw r.error;await reload()}catch(e){setError(errorMessage(e))}finally{lock.current=false;setBusy(false)}}
 return <section id="accounts" className="accounts-section">
  <div className="section-heading"><h2>Contas bancárias</h2><button className="btn sm" disabled={busy} onClick={()=>open(null)}>Nova conta</button></div>
  {transferHint&&<p role="status" className="muted">Toque em Editar na conta de origem para transferir.</p>}
  <div className="acct-grid">{accounts.map(a=><article key={a.id} className="bank-card acct-tile" style={{borderTopColor:a.color??palette[0]}}>
   <header><h3>{a.name}{a.is_primary&&<span className="acct-star" title="Conta principal">★</span>}</h3><small>{members.find(m=>m.user_id===a.owner_id)?.display_name} · {a.account_type==='investment'?'Investimento':a.account_type==='recurring'?'Despesas recorrentes':'Uso diário'}</small></header>
   <button className="balance-button" aria-label={'Ajustar saldo de '+a.name} title="Toque para ajustar o saldo" disabled={busy} onClick={()=>open(a,true)}><span className={a.balance<0?'negative':''}>{brl(a.balance)}</span><Pencil size={14}/></button>
   <div className="acct-actions"><button type="button" aria-label={'Editar conta '+a.name} disabled={busy} onClick={()=>open(a)}><Pencil size={15}/>Editar</button></div>
  </article>)}</div>
  <dialog ref={dialog} className="account-dialog" aria-label={balanceOnly?'Ajustar saldo':editing?'Editar conta':'Nova conta'} onCancel={e=>{if(busy)e.preventDefault();else setForm(false)}} onClose={()=>setForm(false)}>
   {form&&editing&&!balanceOnly&&<nav className="more-menu" aria-label="Opções da conta"><button disabled={busy} aria-pressed={view==='details'} onClick={()=>{setView('details');setError('')}}>Dados da conta</button><button disabled={busy} aria-pressed={view==='transfer'} onClick={()=>{setView('transfer');setError('')}}>Transferir</button></nav>}
   {form&&(balanceOnly||view==='details')&&<form key={(balanceOnly?'balance:':'account:')+(editing?.id??'new')} className={balanceOnly?'space-y-4':'form-grid'} onSubmit={save}>
    <h3 className="form-title">{balanceOnly?'Ajustar saldo · '+editing?.name:editing?'Editar conta':'Nova conta'}</h3>
    {!balanceOnly&&<><label>Nome da conta<input ref={nameField} autoFocus required name="name" placeholder="Nome da conta" defaultValue={editing?.name} maxLength={120}/></label><label>Titular<select name="owner" defaultValue={editing?.owner_id??members[0]?.user_id}>{members.map(m=><option key={m.user_id} value={m.user_id}>{m.display_name}</option>)}</select></label></>}
    <label>{balanceOnly?'Novo saldo':editing?'Saldo atual (ajuste auditado)':'Saldo inicial'}<input ref={balanceField} name="balance" type="number" inputMode="decimal" step=".01" required placeholder="Saldo inicial" defaultValue={editing?.balance}/></label>
    {!balanceOnly&&<><label>Finalidade<select name="type" defaultValue={editing?.account_type??'checking'}><option value="checking">Uso diário</option><option value="recurring">Despesas recorrentes</option><option value="investment">Investimentos</option></select></label><label>Cor de identificação<input name="color" type="color" defaultValue={editing?.color??palette[0]} list="account-colors"/></label><datalist id="account-colors">{palette.map(c=><option key={c}>{c}</option>)}</datalist><label className="check"><input type="checkbox" name="primary" defaultChecked={editing?.is_primary??false}/>Conta principal deste titular</label></>}
    <button disabled={busy}>{balanceOnly?'Salvar saldo':'Salvar conta'}</button><button type="button" disabled={busy} onClick={()=>setForm(false)}>Cancelar</button>
    <small className="block">{balanceOnly?'O ajuste será registrado no histórico da conta.':'Alterações de saldo geram ajuste no histórico. Contas com movimentações preservam seu titular.'}</small>
   </form>}
   {form&&editing&&!balanceOnly&&view==='transfer'&&<div className="space-y-4"><h3>Enviar de {accounts.find(a=>a.id===editing.id)?.name??editing.name}</h3><p className="muted">Saldo atual: {brl(accounts.find(a=>a.id===editing.id)?.balance??editing.balance)}</p><form className="space-y-3" onSubmit={send}><label>Valor da transferência<input ref={transferField} name="transfer_amount" type="number" inputMode="decimal" min=".01" step=".01" required/></label><label>Conta que vai receber<select aria-label="Conta que vai receber" name="destination" required>{accounts.filter(a=>a.id!==editing.id).map(a=><option key={a.id} value={a.id}>{a.name} · {members.find(m=>m.user_id===a.owner_id)?.display_name}</option>)}</select></label><label>Data da transferência<input name="transfer_date" type="date" defaultValue={today()} required/></label><small className="block muted">Hoje ou em data anterior, registra a transferência e atualiza os saldos. Datas futuras ficam agendadas.</small><button disabled={busy||accounts.length<2}>Enviar ou agendar</button><button disabled={busy} type="button" onClick={()=>setForm(false)}>Cancelar</button>{accounts.length<2&&<p>Cadastre outra conta para receber a transferência.</p>}</form>
   {scheduled.some(t=>t.from_account===editing.id&&t.status==='pending')&&<details><summary>Transferências agendadas desta conta</summary>{scheduled.filter(t=>t.from_account===editing.id&&t.status==='pending').sort((a,b)=>a.due_date.localeCompare(b.due_date)).map(t=><article className="transaction" key={t.id}><span>{t.due_date.split('-').reverse().join('/')} · {accounts.find(a=>a.id===t.to_account)?.name} · {brl(t.amount)}</span><button disabled={busy||t.due_date>today()} onClick={()=>confirmScheduled(t.id)}>Confirmar transferência</button></article>)}</details>}</div>}
   {error&&<p role="alert">{error}</p>}
  </dialog>
 </section>
}
