"use client";

import {useEffect,useMemo,useState,useRef} from "react";

import DuoLogo from "@/components/duo-logo";
import {Wallet,Plus,Home as HomeIcon,CalendarDays,ListChecks,Settings} from "lucide-react";
import {firstName,familyTitle} from "@/lib/identity";
import {Metrics,InvestmentBalance} from "@/components/finance-visuals";
import MovementList from "@/components/movement-list";
import MonthlyOverview from "@/components/monthly-overview";
import EventEditor from "@/components/event-editor";
import PaymentDialog,{type PaymentMode} from "@/components/payment-dialog";
import type {PropertyRecord} from "@/components/properties-panel";
import LoginPanel from "@/components/login-panel";
import AccountsPanel from "@/components/accounts-panel";
import {uniqueEvents,propertyEquity,monthlyCashOutlook,type CreditCard,type ViewAccount,type ViewEvent} from "@/lib/finance-view";
import EntryForm from "@/components/entry-form";
import Preferences,{type Category} from "@/components/preferences";
import TransactionActions,{type TransactionMode} from '@/components/transaction-actions';
import CreditPanel,{CreditOverview,CreditOperationDialog,operationForEvent} from "@/components/credit-module";
import {emptyCredit,creditEvents,type CreditData,type Card} from "@/lib/credit";
import Planning from "@/components/planning";

import {errorMessage} from "@/lib/errors";

import {useViewState,usePagePosition} from "@/lib/use-view-state";

import {supabase} from "@/lib/supabase";

import {brl,today,type ScheduledTransfer} from "@/lib/money";

import type {User} from "@supabase/supabase-js";

type Account=ViewAccount;

type Event=ViewEvent;

type Member={user_id:string;display_name:string};

const tabs=[{id:'home',label:'Início',Icon:HomeIcon},{id:'pending',label:'Transações',Icon:ListChecks},{id:'planning',label:'Calendário',Icon:CalendarDays},{id:'accounts',label:'Contas',Icon:Wallet},{id:'preferences',label:'Mais',Icon:Settings}];

