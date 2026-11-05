"use client";

import {useEffect,useMemo,useState,useRef} from "react";

import {Wallet,Plus,Home as HomeIcon,CalendarDays,ListChecks,Settings} from "lucide-react";
import {firstName,familyTitle} from "@/lib/identity";
import {Metrics,CashFlowChart,PeriodNav,AccountMark} from "@/components/finance-visuals";
import MovementList from "@/components/movement-list";
import LoginPanel from "@/components/login-panel";
import AccountsPanel from "@/components/accounts-panel";
import {dailyMovements,shiftDate,type ViewAccount} from "@/lib/finance-view";
import EntryForm from "@/components/entry-form";
import Preferences,{type Category} from "@/components/preferences";
import Planning from "@/components/planning";

import {errorMessage} from "@/lib/errors";

import {useViewState,validPeriod,validDate,usePagePosition} from "@/lib/use-view-state";

import {supabase} from "@/lib/supabase";

import {brl,project,today,transferSuggestions,transferFlows,type ScheduledTransfer} from "@/lib/money";

import type {User} from "@supabase/supabase-js";

type Account=ViewAccount;

type Event={id:string;title:string;amount:number;paid_amount:number;category?:string;property_id?:string;card_id?:string;due_date:string;account_id:string;owner_id:string;status:string;kind:"income"|"expense"};

type Member={user_id:string;display_name:string};

const tabs=[{id:'home',label:'Início',Icon:HomeIcon},{id:'pending',label:'Pendências',Icon:ListChecks},{id:'planning',label:'Calendário',Icon:CalendarDays},{id:'accounts',label:'Contas',Icon:Wallet},{id:'preferences',label:'Mais',Icon:Settings}];
const dateLabel=(d:string)=>d.split("-").reverse().join("/");

