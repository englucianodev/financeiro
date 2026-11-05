"use client";

import {useEffect,useMemo,useState,useRef} from "react";

import {Wallet,Plus,Home as HomeIcon,CalendarDays,ListChecks,Settings,ArrowLeftRight} from "lucide-react";
import {firstName,familyTitle,palette} from "@/lib/identity";
import {Metrics,BalanceChart,PeriodNav,AccountMark} from "@/components/finance-visuals";
import EntryForm from "@/components/entry-form";
import Preferences,{type Category} from "@/components/preferences";
import Planning from "@/components/planning";

import {errorMessage} from "@/lib/errors";

import {supabase} from "@/lib/supabase";

import {brl,project,today,transferSuggestions,transferFlows,type ScheduledTransfer} from "@/lib/money";

import type {User} from "@supabase/supabase-js";

type Account={id:string;name:string;owner_id:string;balance:number;is_primary:boolean;color?:string};

type Event={id:string;title:string;amount:number;paid_amount:number;category?:string;property_id?:string;card_id?:string;due_date:string;account_id:string;owner_id:string;status:string;kind:"income"|"expense"};

type Member={user_id:string;display_name:string};

const dateLabel=(d:string)=>d.split("-").reverse().join("/");

function FinanceApp(){

 const [scheduled,setScheduled]=useState<ScheduledTransfer[]>([]);
 const [categories,setCategories]=useState<Category[]>([]),[entryMode,setEntryMode]=useState<'expense'|'income'|'salary'>('expense'),[quick,setQuick]=useState(false),[period,setPeriod]=useState(0),[displayName,setDisplayName]=useState('');
 const acting=useRef(false);
 const [dark,setDark]=useState(false);
 useEffect(()=>{const value=localStorage.getItem("financas-theme")==="dark";setDark(value);document.documentElement.classList.toggle("dark",value)},[]);
 const [user,setUser]=useState<User|null>(null),[email,setEmail]=useState(""),[password,setPassword]=useState("");

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
  const cats=await db.from('categories').select('*').eq('household_id',h);
  if(version!==loadVersion.current||activeUser.current!==u.id)return;
  if(cats.error)setError(errorMessage(cats.error));else setCategories(cats.data??[]);

  } catch(error) {
   if(version!==loadVersion.current||activeUser.current!==u.id)return;
   setError(errorMessage(error));setMembershipStatus("error");
  }

 }

 useEffect(()=>{
  let mounted=true;
  db.auth.getUser().then(({data,error})=>{if(!mounted)return;if(error){setError(error.message);return}activeUser.current=data.user?.id??null;setUser(data.user);if(data.user)void load(data.user)});
  const {data:listener}=db.auth.onAuthStateChange((_event,session)=>{
   const next=session?.user??null;if(activeUser.current!==next?.id){activeUser.current=next?.id??null;loadVersion.current++;setHousehold(null);setMembershipStatus("loading");setError("");setScheduled([]);setCategories([]);setProperties([]);setAccounts([]);setEvents([]);setMembers([]);setInvite("");setPayment(null);setEditing(null);retryKeys.current.clear();if(next)setTimeout(()=>{if(mounted)void load(next)},0)}setUser(next);
  });
  return ()=>{mounted=false;loadVersion.current++;listener.subscription.unsubscribe()}
 },[db]);


 useEffect(()=>{if(members.length)document.title=familyTitle(members)},[members]);
 useEffect(()=>{if(!payment&&!editing)return;const previous=document.activeElement as HTMLElement|null;const modal=document.querySelector<HTMLElement>('[role="dialog"]');const focusable=()=>Array.from(modal?.querySelectorAll<HTMLElement>('button:not(:disabled),input,select')??[]);focusable()[0]?.focus();const handle=(e:KeyboardEvent)=>{if(e.key==='Escape'){setPayment(null);setEditing(null)}if(e.key==='Tab'){const items=focusable(),first=items[0],last=items.at(-1);if(e.shiftKey&&document.activeElement===first){e.preventDefault();last?.focus()}else if(!e.shiftKey&&document.activeElement===last){e.preventDefault();first?.focus()}}};document.addEventListener('keydown',handle);return()=>{document.removeEventListener('keydown',handle);previous?.focus()}},[payment,editing]);
 const pending=events.filter(e=>e.status==="pending"),total=accounts.reduce((s,a)=>s+a.balance,0);

 const projection=project(accounts,[...transferFlows(scheduled),...pending.map(e=>({...e,amount:e.kind==="expense"?-(Number(e.amount)-Number(e.paid_amount??0)):(Number(e.amount)-Number(e.paid_amount??0))}))],180);
 const periodRows=projection.slice(period*30,period*30+30);

 const suggestions=transferSuggestions(accounts,projection);
 const deficit=projection.find(p=>Object.values(p.byAccount).some(v=>v<0));

 async function act(fn:()=>Promise<void>){if(acting.current)return;acting.current=true;setBusy(true);setError("");try{await fn()}catch(e){setError(errorMessage(e))}finally{acting.current=false;setBusy(false)}}

 async function login(signup:boolean){await act(async()=>{const r=signup?await db.auth.signUp({email,password}):await db.auth.signInWithPassword({email,password});if(r.error)throw r.error;if(signup)alert("Cadastro solicitado. Verifique seu e-mail caso a confirmação esteja ativada.");if(r.data.session&&r.data.user){activeUser.current=r.data.user.id;setUser(r.data.user);await load(r.data.user)}})}

 async function createHousehold(){if(!user)return;await act(async()=>{const {error}=await db.rpc("create_household",{p_name:"Nossa família",p_display_name:displayName.trim()||firstName(String(user.user_metadata?.full_name??user.user_metadata?.name??"Participante"))});if(error)throw error;await load(user)})}

 async function addAccount(e:React.FormEvent<HTMLFormElement>){e.preventDefault();if(!user||!household)return;await act(async()=>{

 const fd=new FormData(e.currentTarget);const signature=JSON.stringify(["account",...fd.entries()]);const {error}=await db.rpc("create_account",{p_id:requestKey(signature),p_household:household,p_owner:String(fd.get("owner")),p_name:String(fd.get("name")),p_balance:Number(fd.get("balance"))});

 if(error)throw error;const colorResult=await db.rpc('set_account_color',{p_account:requestKey(signature),p_color:fd.get('color')});if(colorResult.error)throw colorResult.error;retryKeys.current.delete(signature);await load(user)})}

 async function pay(e:Event){if(!user)return;await act(async()=>{

 const signature=JSON.stringify([e.id,paymentAccount,paidValue,paidDate,e.paid_amount]);const {error}=await db.rpc("pay_event",{p_id:requestKey(signature),p_event:e.id,p_account:paymentAccount||e.account_id,p_amount:Number(paidValue),p_date:paidDate,p_expected_paid:Number(e.paid_amount??0)});if(error)throw error;retryKeys.current.delete(signature);setPayment(null);await load(user)})}

 async function transfer(e:React.FormEvent<HTMLFormElement>){e.preventDefault();if(!user)return;await act(async()=>{

 const fd=new FormData(e.currentTarget);const signature=JSON.stringify([...fd.entries()]);const date=String(fd.get('date'));const {error}=await db.rpc(date>today()?'schedule_transfer':'transfer_funds',{p_from:String(fd.get('from')),p_to:String(fd.get('to')),p_amount:Number(fd.get('amount')),...(date>today()?{p_id:requestKey(signature),p_date:date}:{p_key:requestKey(signature)})});if(error)throw error;retryKeys.current.delete(signature);await load(user)})}

 async function inviteMember(){if(!user)return;await act(async()=>{const {data,error}=await db.rpc("accept_invite",{p_code:invite.trim(),p_name:displayName.trim()||firstName(String(user.user_metadata?.full_name??user.user_metadata?.name??"Participante"))});if(error)throw error;if(!data)throw new Error("Convite inválido, expirado, revogado ou limite de tentativas atingido. Tente mais tarde.");await load(user)})}

 if(!user)return <main className="max-w-md mx-auto p-8 mt-16 card space-y-4"><h1 className="text-2xl font-bold">Finanças a Dois</h1><p>Entre com seu e-mail e senha.</p><input placeholder="E-mail" type="email" value={email} onChange={e=>setEmail(e.target.value)}/><input placeholder="Senha" type="password" value={password} onChange={e=>setPassword(e.target.value)}/><div className="flex gap-2"><button disabled={busy} onClick={()=>login(false)}>Entrar</button><button disabled={busy} onClick={()=>login(true)}>Criar conta</button></div>{error&&<p role="alert" className="text-red-700">{error}</p>}</main>;

 if(membershipStatus!=="ready")return <main className="max-w-lg mx-auto p-8 space-y-5" aria-live="polite"><h1 className="text-2xl font-bold">Finanças a Dois</h1>{membershipStatus==="loading"?<p>Carregando sua família…</p>:<><p role="alert">Não foi possível consultar seu núcleo familiar. {error}</p><button disabled={busy} onClick={()=>act(async()=>{setMembershipStatus("loading");await load(user)})}>Tentar novamente</button><button onClick={()=>db.auth.signOut()}>Sair</button></>}</main>;

 if(!household)return <main className="max-w-lg mx-auto p-8 space-y-5"><h1 className="text-2xl font-bold">Bem-vindo!</h1><div className="card space-y-3"><label>Seu nome<input required value={displayName} onChange={e=>setDisplayName(e.target.value)} placeholder="Nome de exibição" maxLength={120}/></label><p>Crie seu núcleo familiar:</p><button onClick={createHousehold} disabled={busy||!displayName.trim()}>Criar família</button></div><div className="card space-y-3"><p>Ou entre usando o código compartilhado pelo parceiro:</p><input placeholder="Código de convite" value={invite} onChange={e=>setInvite(e.target.value)}/><button disabled={busy} onClick={inviteMember}>Entrar na família</button></div>{error&&<p role="alert" className="text-red-700">{error}</p>}</main>;

 return <main className="max-w-6xl mx-auto p-4 md:p-8 space-y-6">

 <header id="home" className="app-header"><div><span className="eyebrow"><Wallet size={16}/> NOSSO DINHEIRO, NOSSOS PLANOS</span><h1>{familyTitle(members)}</h1></div><div className="flex gap-2"><button aria-label="Alternar tema" onClick={()=>{const value=!dark;setDark(value);localStorage.setItem("financas-theme",value?"dark":"light");document.documentElement.classList.toggle("dark",value)}}>{dark?"Modo claro":"Modo escuro"}</button><button onClick={()=>db.auth.signOut()}>Sair</button></div></header>
 {error&&<div role="alert" className="card text-red-700">{error}</div>}
 <Metrics total={total} income={pending.filter(e=>e.kind==='income'&&e.due_date<=projection[29].date).reduce((n,e)=>n+Number(e.amount)-Number(e.paid_amount??0),0)} expense={pending.filter(e=>e.kind==='expense'&&e.due_date<=projection[29].date).reduce((n,e)=>n+Number(e.amount)-Number(e.paid_amount??0),0)} final={projection[29].total}/>
  <section id="pending" className="card"><h2 className="text-lg font-bold mb-3">Pendências</h2>{pending.length===0?<p>Nenhuma pendência.</p>:[...pending].sort((a,b)=>a.due_date.localeCompare(b.due_date)).map(e=><div key={e.id} className="flex flex-wrap items-center justify-between gap-3 py-3 border-b"><div><b>{e.title}</b><p className="muted">{dateLabel(e.due_date)} · {members.find(m=>m.user_id===e.owner_id)?.display_name}</p><AccountMark name={accounts.find(a=>a.id===e.account_id)?.name??'Conta'} color={accounts.find(a=>a.id===e.account_id)?.color}/><span className="status">{e.due_date<today()?'Atrasada':e.due_date===today()?'Vence hoje':e.due_date<=projection[6].date?'Próximos 7 dias':e.due_date.slice(0,7)===today().slice(0,7)?'Restante do mês':'Futura'} · {e.kind==='income'?'Receita':'Despesa'}</span></div><div className="flex items-center gap-3"><strong className={e.kind==='income'?'positive':'negative'}>{brl(Number(e.amount)-Number(e.paid_amount??0))}</strong>{!e.card_id&&<button disabled={busy} onClick={()=>{setEditing(e);setEditAmount(String(e.amount));setEditDue(e.due_date)}}>Editar</button>}<button disabled={busy} onClick={()=>{setPayment(e);setPaymentAccount(e.account_id);setPaidValue(String(Number(e.amount)-Number(e.paid_amount??0)));setPaidDate(today())}}>{e.kind==="expense"?"Marcar pago":"Confirmar recebimento"}</button></div></div>)}</section>


 <section className="card"><h2>Resumo da semana</h2><div className="weekly-grid">{events.filter(e=>e.status!=='cancelled'&&e.due_date>=today()&&e.due_date<=projection[6].date).map(e=><article key={e.id} className="transaction"><div><small>{dateLabel(e.due_date)} · {members.find(m=>m.user_id===e.owner_id)?.display_name}</small><h3>{e.title}</h3><AccountMark name={accounts.find(a=>a.id===e.account_id)?.name??'Conta'} color={accounts.find(a=>a.id===e.account_id)?.color}/><span className="status">{e.status==='settled'?'✓ Confirmado':'Pendente'}</span></div><strong className={e.kind==='income'?'positive':'negative'}>{e.kind==='income'?'+':'−'} {brl(Number(e.amount))}</strong></article>)}</div></section>
 <section id="projection" className="card"><h2>Seu dinheiro no tempo</h2><PeriodNav period={period} setPeriod={setPeriod} rows={periodRows}/><p>Saldo inicial: {brl(period===0?total:projection[period*30-1].total)} · Saldo final: {brl(periodRows.at(-1)?.total??total)}</p><BalanceChart rows={periodRows} accounts={accounts}/><p className="status">{deficit?'Primeiro déficit: '+dateLabel(deficit.date):'Sem déficit nos próximos 180 dias'}</p>{suggestions.map((x,i)=><p key={i}>{accounts.find(a=>a.id===x.from)?.name} → {accounts.find(a=>a.id===x.to)?.name}: {brl(x.amount)}</p>)}</section>
 <Planning transfers={scheduled} db={db} household={household} accounts={accounts} members={members} events={events} reload={()=>load(user)}/>
 <section className="grid md:grid-cols-2 gap-4">

 <div id="accounts" className="card space-y-3"><h2 className="font-bold text-lg">Contas</h2>{accounts.map(a=><div key={a.id} className="bank-card" style={{borderColor:a.color??palette[0],background:`linear-gradient(125deg,${a.color??palette[0]}22,var(--panel))`}}><span><Wallet size={22}/>{a.name} {a.is_primary?"★":""}<small className="block text-slate-500">{members.find(m=>m.user_id===a.owner_id)?.display_name}</small></span><div><b>{brl(a.balance)}</b><label>Cor de {a.name}<input type="color" aria-label={'Cor de '+a.name} defaultValue={a.color??palette[0]} onBlur={e=>{const color=e.target.value;if(color!==a.color)void act(async()=>{const r=await db.rpc('set_account_color',{p_account:a.id,p_color:color});if(r.error)throw r.error;await load(user)})}}/></label>{!a.is_primary&&<button disabled={busy} className="block text-xs" onClick={()=>act(async()=>{const {error}=await db.rpc("set_primary_account",{p_account:a.id});if(error)throw error;await load(user)})}>Tornar principal</button>}</div></div>)}

 <form onSubmit={addAccount} className="space-y-2"><h3 className="font-semibold">Adicionar conta</h3><label>Nome da conta<input required name="name" placeholder="Nome da conta"/></label><label>Titular<select name="owner">{members.map(m=><option key={m.user_id} value={m.user_id}>{m.display_name}</option>)}</select></label><label>Saldo inicial<input required type="number" name="balance" step=".01" placeholder="Saldo inicial"/></label><label>Cor de identificação<input name="color" type="color" defaultValue={palette[0]} list="account-colors"/></label><datalist id="account-colors">{palette.map(c=><option key={c}>{c}</option>)}</datalist><button disabled={busy}>Salvar conta</button></form></div>

 <EntryForm key={entryMode} mode={entryMode} db={db} household={household} userId={user.id} accounts={accounts} members={members} categories={categories} properties={properties} reload={()=>load(user)}/>
 </section>

 <section className="grid md:grid-cols-2 gap-4"><div className="card space-y-3"><h2 id="transfer" className="text-lg font-bold">Transferência interna</h2><form onSubmit={transfer} className="space-y-2"><label>Origem</label><select name="from">{accounts.map(a=><option key={a.id} value={a.id}>{a.name} · {members.find(m=>m.user_id===a.owner_id)?.display_name}</option>)}</select><label>Destino</label><select name="to">{accounts.map(a=><option key={a.id} value={a.id}>{a.name} · {members.find(m=>m.user_id===a.owner_id)?.display_name}</option>)}</select><input required name="amount" min=".01" type="number" step=".01" placeholder="Valor"/><label>Data da transferência<input name="date" type="date" defaultValue={today()} min={today()} required/></label><button disabled={busy||accounts.length<2}>Transferir ou agendar</button></form>{scheduled.filter(t=>t.status==='pending').map(t=><div className="transaction" key={t.id}><span>{dateLabel(t.due_date)} · {accounts.find(a=>a.id===t.from_account)?.name} → {accounts.find(a=>a.id===t.to_account)?.name} · {brl(t.amount)}</span><button disabled={busy||t.due_date>today()} onClick={()=>act(async()=>{const r=await db.rpc('execute_transfer',{p_id:t.id});if(r.error)throw r.error;await load(user)})}>Confirmar transferência</button></div>)}</div>

 <div className="card space-y-3"><h2 className="text-lg font-bold">Projeção e saldo necessário por conta</h2>{accounts.map(a=>{const minimum=Math.min(...projection.map(p=>p.byAccount[a.id]??0));return <div key={a.id} className="border-b py-2 flex justify-between"><span>{a.name}<small className="block text-slate-500">Menor saldo no período</small></span><strong className={minimum<0?"text-red-700":""}>{brl(minimum)}{minimum<0&&<small className="block">Necessário: {brl(-minimum)}</small>}</strong></div>})}</div></section>

 {payment&&<section role="dialog" aria-modal="true" aria-label="Confirmar movimentação" className="card space-y-3"><h2>Confirmar: {payment.title} · {brl(payment.amount)}</h2><label>Conta efetiva<select value={paymentAccount} onChange={e=>setPaymentAccount(e.target.value)}>{accounts.map(a=><option key={a.id} value={a.id}>{a.name} · {members.find(m=>m.user_id===a.owner_id)?.display_name}</option>)}</select></label><label>Valor efetivo<input type="number" min=".01" max={Number(payment.amount)-Number(payment.paid_amount??0)} step=".01" value={paidValue} onChange={e=>setPaidValue(e.target.value)}/></label><label>Data efetiva<input type="date" max={today()} value={paidDate} onChange={e=>setPaidDate(e.target.value)}/></label><button disabled={busy||!paidDate||Number(paidValue)<=0} onClick={()=>pay(payment)}>Confirmar</button> <button onClick={()=>setPayment(null)}>Cancelar</button></section>}

 <section className="card"><h2>Histórico de confirmações</h2>{events.filter(e=>Number(e.paid_amount)>0).map(e=><div key={e.id} className="flex justify-between py-2"><span>{e.title} · {brl(Number(e.paid_amount))}</span><button disabled={busy} onClick={()=>act(async()=>{const {error}=await db.rpc("reverse_event",{p_event_id:e.id});if(error)throw error;await load(user)})}>Estornar</button></div>)}</section>

 {editing&&<section className="card space-y-3" role="dialog" aria-label="Editar ocorrência"><h2>{editing.title}</h2><label>Valor<input type="number" min=".01" step=".01" value={editAmount} onChange={e=>setEditAmount(e.target.value)}/></label><label>Vencimento<input type="date" value={editDue} onChange={e=>setEditDue(e.target.value)}/></label>{[false,true].map(cancel=><button key={String(cancel)} disabled={busy} onClick={()=>act(async()=>{const {error}=await db.rpc("edit_occurrence",{p_event:editing.id,p_amount:Number(editAmount),p_due:editDue,p_cancel:cancel});if(error)throw error;setEditing(null);await load(user)})}>{cancel?'Cancelar ocorrência':'Salvar ocorrência'}</button>)} <button disabled={busy} onClick={()=>act(async()=>{const r=await db.rpc('edit_future',{p_event:editing.id,p_amount:Number(editAmount)});if(r.error)throw r.error;setEditing(null);await load(user)})}>Aplicar valor às próximas ocorrências</button> <button onClick={()=>setEditing(null)}>Fechar</button><p>Somente esta ocorrência será alterada.</p></section>}



 <Preferences db={db} household={household} reload={()=>load(user)} categories={categories}/>
 <button className="quick-action" aria-label="Nova movimentação" onClick={()=>setQuick(!quick)}><Plus/></button>{quick&&<div className="quick-menu card">{[['income','Nova receita'],['salary','Novo salário'],['expense','Nova despesa']].map(([m,label])=><button key={m} onClick={()=>{setEntryMode(m as typeof entryMode);setQuick(false);setTimeout(()=>document.getElementById('new-entry')?.scrollIntoView({behavior:matchMedia('(prefers-reduced-motion: reduce)').matches?'auto':'smooth'}),0)}}>{label}</button>)}<a href="#transfer" onClick={()=>setQuick(false)}>Nova transferência</a><a href="#accounts" onClick={()=>setQuick(false)}>Nova conta bancária</a></div>}
 <nav className="bottom-nav" aria-label="Navegação principal">{[{id:'home',label:'Início',Icon:HomeIcon},{id:'pending',label:'Pendências',Icon:ListChecks},{id:'planning',label:'Calendário',Icon:CalendarDays},{id:'accounts',label:'Contas',Icon:Wallet},{id:'preferences',label:'Mais',Icon:Settings}].map(({id,label,Icon})=><a key={id} href={'#'+id} onClick={()=>{if(id==='planning')window.dispatchEvent(new window.Event('planning-calendar'))}}><Icon size={20}/><span>{label}</span></a>)}</nav>
 </main>

}



export default function Home(){

 const [ready,setReady]=useState(false);

 useEffect(()=>setReady(true),[]);

 if(!process.env.NEXT_PUBLIC_SUPABASE_URL||!process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY)return <main className="card max-w-lg mx-auto mt-16"><h1>Finanças a Dois</h1><p>Configure NEXT_PUBLIC_SUPABASE_URL e NEXT_PUBLIC_SUPABASE_ANON_KEY para conectar seu projeto Supabase.</p></main>;

 return ready?<FinanceApp/>:<main className="p-8" aria-live="polite">Carregando…</main>;

}