function FinanceApp(){
 const authCallback=useRef(typeof window!=='undefined'&&(new URL(window.location.href).searchParams.has('code')||new URLSearchParams(window.location.hash.slice(1)).get('type')==='recovery'));

 const [creditData,setCreditData]=useState<CreditData>(emptyCredit),[creditError,setCreditError]=useState(''),[creditOperation,setCreditOperation]=useState<ReturnType<typeof operationForEvent>>(null),[accountTab,setAccountTab]=useState('bank');
 const [cards,setCards]=useState<CreditCard[]>([]);
 const [scheduled,setScheduled]=useState<ScheduledTransfer[]>([]);
 const [categories,setCategories]=useState<Category[]>([]),[entryMode,setEntryMode]=useState<'expense'|'income'>('expense'),[quick,setQuick]=useState(false),[displayName,setDisplayName]=useState('');
 const [paymentDates,setPaymentDates]=useState<Record<string,string>>({}),[paymentAccounts,setPaymentAccounts]=useState<Record<string,string[]>>({}),[correction,setCorrection]=useState<Event|null>(null);
 const quickMenu=useRef<HTMLDivElement>(null),quickButton=useRef<HTMLButtonElement>(null);
 const [transactionVersion,setTransactionVersion]=useState(0),[txMode,setTxMode]=useState<TransactionMode>('');
 const [entryVersion,setEntryVersion]=useState(0),[transferRequest,setTransferRequest]=useState(0);
 const acting=useRef(false);
 const [dark,setDark]=useState(false);
 useEffect(()=>{const value=localStorage.getItem("financas-theme")==="dark";setDark(value);document.documentElement.classList.toggle("dark",value)},[]);
 const [user,setUser]=useState<User|null>(null);

 const [authReady,setAuthReady]=useState(false),[authError,setAuthError]=useState('');
 const [mainTab,setMainTab]=useViewState(user?`financas:view:${user.id}:main-tab`:null,'home',(v):v is string=>typeof v==='string'&&tabs.some(t=>t.id===v));
 const [moreSection,setMoreSection]=useViewState(user?`financas:view:${user.id}:more-section`:null,'entry',(v):v is string=>typeof v==='string'&&['entry','planning','history','preferences'].includes(v));
 const [membershipStatus,setMembershipStatus]=useState<"loading"|"ready"|"error">("loading");
 const [household,setHousehold]=useState<string|null>(null),[members,setMembers]=useState<Member[]>([]);

 const [accounts,setAccounts]=useState<Account[]>([]),[bankEvents,setEvents]=useState<Event[]>([]);



 const allPaymentDates=useMemo(()=>({...paymentDates,...Object.fromEntries(creditData.payments.filter(p=>!p.reversed_at).sort((a,b)=>a.paid_date.localeCompare(b.paid_date)).map(p=>['cc-invoice:'+p.invoice_id,p.paid_date])),...Object.fromEntries(creditData.purchases.filter(p=>p.obligation_id).map(p=>['cc-obligation:'+p.obligation_id,p.charge_date]))}),[paymentDates,creditData]);
 const events=useMemo(()=>uniqueEvents([...bankEvents,...creditEvents(creditData)]), [bankEvents,creditData]);
 const activeUser=useRef<string|null>(null),loadVersion=useRef(0);
 const retryKeys=useRef(new Map<string,string>());

 const requestKey=(signature:string)=>{let key=retryKeys.current.get(signature);if(!key){key=crypto.randomUUID();retryKeys.current.set(signature,key)}return key};

 const [properties,setProperties]=useState<PropertyRecord[]>([]);

 const [editing,setEditing]=useState<Event|null>(null);

 const [payment,setPayment]=useState<Event|null>(null),[paymentMode,setPaymentMode]=useState<PaymentMode>("confirm");

 const [invite,setInvite]=useState(""),[error,setError]=useState(""),[busy,setBusy]=useState(false);

 const db=useMemo(()=>supabase(),[]);

 async function load(u:User){
  const version=++loadVersion.current;
  if(activeUser.current!==u.id)return;

  try {
  const {data:member,error:me}=await db.from("household_members").select("household_id").eq("user_id",u.id).limit(1).maybeSingle();

  if(version!==loadVersion.current||activeUser.current!==u.id)return;
  if(me)throw me;

  const h=member?.household_id??null;setHousehold(h);setMembershipStatus("ready");

  if(!h)return;

  const auto=await db.rpc('confirm_due_income',{p_household:h});
  if(auto.error)throw auto.error;
  const [m,a,e]=await Promise.all([

   db.from("household_members").select("user_id,display_name").eq("household_id",h),

   db.from("financial_accounts").select("*").eq("household_id",h).eq("active",true).order("created_at"),

   db.from("financial_events").select("*").eq("household_id",h).order("due_date")

  ]);

  if(version!==loadVersion.current||activeUser.current!==u.id)return;
  for(const r of [m,a,e])if(r.error)setError(r.error.message);

  setMembers((m.data??[]).map(x=>({...x,display_name:firstName(x.display_name)})));setAccounts((a.data??[]).map(x=>({...x,balance:Number(x.balance)})));

  setEvents(uniqueEvents((e.data??[]).map(x=>({...x,amount:Number(x.amount)}))));

  const propertyResult=await db.from("properties").select("*").eq("household_id",h);if(version!==loadVersion.current||activeUser.current!==u.id)return;setProperties(propertyResult.data??[]);

  const cardResult=await db.from("credit_cards").select("*").eq("household_id",h);if(version!==loadVersion.current||activeUser.current!==u.id)return;if(cardResult.error)throw cardResult.error;setCards(cardResult.data??[]);
  try{
   const generated=await db.rpc('cc_generate',{p_household:h,p_through:new Date(new Date(today()+'T12:00:00Z').setUTCFullYear(new Date(today()+'T12:00:00Z').getUTCFullYear()+1)).toISOString().slice(0,10)});if(generated.error)throw generated.error;
   const tables=['cc_invoices','cc_obligations','cc_purchases','cc_lines','cc_payments','cc_recurrences'];
   const creditRows=await Promise.all(tables.map(t=>db.from(t).select('*').eq('household_id',h)));for(const row of creditRows)if(row.error)throw row.error;
   if(version!==loadVersion.current||activeUser.current!==u.id)return;
   setCreditData({cards:(cardResult.data??[]).map(c=>({...c,credit_limit:Number(c.credit_limit??0),closing_day:c.closing_day??5,due_day:c.due_day??15,card_status:c.card_status??'active',parent_card_id:c.parent_card_id??null,revision:Number(c.revision??0)})) as Card[],invoices:creditRows[0].data??[],obligations:creditRows[1].data??[],purchases:creditRows[2].data??[],lines:creditRows[3].data??[],payments:creditRows[4].data??[],recurrences:creditRows[5].data??[]});setCreditError('');
  }catch(e){setCreditError('Módulo de cartões indisponível. Aplique as migrations pendentes, incluindo 019. '+errorMessage(e))}
  const transfersResult=await db.from('scheduled_transfers').select('*').eq('household_id',h);if(version!==loadVersion.current||activeUser.current!==u.id)return;if(transfersResult.error)setError(errorMessage(transfersResult.error));else setScheduled(transfersResult.data??[]);
  const receiptRows=await db.from('event_payments').select('event_id,paid_date,account_id').eq('household_id',h).is('reversed_at',null).order('paid_date');if(version!==loadVersion.current||activeUser.current!==u.id)return;setPaymentDates(Object.fromEntries((receiptRows.data??[]).map(r=>[r.event_id,r.paid_date])));setPaymentAccounts((receiptRows.data??[]).reduce<Record<string,string[]>>((out,r)=>{if(!out[r.event_id])out[r.event_id]=[];if(!out[r.event_id].includes(r.account_id))out[r.event_id].push(r.account_id);return out},{}));
  const cats=await db.from('categories').select('*').eq('household_id',h).is('deleted_at',null);
  if(version!==loadVersion.current||activeUser.current!==u.id)return;
  if(cats.error)setError(errorMessage(cats.error));else setCategories((cats.data??[]).sort((a,b)=>a.name.localeCompare(b.name,'pt-BR',{sensitivity:'base'})));

  } catch(error) {
   if(version!==loadVersion.current||activeUser.current!==u.id)return;
   setError(errorMessage(error));setMembershipStatus("error");
  }

 }

 useEffect(()=>{
  let mounted=true,revision=0,callbackPending=authCallback.current,recovering=false;let callbackTimer:ReturnType<typeof setTimeout>|undefined;
  function restore(next:User|null){
   if(!mounted||callbackPending||recovering)return;
   if(activeUser.current!==next?.id){
    activeUser.current=next?.id??null;loadVersion.current++;setHousehold(null);setMembershipStatus("loading");setError("");setPaymentDates({});setPaymentAccounts({});setCorrection(null);setScheduled([]);setCategories([]);setProperties([]);setCards([]);setCreditData(emptyCredit());setCreditError('');setCreditOperation(null);setAccounts([]);setEvents([]);setMembers([]);setInvite("");setPayment(null);setEditing(null);retryKeys.current.clear();
    if(next)setTimeout(()=>{if(mounted)void load(next)},0);
   }
   setUser(next);setAuthReady(true);setAuthError('');
  }
  // A single session source prevents getUser network failures or late responses
  // from replacing a restored session during a reload or token renewal.
  const {data:listener}=db.auth.onAuthStateChange((event,session)=>{revision++;if(event==='PASSWORD_RECOVERY'&&session){recovering=true;try{sessionStorage.setItem('financas:password-recovery',session.user.id)}catch{}location.replace('/redefinir-senha');return}restore(session?.user??null)});
  const initialRevision=revision;
  if(callbackPending){void db.auth.initialize().then(({error})=>{if(!mounted||recovering)return;if(error){setAuthError(errorMessage(error));return}callbackTimer=setTimeout(()=>{if(!mounted||recovering)return;callbackPending=false;void db.auth.getSession().then(({data,error})=>{if(!mounted||recovering)return;if(error)setAuthError(errorMessage(error));else restore(data.session?.user??null)})},0)})}
  else db.auth.getSession().then(({data,error})=>{
   if(!mounted||revision!==initialRevision)return;
   if(error){setAuthError(errorMessage(error));return}
   restore(data.session?.user??null);
  }).catch(error=>{if(mounted&&revision===initialRevision)setAuthError(errorMessage(error))});
  return ()=>{mounted=false;if(callbackTimer)clearTimeout(callbackTimer);loadVersion.current++;listener.subscription.unsubscribe()}
 },[db]);

 useEffect(()=>{
  if(!quick)return;
  const outside=(event:PointerEvent|FocusEvent)=>{const target=event.target;if(target instanceof Node&&!quickMenu.current?.contains(target)&&!quickButton.current?.contains(target))setQuick(false)};
  const escape=(event:KeyboardEvent)=>{if(event.key==='Escape'){setQuick(false);quickButton.current?.focus()}};
  document.addEventListener('pointerdown',outside,true);document.addEventListener('focusin',outside);document.addEventListener('keydown',escape);
  return()=>{document.removeEventListener('pointerdown',outside,true);document.removeEventListener('focusin',outside);document.removeEventListener('keydown',escape)};
 },[quick]);
 useEffect(()=>{if(!user||!household)return;const refresh=()=>{if(document.visibilityState==='visible'&&!acting.current)void load(user)};const interval=setInterval(refresh,60000);document.addEventListener('visibilitychange',refresh);return()=>{clearInterval(interval);document.removeEventListener('visibilitychange',refresh)}},[user?.id,household]);
 useEffect(()=>{document.title=members.length?"Duo · "+familyTitle(members):"Duo"},[members]);
 useEffect(()=>{if(!correction)return;const previous=document.activeElement as HTMLElement|null;const modal=document.querySelector<HTMLElement>('[role="dialog"]');const focusable=()=>Array.from(modal?.querySelectorAll<HTMLElement>('button:not(:disabled),input,select')??[]);focusable()[0]?.focus();const handle=(e:KeyboardEvent)=>{if(e.key==='Escape'){setCorrection(null)}if(e.key==='Tab'){const items=focusable(),first=items[0],last=items.at(-1);if(e.shiftKey&&document.activeElement===first){e.preventDefault();last?.focus()}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus()}}};document.addEventListener('keydown',handle);return()=>{document.removeEventListener('keydown',handle);previous?.focus()}},[correction]);
 usePagePosition(user&&household&&members.length?`financas:view:${user.id}:${household}:${mainTab}:scroll`:null);
 const outlook=monthlyCashOutlook(accounts,events,scheduled);

 async function act(fn:()=>Promise<void>){if(acting.current)return;acting.current=true;setBusy(true);setError("");try{await fn()}catch(e){setError(errorMessage(e))}finally{acting.current=false;setBusy(false)}}

 function navigate(tab:string){setMainTab(tab);window.scrollTo({top:0,behavior:'instant'})}
 function openCredit(e:Event){const op=operationForEvent(e);if(op)setCreditOperation(op);else{setAccountTab('credit');navigate('accounts')}}
 function openPay(e:Event){if(e.source){openCredit(e);return}setPaymentMode("confirm");setPayment(e)}
 function openExpenseCorrection(e:Event){setPaymentMode("correct");setPayment(e)}
 function openUndo(e:Event){if(e.source){openCredit(e);return}setPaymentMode("undo");setPayment(e)}
 function openEdit(e:Event){setEditing(e)}
 function openCorrection(e:Event){setCorrection(e)}
 async function createHousehold(){if(!user)return;await act(async()=>{const {error}=await db.rpc("create_household",{p_name:"Nossa família",p_display_name:displayName.trim()||firstName(String(user.user_metadata?.full_name??user.user_metadata?.name??"Participante"))});if(error)throw error;await load(user)})}

 async function inviteMember(){if(!user)return;await act(async()=>{const {data,error}=await db.rpc("accept_invite",{p_code:invite.trim(),p_name:displayName.trim()||firstName(String(user.user_metadata?.full_name??user.user_metadata?.name??"Participante"))});if(error)throw error;if(!data)throw new Error("Convite inválido, expirado, revogado ou limite de tentativas atingido. Tente mais tarde.");await load(user)})}

 if(!authReady)return <main className="card max-w-lg mx-auto p-8 mt-16" aria-live="polite"><h1>Duo</h1>{authError?<><p role="alert">Não foi possível restaurar sua sessão. {authError}</p><button onClick={()=>location.reload()}>Tentar novamente</button></>:<p>Restaurando sua sessão…</p>}</main>;

 if(!user)return <LoginPanel db={db} onLogin={async next=>{activeUser.current=next.id;setUser(next);await load(next)}}/>;

 if(membershipStatus!=="ready")return <main className="max-w-lg mx-auto p-8 space-y-5" aria-live="polite"><h1 className="text-2xl font-bold">Duo</h1>{membershipStatus==="loading"?<p>Carregando sua família…</p>:<><p role="alert">Não foi possível consultar seu núcleo familiar. {error}</p><button disabled={busy} onClick={()=>act(async()=>{setMembershipStatus("loading");await load(user)})}>Tentar novamente</button><button onClick={()=>db.auth.signOut()}>Sair</button></>}</main>;

 if(!household)return <main className="max-w-lg mx-auto p-8 space-y-5"><h1 className="text-2xl font-bold">Bem-vindo!</h1><div className="card space-y-3"><label>Seu nome<input required value={displayName} onChange={e=>setDisplayName(e.target.value)} placeholder="Nome de exibição" maxLength={120}/></label><p>Crie seu núcleo familiar:</p><button onClick={createHousehold} disabled={busy||!displayName.trim()}>Criar família</button></div><div className="card space-y-3"><p>Ou entre usando o código compartilhado pelo parceiro:</p><input placeholder="Código de convite" value={invite} onChange={e=>setInvite(e.target.value)}/><button disabled={busy} onClick={inviteMember}>Entrar na família</button></div>{error&&<p role="alert" className="text-red-700">{error}</p>}</main>;

 return <main data-screen={mainTab} className="app-shell max-w-6xl mx-auto p-4 md:p-8 space-y-6">

 <header id="home" className="app-header"><div><span className="brand-mark"><DuoLogo size={28}/><span>Duo</span></span><h1>{familyTitle(members)}</h1></div><div className="header-actions"><button aria-label="Alternar tema" onClick={()=>{const value=!dark;setDark(value);localStorage.setItem("financas-theme",value?"dark":"light");document.documentElement.classList.toggle("dark",value)}}>{dark?"Modo claro":"Modo escuro"}</button><button onClick={()=>db.auth.signOut()}>Sair</button></div></header>
 {error&&<div role="alert" className="card text-red-700">{error}</div>}
 <div role="tabpanel" id="screen-home" aria-labelledby="tab-home" hidden={mainTab!=='home'} className="tab-content space-y-5">
 <Metrics total={outlook.available} income={outlook.income} expense={outlook.expense} final={outlook.projected} until={outlook.through}/>

 <MovementList onCardAction={openCredit} cards={cards} mode="urgent" events={events} accounts={accounts} members={members} paymentDates={allPaymentDates} onPay={openPay} onEdit={openEdit} onCorrect={openCorrection} onExpenseCorrection={openExpenseCorrection} onUndo={openUndo}/>
 <MovementList onCardAction={openCredit} cards={cards} mode="history" events={events} accounts={accounts} members={members} paymentDates={allPaymentDates} onPay={openPay} onEdit={openEdit} onCorrect={openCorrection} onExpenseCorrection={openExpenseCorrection} onUndo={openUndo}/>
 <MonthlyOverview events={events} categories={categories} persistenceKey={"financas:view:"+user.id+":"+household}/>

 <CreditOverview data={creditData} members={members} legacy={bankEvents}/>
 <InvestmentBalance accounts={accounts.filter(a=>a.account_type==='investment')} members={members}/>

 <section className="card property-summary space-y-3" aria-label="Patrimônio em imóveis"><h2>Saldo aplicado em imóveis</h2><strong className="text-2xl">{brl(propertyEquity(properties))}</strong><p className="muted">Valor estimado dos imóveis próprios menos as dívidas. Patrimônio separado do saldo bancário disponível.</p>{properties.filter(p=>p.tenure==='owned').map(p=><article className="transaction" key={p.id}><div><h3>{p.name}</h3><small>{p.city}{p.payment_status==='financed'?` · ${p.pending_installments??0} parcelas pendentes`:''}</small></div><b>{brl(Number(p.estimated_value)-Number(p.debt??0))}</b></article>)}</section>
 </div>
 <div role="tabpanel" id="screen-pending" aria-labelledby="tab-pending" hidden={mainTab!=='pending'} className="tab-content"><TransactionActions key={transactionVersion} initialMode={txMode} db={db} household={household} userId={user.id} accounts={accounts} members={members} categories={categories} properties={properties} data={creditData} reload={()=>load(user)}/><MovementList onCardAction={openCredit} cards={cards} onCreate={()=>{setTxMode('expense');setTransactionVersion(v=>v+1)}} persistenceKey={"financas:view:"+user.id+":"+household} mode="pending" events={events} accounts={accounts} members={members} paymentDates={allPaymentDates} onPay={openPay} onEdit={openEdit} onCorrect={openCorrection} onExpenseCorrection={openExpenseCorrection} onUndo={openUndo}/></div>
 <div role="tabpanel" id="screen-planning" aria-labelledby="tab-planning" hidden={mainTab!=='planning'} className="tab-content">{mainTab==='planning'&&<Planning creditData={creditData} view="calendar" persistenceKey={user.id+household} transfers={scheduled} db={db} household={household} accounts={accounts} members={members} events={events} reload={()=>load(user)}/>}</div>
 <div role="tabpanel" id="screen-accounts" aria-labelledby="tab-accounts" hidden={mainTab!=='accounts'} className="tab-content"><CreditPanel legacy={bankEvents} db={db} household={household} data={creditData} accounts={accounts} members={members} categories={categories} reload={()=>load(user)} moduleError={creditError}/><AccountsPanel scheduled={scheduled} transferRequest={transferRequest} db={db} household={household} accounts={accounts} members={members} reload={()=>load(user)}/></div>
 <div role="tabpanel" id="screen-preferences" aria-labelledby="tab-preferences" hidden={mainTab!=='preferences'} className="tab-content space-y-5"><h2>Mais opções</h2><nav className="more-menu" aria-label="Opções adicionais">{[['entry','Lançamentos'],['planning','Planejamento'],['history','Histórico'],['preferences','Personalização']].map(([id,label])=><button key={id} aria-pressed={moreSection===id} onClick={()=>setMoreSection(id)}>{label}</button>)}</nav><div hidden={moreSection!=='entry'}>
 <EntryForm creditData={creditData} key={entryVersion} initialType={entryMode} cards={cards} db={db} household={household} userId={user.id} accounts={accounts} members={members} categories={categories} properties={properties} reload={()=>load(user)}/></div>