function FinanceApp(){
 const authCallback=useRef(typeof window!=='undefined'&&(new URL(window.location.href).searchParams.has('code')||new URLSearchParams(window.location.hash.slice(1)).get('type')==='recovery'));

 const [scheduled,setScheduled]=useState<ScheduledTransfer[]>([]);
 const [categories,setCategories]=useState<Category[]>([]),[entryMode,setEntryMode]=useState<'expense'|'income'>('expense'),[quick,setQuick]=useState(false),[displayName,setDisplayName]=useState('');
 const [investmentsTotal,setInvestmentsTotal]=useState(0),[paymentDates,setPaymentDates]=useState<Record<string,string>>({}),[correction,setCorrection]=useState<Event|null>(null);
 const quickMenu=useRef<HTMLDivElement>(null),quickButton=useRef<HTMLButtonElement>(null);
 const [entryVersion,setEntryVersion]=useState(0),[transferRequest,setTransferRequest]=useState(0);
 const acting=useRef(false);
 const [dark,setDark]=useState(false);
 useEffect(()=>{const value=localStorage.getItem("financas-theme")==="dark";setDark(value);document.documentElement.classList.toggle("dark",value)},[]);
 const [user,setUser]=useState<User|null>(null);

 const [authReady,setAuthReady]=useState(false),[authError,setAuthError]=useState('');
 const [period,setPeriod]=useViewState(user?`financas:view:${user.id}:dashboard-period`:null,0,validPeriod);
 const [mainTab,setMainTab]=useViewState(user?`financas:view:${user.id}:main-tab`:null,'home',(v):v is string=>typeof v==='string'&&tabs.some(t=>t.id===v));
 const [moreSection,setMoreSection]=useViewState(user?`financas:view:${user.id}:more-section`:null,'entry',(v):v is string=>typeof v==='string'&&['entry','planning','history','preferences'].includes(v));
 const [projectionEnd,setProjectionEnd]=useViewState(user?`financas:view:${user.id}:projection-end`:null,shiftDate(today(),179),validDate);
 const [membershipStatus,setMembershipStatus]=useState<"loading"|"ready"|"error">("loading");
 const [household,setHousehold]=useState<string|null>(null),[members,setMembers]=useState<Member[]>([]);

 const [accounts,setAccounts]=useState<Account[]>([]),[events,setEvents]=useState<Event[]>([]);



 const activeUser=useRef<string|null>(null),loadVersion=useRef(0);
 const retryKeys=useRef(new Map<string,string>());

 const requestKey=(signature:string)=>{let key=retryKeys.current.get(signature);if(!key){key=crypto.randomUUID();retryKeys.current.set(signature,key)}return key};

 const [properties,setProperties]=useState<{id:string;name:string}[]>([]);

 const [paidValue,setPaidValue]=useState(""),[paidDate,setPaidDate]=useState(today()),[editing,setEditing]=useState<Event|null>(null),[editAmount,setEditAmount]=useState(""),[editDue,setEditDue]=useState(today());

 const [payment,setPayment]=useState<Event|null>(null),[paymentAccount,setPaymentAccount]=useState("");

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

  setEvents((e.data??[]).map(x=>({...x,amount:Number(x.amount)})));

  const propertyResult=await db.from("properties").select("id,name").eq("household_id",h);if(version!==loadVersion.current||activeUser.current!==u.id)return;setProperties(propertyResult.data??[]);

  const transfersResult=await db.from('scheduled_transfers').select('*').eq('household_id',h);if(version!==loadVersion.current||activeUser.current!==u.id)return;if(transfersResult.error)setError(errorMessage(transfersResult.error));else setScheduled(transfersResult.data??[]);
  const receiptRows=await db.from('event_payments').select('event_id,paid_date').eq('household_id',h).is('reversed_at',null).order('paid_date');if(version!==loadVersion.current||activeUser.current!==u.id)return;setPaymentDates(Object.fromEntries((receiptRows.data??[]).map(r=>[r.event_id,r.paid_date])));
  const investmentRows=await db.from('investments').select('amount').eq('household_id',h);if(version!==loadVersion.current||activeUser.current!==u.id)return;setInvestmentsTotal((investmentRows.data??[]).reduce((n,r)=>n+Number(r.amount),0));
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
    activeUser.current=next?.id??null;loadVersion.current++;setHousehold(null);setMembershipStatus("loading");setError("");setPaymentDates({});setInvestmentsTotal(0);setCorrection(null);setScheduled([]);setCategories([]);setProperties([]);setAccounts([]);setEvents([]);setMembers([]);setInvite("");setPayment(null);setEditing(null);retryKeys.current.clear();
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
 useEffect(()=>{if(members.length)document.title=familyTitle(members)},[members]);
 useEffect(()=>{if(!payment&&!editing&&!correction)return;const previous=document.activeElement as HTMLElement|null;const modal=document.querySelector<HTMLElement>('[role="dialog"]');const focusable=()=>Array.from(modal?.querySelectorAll<HTMLElement>('button:not(:disabled),input,select')??[]);focusable()[0]?.focus();const handle=(e:KeyboardEvent)=>{if(e.key==='Escape'){setPayment(null);setEditing(null);setCorrection(null)}if(e.key==='Tab'){const items=focusable(),first=items[0],last=items.at(-1);if(e.shiftKey&&document.activeElement===first){e.preventDefault();last?.focus()}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus()}}};document.addEventListener('keydown',handle);return()=>{document.removeEventListener('keydown',handle);previous?.focus()}},[payment,editing,correction]);
 usePagePosition(user&&household&&members.length?`financas:view:${user.id}:${household}:${mainTab}:scroll`:null);
 const cashAccounts=accounts.filter(a=>a.account_type!=='investment');
 const pending=events.filter(e=>e.status==="pending"),total=cashAccounts.reduce((s,a)=>s+a.balance,0);
 const flows=[...transferFlows(scheduled),...pending.map(e=>({...e,amount:(e.kind==='income'?1:-1)*(Number(e.amount)-Number(e.paid_amount??0))}))];

 const projection=project(cashAccounts,flows,365);
 const periodRows=projection.slice(period*30,period*30+30);

 const limitedProjection=projection.filter(r=>r.date<=projectionEnd);
 const suggestions=transferSuggestions(cashAccounts,limitedProjection);
 const deficit=limitedProjection.find(p=>Object.values(p.byAccount).some(v=>v<0));

 async function act(fn:()=>Promise<void>){if(acting.current)return;acting.current=true;setBusy(true);setError("");try{await fn()}catch(e){setError(errorMessage(e))}finally{acting.current=false;setBusy(false)}}

 function navigate(tab:string){setMainTab(tab);window.scrollTo({top:0,behavior:'instant'})}
 function openPay(e:Event){setPayment(e);setPaymentAccount(e.account_id);setPaidValue(String(Number(e.amount)-Number(e.paid_amount??0)));setPaidDate(today())}
 function openEdit(e:Event){setEditing(e);setEditAmount(String(e.amount));setEditDue(e.due_date)}
 function openCorrection(e:Event){setCorrection(e)}
 async function createHousehold(){if(!user)return;await act(async()=>{const {error}=await db.rpc("create_household",{p_name:"Nossa família",p_display_name:displayName.trim()||firstName(String(user.user_metadata?.full_name??user.user_metadata?.name??"Participante"))});if(error)throw error;await load(user)})}

 async function pay(e:Event){if(!user)return;await act(async()=>{

 const signature=JSON.stringify([e.id,paymentAccount,paidValue,paidDate,e.paid_amount]);const {error}=await db.rpc("pay_event",{p_id:requestKey(signature),p_event:e.id,p_account:paymentAccount||e.account_id,p_amount:Number(paidValue),p_date:paidDate,p_expected_paid:Number(e.paid_amount??0)});if(error)throw error;retryKeys.current.delete(signature);setPayment(null);await load(user)})}

 async function inviteMember(){if(!user)return;await act(async()=>{const {data,error}=await db.rpc("accept_invite",{p_code:invite.trim(),p_name:displayName.trim()||firstName(String(user.user_metadata?.full_name??user.user_metadata?.name??"Participante"))});if(error)throw error;if(!data)throw new Error("Convite inválido, expirado, revogado ou limite de tentativas atingido. Tente mais tarde.");await load(user)})}

 if(!authReady)return <main className="card max-w-lg mx-auto p-8 mt-16" aria-live="polite"><h1>Finanças a Dois</h1>{authError?<><p role="alert">Não foi possível restaurar sua sessão. {authError}</p><button onClick={()=>location.reload()}>Tentar novamente</button></>:<p>Restaurando sua sessão…</p>}</main>;

 if(!user)return <LoginPanel db={db} onLogin={async next=>{activeUser.current=next.id;setUser(next);await load(next)}}/>;

 if(membershipStatus!=="ready")return <main className="max-w-lg mx-auto p-8 space-y-5" aria-live="polite"><h1 className="text-2xl font-bold">Finanças a Dois</h1>{membershipStatus==="loading"?<p>Carregando sua família…</p>:<><p role="alert">Não foi possível consultar seu núcleo familiar. {error}</p><button disabled={busy} onClick={()=>act(async()=>{setMembershipStatus("loading");await load(user)})}>Tentar novamente</button><button onClick={()=>db.auth.signOut()}>Sair</button></>}</main>;

 if(!household)return <main className="max-w-lg mx-auto p-8 space-y-5"><h1 className="text-2xl font-bold">Bem-vindo!</h1><div className="card space-y-3"><label>Seu nome<input required value={displayName} onChange={e=>setDisplayName(e.target.value)} placeholder="Nome de exibição" maxLength={120}/></label><p>Crie seu núcleo familiar:</p><button onClick={createHousehold} disabled={busy||!displayName.trim()}>Criar família</button></div><div className="card space-y-3"><p>Ou entre usando o código compartilhado pelo parceiro:</p><input placeholder="Código de convite" value={invite} onChange={e=>setInvite(e.target.value)}/><button disabled={busy} onClick={inviteMember}>Entrar na família</button></div>{error&&<p role="alert" className="text-red-700">{error}</p>}</main>;

 return <main className="max-w-6xl mx-auto p-4 md:p-8 space-y-6">

 <header id="home" className="app-header"><div><span className="eyebrow"><Wallet size={16}/> NOSSO DINHEIRO, NOSSOS PLANOS</span><h1>{familyTitle(members)}</h1></div><div className="flex gap-2"><button aria-label="Alternar tema" onClick={()=>{const value=!dark;setDark(value);localStorage.setItem("financas-theme",value?"dark":"light");document.documentElement.classList.toggle("dark",value)}}>{dark?"Modo claro":"Modo escuro"}</button><button onClick={()=>db.auth.signOut()}>Sair</button></div></header>
 {error&&<div role="alert" className="card text-red-700">{error}</div>}
 <div role="tabpanel" id="screen-home" aria-labelledby="tab-home" hidden={mainTab!=='home'} className="tab-content space-y-5">
 <Metrics total={total} income={pending.filter(e=>e.kind==='income'&&e.due_date<=projection[29].date&&cashAccounts.some(a=>a.id===e.account_id)).reduce((n,e)=>n+Number(e.amount)-Number(e.paid_amount??0),0)} expense={pending.filter(e=>e.kind==='expense'&&e.due_date<=projection[29].date&&cashAccounts.some(a=>a.id===e.account_id)).reduce((n,e)=>n+Number(e.amount)-Number(e.paid_amount??0),0)} final={projection[29].total}/>
 <div className="balance-breakdown"><span>Uso diário <b>{brl(accounts.filter(a=>!a.account_type||a.account_type==='checking').reduce((n,a)=>n+a.balance,0))}</b></span><span>Contas de despesas recorrentes <b>{brl(accounts.filter(a=>a.account_type==='recurring').reduce((n,a)=>n+a.balance,0))}</b></span><small>Contas de investimento: {brl(accounts.filter(a=>a.account_type==='investment').reduce((n,a)=>n+a.balance,0))} · Investimentos cadastrados (informativo): {brl(investmentsTotal)}</small></div>
 <MovementList mode="urgent" events={events} accounts={accounts} members={members} paymentDates={paymentDates} onPay={openPay} onEdit={openEdit} onCorrect={openCorrection}/>
 <MovementList mode="history" events={events} accounts={accounts} members={members} paymentDates={paymentDates} onPay={openPay} onEdit={openEdit} onCorrect={openCorrection}/>
 <section id="projection" className="card"><h2>Seu dinheiro no tempo</h2><PeriodNav period={period} setPeriod={setPeriod} rows={periodRows}/><p className="muted">Entradas e saídas previstas por dia. Vermelho destaca dia com déficit em alguma conta disponível.</p><CashFlowChart rows={dailyMovements(periodRows,flows)}/><p>Saldo inicial: {brl(period===0?total:projection[period*30-1].total)} · Saldo final: {brl(periodRows.at(-1)?.total??total)}</p></section>
 <section className="card"><h2>Projeção e saldo necessário por conta</h2><label>Projetar até<input type="date" min={today()} max={projection.at(-1)?.date} value={projectionEnd} onChange={e=>{if(e.target.value>=today()&&e.target.value<=(projection.at(-1)?.date??''))setProjectionEnd(e.target.value)}}/></label><p className="muted">De {dateLabel(today())} a {dateLabel(projectionEnd)} · investimentos fora do disponível.</p>{cashAccounts.map(a=>{const minimum=Math.min(a.balance,...limitedProjection.map(p=>p.byAccount[a.id]??0));return <div key={a.id} className="transaction"><AccountMark name={a.name} color={a.color}/><strong className={minimum<0?'negative':''}>{brl(minimum)}{minimum<0&&<small className="block">Necessário: {brl(-minimum)}</small>}</strong></div>})}<p className="status">{deficit?'Primeiro déficit: '+dateLabel(deficit.date):'Sem déficit neste intervalo'}</p>{suggestions.map((x,i)=><p key={i}>{accounts.find(a=>a.id===x.from)?.name} → {accounts.find(a=>a.id===x.to)?.name}: {brl(x.amount)}</p>)}</section>
 </div>
 <div role="tabpanel" id="screen-pending" aria-labelledby="tab-pending" hidden={mainTab!=='pending'} className="tab-content"><MovementList mode="pending" events={events} accounts={accounts} members={members} paymentDates={paymentDates} onPay={openPay} onEdit={openEdit} onCorrect={openCorrection}/></div>
 <div role="tabpanel" id="screen-planning" aria-labelledby="tab-planning" hidden={mainTab!=='planning'} className="tab-content"><Planning view="calendar" persistenceKey={user.id+household} transfers={scheduled} db={db} household={household} accounts={accounts} members={members} events={events} reload={()=>load(user)}/></div>
 <div role="tabpanel" id="screen-accounts" aria-labelledby="tab-accounts" hidden={mainTab!=='accounts'} className="tab-content"><AccountsPanel scheduled={scheduled} transferRequest={transferRequest} db={db} household={household} accounts={accounts} members={members} reload={()=>load(user)}/></div>
 <div role="tabpanel" id="screen-preferences" aria-labelledby="tab-preferences" hidden={mainTab!=='preferences'} className="tab-content space-y-5"><h2>Mais opções</h2><nav className="more-menu" aria-label="Opções adicionais">{[['entry','Lançamentos'],['planning','Planejamento'],['history','Histórico'],['preferences','Personalização']].map(([id,label])=><button key={id} aria-pressed={moreSection===id} onClick={()=>setMoreSection(id)}>{label}</button>)}</nav><div hidden={moreSection!=='entry'}>
 <EntryForm key={entryVersion} initialType={entryMode} db={db} household={household} userId={user.id} accounts={accounts} members={members} categories={categories} properties={properties} reload={()=>load(user)}/></div>