<div hidden={moreSection!=='planning'}>{mainTab==='preferences'&&moreSection==='planning'&&<Planning creditData={creditData} view="more" persistenceKey={user.id+household} transfers={scheduled} db={db} household={household} accounts={accounts} members={members} events={events} reload={()=>load(user)}/>}</div>
 <section hidden={moreSection!=='history'} className="card history"><h2>Histórico de confirmações</h2><p className="muted">Pagamentos e recebimentos já confirmados. Corrija o valor ou desfaça quando precisar.</p>{(()=>{const rows=events.filter(e=>!e.source&&Number(e.paid_amount)>0).sort((a,b)=>(paymentDates[b.id]??b.due_date).localeCompare(paymentDates[a.id]??a.due_date));return rows.length?<ul className="history-list">{rows.map(e=><li key={e.id} className="history-row"><span className="history-date">{(paymentDates[e.id]??e.due_date).split('-').reverse().join('/').slice(0,5)}</span><span className="history-main"><b>{e.title}</b><small><span className={'chip '+(e.kind==='income'?'ok':'late')}>{e.kind==='income'?'Recebimento':'Pagamento'}</span> {accounts.find(a=>a.id===e.account_id)?.name??''}{e.status!=='settled'?' · parcial':''}</small></span><strong className={'history-amount '+(e.kind==='income'?'positive':'negative')}>{brl(Number(e.paid_amount))}</strong><span className="history-actions"><button type="button" onClick={()=>e.kind==='income'?openCorrection(e):openExpenseCorrection(e)}>Corrigir</button><button type="button" disabled={busy} onClick={()=>openUndo(e)}>Desfazer</button></span></li>)}</ul>:<p className="muted">Nenhuma confirmação ainda.</p>})()}</section>
 <div hidden={moreSection!=='preferences'}><Preferences db={db} household={household} reload={()=>load(user)} categories={categories}/></div></div>
  {payment&&<PaymentDialog key={payment.id+paymentMode} db={db} event={payment} mode={paymentMode} accounts={accounts} previousAccounts={paymentAccounts[payment.id]??[]} paidDate={paymentDates[payment.id]} reload={()=>load(user)} onClose={()=>setPayment(null)}/>}


  {creditOperation&&<CreditOperationDialog key={JSON.stringify(creditOperation)} db={db} household={household} data={creditData} accounts={accounts} members={members} reload={()=>load(user)} operation={creditOperation} onClose={()=>setCreditOperation(null)}/>}
  {editing&&<EventEditor key={editing.id} db={db} event={editing} members={members} categories={categories} cards={cards} accounts={accounts} properties={properties} reload={()=>load(user)} onClose={()=>setEditing(null)}/>}




 {correction&&<section role="dialog" aria-modal="true" aria-label="Corrigir recebimento" className="card space-y-3"><h2>Corrigir: {correction.title}</h2><p className="muted">O ajuste preserva o recebimento anterior no histórico.</p><form className="space-y-3" onSubmit={e=>{e.preventDefault();const fd=new FormData(e.currentTarget);void act(async()=>{const params={p_event:correction.id,p_amount:Number(fd.get('amount')),p_date:String(fd.get('date')),p_expected:Number(correction.paid_amount)},signature=JSON.stringify(['correct',params]);const r=await db.rpc('correct_income',{p_id:requestKey(signature),...params});if(r.error)throw r.error;retryKeys.current.delete(signature);setCorrection(null);await load(user)})}}><label>Valor recebido<input name="amount" type="number" min=".01" step=".01" defaultValue={correction.paid_amount} required/></label><label>Data do recebimento<input name="date" type="date" max={today()} defaultValue={paymentDates[correction.id]??correction.due_date} required/></label><button disabled={busy}>Salvar correção</button><button type="button" onClick={()=>setCorrection(null)}>Cancelar</button></form></section>}
 <button ref={quickButton} className="quick-action" aria-label="Nova movimentação" aria-expanded={quick} onClick={()=>setQuick(!quick)}><Plus/></button>{quick&&<div ref={quickMenu} className="quick-menu card">{([['expense','Despesa avulsa'],['card','Lançar no cartão']] as const).map(([m,label])=><button key={m} onClick={()=>{setTxMode(m);setTransactionVersion(v=>v+1);navigate('pending');setQuick(false)}}>{label}</button>)}<button onClick={()=>{setEntryMode('income');setEntryVersion(v=>v+1);setMoreSection('entry');navigate('preferences');setQuick(false)}}>Receita</button><button onClick={()=>{setTransferRequest(n=>n+1);navigate('accounts');setQuick(false)}}>Transferência</button></div>}
 <nav className="bottom-nav" aria-label="Navegação principal" role="tablist">{tabs.map(({id,label,Icon},i)=><button role="tab" key={id} id={'tab-'+id} aria-controls={'screen-'+id} aria-selected={mainTab===id} tabIndex={mainTab===id?0:-1} onClick={()=>navigate(id)} onKeyDown={e=>{if(['ArrowLeft','ArrowRight','Home','End'].includes(e.key)){e.preventDefault();const index=e.key==='Home'?0:e.key==='End'?tabs.length-1:(i+(e.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length;navigate(tabs[index].id);document.getElementById('tab-'+tabs[index].id)?.focus()}}}><Icon size={20}/><span>{label}</span></button>)}</nav>
 </main>

}



export default function Home(){

 const [ready,setReady]=useState(false);

 useEffect(()=>setReady(true),[]);

 if(!process.env.NEXT_PUBLIC_SUPABASE_URL||!process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY)return <main className="card max-w-lg mx-auto mt-16"><h1>Duo</h1><p>Configure NEXT_PUBLIC_SUPABASE_URL e NEXT_PUBLIC_SUPABASE_ANON_KEY para conectar seu projeto Supabase.</p></main>;

 return ready?<FinanceApp/>:<main className="p-8" aria-live="polite">Carregando…</main>;

}