<div hidden={moreSection!=='planning'}><Planning view="more" persistenceKey={user.id+household} transfers={scheduled} db={db} household={household} accounts={accounts} members={members} events={events} reload={()=>load(user)}/></div>
 <section hidden={moreSection!=='history'} className="card"><h2>Histórico de confirmações</h2><div className="scroll-list">{events.filter(e=>Number(e.paid_amount)>0).map(e=><div key={e.id} className="transaction"><span>{e.title} · {brl(Number(e.paid_amount))}</span>{e.kind==='income'&&<button onClick={()=>openCorrection(e)}>Corrigir recebimento</button>}<button disabled={busy} onClick={()=>act(async()=>{const {error}=await db.rpc("reverse_event",{p_event_id:e.id});if(error)throw error;await load(user)})}>Estornar</button></div>)}</div></section>
 <div hidden={moreSection!=='preferences'}><Preferences db={db} household={household} reload={()=>load(user)} categories={categories}/></div></div>
  {payment&&<section role="dialog" aria-modal="true" aria-label="Confirmar movimentação" className="card space-y-3"><h2>Confirmar: {payment.title} · {brl(payment.amount)}</h2><label>Conta efetiva<select value={paymentAccount} onChange={e=>setPaymentAccount(e.target.value)}>{accounts.map(a=><option key={a.id} value={a.id}>{a.name} · {members.find(m=>m.user_id===a.owner_id)?.display_name}</option>)}</select></label><label>Valor efetivo<input type="number" min=".01" max={Number(payment.amount)-Number(payment.paid_amount??0)} step=".01" value={paidValue} onChange={e=>setPaidValue(e.target.value)}/></label><label>Data efetiva<input type="date" max={today()} value={paidDate} onChange={e=>setPaidDate(e.target.value)}/></label><button disabled={busy||!paidDate||Number(paidValue)<=0} onClick={()=>pay(payment)}>Confirmar</button> <button onClick={()=>setPayment(null)}>Cancelar</button></section>}


  {editing&&<section className="card space-y-3" role="dialog" aria-label="Editar ocorrência"><h2>{editing.title}</h2><label>Valor<input type="number" min=".01" step=".01" value={editAmount} onChange={e=>setEditAmount(e.target.value)}/></label><label>Vencimento<input type="date" value={editDue} onChange={e=>setEditDue(e.target.value)}/></label>{[false,true].map(cancel=><button key={String(cancel)} disabled={busy} onClick={()=>act(async()=>{const {error}=await db.rpc("edit_occurrence",{p_event:editing.id,p_amount:Number(editAmount),p_due:editDue,p_cancel:cancel});if(error)throw error;setEditing(null);await load(user)})}>{cancel?'Cancelar ocorrência':'Salvar ocorrência'}</button>)} <button disabled={busy} onClick={()=>act(async()=>{const r=await db.rpc('edit_future',{p_event:editing.id,p_amount:Number(editAmount)});if(r.error)throw r.error;setEditing(null);await load(user)})}>Aplicar valor às próximas ocorrências</button> <button onClick={()=>setEditing(null)}>Fechar</button><p>Somente esta ocorrência será alterada.</p></section>}




 {correction&&<section role="dialog" aria-modal="true" aria-label="Corrigir recebimento" className="card space-y-3"><h2>Corrigir: {correction.title}</h2><p className="muted">O ajuste preserva o recebimento anterior no histórico.</p><form className="space-y-3" onSubmit={e=>{e.preventDefault();const fd=new FormData(e.currentTarget);void act(async()=>{const params={p_event:correction.id,p_amount:Number(fd.get('amount')),p_date:String(fd.get('date')),p_expected:Number(correction.paid_amount)},signature=JSON.stringify(['correct',params]);const r=await db.rpc('correct_income',{p_id:requestKey(signature),...params});if(r.error)throw r.error;retryKeys.current.delete(signature);setCorrection(null);await load(user)})}}><label>Valor recebido<input name="amount" type="number" min=".01" step=".01" defaultValue={correction.paid_amount} required/></label><label>Data do recebimento<input name="date" type="date" max={today()} defaultValue={paymentDates[correction.id]??correction.due_date} required/></label><button disabled={busy}>Salvar correção</button><button type="button" onClick={()=>setCorrection(null)}>Cancelar</button></form></section>}
 <button ref={quickButton} className="quick-action" aria-label="Nova movimentação" aria-expanded={quick} onClick={()=>setQuick(!quick)}><Plus/></button>{quick&&<div ref={quickMenu} className="quick-menu card">{[['expense','Despesa'],['income','Receita']].map(([m,label])=><button key={m} onClick={()=>{setEntryMode(m as typeof entryMode);setEntryVersion(v=>v+1);setMoreSection('entry');navigate('preferences');setQuick(false)}}>{label}</button>)}<button onClick={()=>{setTransferRequest(n=>n+1);navigate('accounts');setQuick(false)}}>Transferência</button></div>}
 <nav className="bottom-nav" aria-label="Navegação principal" role="tablist">{tabs.map(({id,label,Icon},i)=><button role="tab" key={id} id={'tab-'+id} aria-controls={'screen-'+id} aria-selected={mainTab===id} tabIndex={mainTab===id?0:-1} onClick={()=>navigate(id)} onKeyDown={e=>{if(['ArrowLeft','ArrowRight','Home','End'].includes(e.key)){e.preventDefault();const index=e.key==='Home'?0:e.key==='End'?tabs.length-1:(i+(e.key==='ArrowRight'?1:-1)+tabs.length)%tabs.length;navigate(tabs[index].id);document.getElementById('tab-'+tabs[index].id)?.focus()}}}><Icon size={20}/><span>{label}</span></button>)}</nav>
 </main>

}



export default function Home(){

 const [ready,setReady]=useState(false);

 useEffect(()=>setReady(true),[]);

 if(!process.env.NEXT_PUBLIC_SUPABASE_URL||!process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY)return <main className="card max-w-lg mx-auto mt-16"><h1>Finanças a Dois</h1><p>Configure NEXT_PUBLIC_SUPABASE_URL e NEXT_PUBLIC_SUPABASE_ANON_KEY para conectar seu projeto Supabase.</p></main>;

 return ready?<FinanceApp/>:<main className="p-8" aria-live="polite">Carregando…</main>;

}

