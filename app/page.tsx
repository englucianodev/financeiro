"use client";

import {useEffect,useMemo,useState,useRef} from "react";

import Planning from "@/components/planning";

import {errorMessage} from "@/lib/errors";

import {supabase} from "@/lib/supabase";

import {brl,project,today,transferSuggestions} from "@/lib/money";

import type {User} from "@supabase/supabase-js";

type Account={id:string;name:string;owner_id:string;balance:number;is_primary:boolean};

type Event={id:string;title:string;amount:number;paid_amount:number;category?:string;property_id?:string;card_id?:string;due_date:string;account_id:string;owner_id:string;status:string;kind:"income"|"expense"};

type Member={user_id:string;display_name:string};

const dateLabel=(d:string)=>d.split("-").reverse().join("/");

function FinanceApp(){

 const [dark,setDark]=useState(false);
 useEffect(()=>{const value=localStorage.getItem("financas-theme")==="dark";setDark(value);document.documentElement.classList.toggle("dark",value)},[]);
 const [user,setUser]=useState<User|null>(null),[email,setEmail]=useState(""),[password,setPassword]=useState("");

 const [membershipStatus,setMembershipStatus]=useState<"loading"|"ready"|"error">("loading");
 const [household,setHousehold]=useState<string|null>(null),[members,setMembers]=useState<Member[]>([]);

 const [accounts,setAccounts]=useState<Account[]>([]),[events,setEvents]=useState<Event[]>([]);

 const [owner,setOwner]=useState(""),[account,setAccount]=useState(""),[amount,setAmount]=useState(""),[title,setTitle]=useState(""),[due,setDue]=useState(today()),[kind,setKind]=useState<"expense"|"income">("expense");

 const activeUser=useRef<string|null>(null),loadVersion=useRef(0);
 const retryKeys=useRef(new Map<string,string>());

 const requestKey=(signature:string)=>{let key=retryKeys.current.get(signature);if(!key){key=crypto.randomUUID();retryKeys.current.set(signature,key)}return key};

 const [months,setMonths]=useState(1),[category,setCategory]=useState("Outros"),[propertyId,setPropertyId]=useState(""),[variable,setVariable]=useState(false),[properties,setProperties]=useState<{id:string;name:string}[]>([]);

 const [paidValue,setPaidValue]=useState(""),[paidDate,setPaidDate]=useState(today()),[editing,setEditing]=useState<Event|null>(null),[editAmount,setEditAmount]=useState(""),[editDue,setEditDue]=useState(today());

 const [horizon,setHorizon]=useState(90),[payment,setPayment]=useState<Event|null>(null),[paymentAccount,setPaymentAccount]=useState("");

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

  setMembers(m.data??[]);setAccounts((a.data??[]).map(x=>({...x,balance:Number(x.balance)})));

  setEvents((e.data??[]).map(x=>({...x,amount:Number(x.amount)})));

  const propertyResult=await db.from("properties").select("id,name").eq("household_id",h);if(version!==loadVersion.current||activeUser.current!==u.id)return;setProperties(propertyResult.data??[]);

  setOwner(v=>v||u.id);
  } catch(error) {
   if(version!==loadVersion.current||activeUser.current!==u.id)return;
   setError(errorMessage(error));setMembershipStatus("error");
  }

 }

 useEffect(()=>{
  let mounted=true;
  db.auth.getUser().then(({data,error})=>{if(!mounted)return;if(error){setError(error.message);return}activeUser.current=data.user?.id??null;setUser(data.user);if(data.user)void load(data.user)});
  const {data:listener}=db.auth.onAuthStateChange((_event,session)=>{
   const next=session?.user??null;if(activeUser.current!==next?.id){activeUser.current=next?.id??null;loadVersion.current++;setHousehold(null);setMembershipStatus("loading");setError("");setProperties([]);setAccounts([]);setEvents([]);setMembers([]);setOwner("");setAccount("");setInvite("");setPayment(null);setEditing(null);retryKeys.current.clear();if(next)setTimeout(()=>{if(mounted)void load(next)},0)}setUser(next);
  });
  return ()=>{mounted=false;loadVersion.current++;listener.subscription.unsubscribe()}
 },[db]);
 useEffect(()=>{setAccount(current=>accounts.some(a=>a.id===current)?current:(accounts.find(a=>a.owner_id===owner&&a.is_primary)??accounts.find(a=>a.owner_id===owner))?.id??"")},[owner,accounts]);

 const pending=events.filter(e=>e.status==="pending"),total=accounts.reduce((s,a)=>s+a.balance,0);

 const projection=project(accounts,pending.map(e=>({...e,amount:e.kind==="expense"?-(Number(e.amount)-Number(e.paid_amount??0)):(Number(e.amount)-Number(e.paid_amount??0))})),horizon);

 const suggestions=transferSuggestions(accounts,projection);
 const deficit=projection.find(p=>Object.values(p.byAccount).some(v=>v<0));

 async function act(fn:()=>Promise<void>){setBusy(true);setError("");try{await fn()}catch(e){setError(errorMessage(e))}finally{setBusy(false)}}

 async function login(signup:boolean){await act(async()=>{const r=signup?await db.auth.signUp({email,password}):await db.auth.signInWithPassword({email,password});if(r.error)throw r.error;if(signup)alert("Cadastro solicitado. Verifique seu e-mail caso a confirmação esteja ativada.");if(r.data.session&&r.data.user){activeUser.current=r.data.user.id;setUser(r.data.user);await load(r.data.user)}})}

 async function createHousehold(){if(!user)return;await act(async()=>{const {error}=await db.rpc("create_household",{p_name:"Nossa família",p_display_name:user.email??"Usuário"});if(error)throw error;await load(user)})}

 async function addAccount(e:React.FormEvent<HTMLFormElement>){e.preventDefault();if(!user||!household)return;await act(async()=>{

 const fd=new FormData(e.currentTarget);const signature=JSON.stringify(["account",...fd.entries()]);const {error}=await db.rpc("create_account",{p_id:requestKey(signature),p_household:household,p_owner:String(fd.get("owner")),p_name:String(fd.get("name")),p_balance:Number(fd.get("balance"))});

 if(error)throw error;retryKeys.current.delete(signature);await load(user)})}

 async function addEvent(e:React.FormEvent){e.preventDefault();if(!user||!household)return;await act(async()=>{

 const signature=JSON.stringify([household,owner,account,title,amount,due,kind,months,category,propertyId,variable]);const {error}=await db.rpc("create_series",{p_id:requestKey(signature),p_household:household,p_owner:owner,p_account:account,p_title:title,p_amount:Number(amount),p_due:due,p_kind:kind,p_months:months,p_category:category,p_property:propertyId||null,p_variable:variable});

 if(error)throw error;retryKeys.current.delete(signature);setTitle("");setAmount("");await load(user)})}

 async function pay(e:Event){if(!user)return;await act(async()=>{

 const signature=JSON.stringify([e.id,paymentAccount,paidValue,paidDate,e.paid_amount]);const {error}=await db.rpc("pay_event",{p_id:requestKey(signature),p_event:e.id,p_account:paymentAccount||e.account_id,p_amount:Number(paidValue),p_date:paidDate,p_expected_paid:Number(e.paid_amount??0)});if(error)throw error;retryKeys.current.delete(signature);setPayment(null);await load(user)})}

 async function transfer(e:React.FormEvent<HTMLFormElement>){e.preventDefault();if(!user)return;await act(async()=>{

 const fd=new FormData(e.currentTarget);const signature=JSON.stringify([...fd.entries()]);const {error}=await db.rpc("transfer_funds",{p_from:String(fd.get("from")),p_to:String(fd.get("to")),p_amount:Number(fd.get("amount")),p_key:requestKey(signature)});if(error)throw error;retryKeys.current.delete(signature);await load(user)})}

 async function inviteMember(){if(!user)return;await act(async()=>{const {error}=await db.rpc("join_household",{p_code:invite.trim(),p_display_name:user.email??"Usuário"});if(error)throw error;await load(user)})}

 if(!user)return <main className="max-w-md mx-auto p-8 mt-16 card space-y-4"><h1 className="text-2xl font-bold">Finanças a Dois</h1><p>Entre com seu e-mail e senha.</p><input placeholder="E-mail" type="email" value={email} onChange={e=>setEmail(e.target.value)}/><input placeholder="Senha" type="password" value={password} onChange={e=>setPassword(e.target.value)}/><div className="flex gap-2"><button disabled={busy} onClick={()=>login(false)}>Entrar</button><button disabled={busy} onClick={()=>login(true)}>Criar conta</button></div>{error&&<p role="alert" className="text-red-700">{error}</p>}</main>;

 if(membershipStatus!=="ready")return <main className="max-w-lg mx-auto p-8 space-y-5" aria-live="polite"><h1 className="text-2xl font-bold">Finanças a Dois</h1>{membershipStatus==="loading"?<p>Carregando sua família…</p>:<><p role="alert">Não foi possível consultar seu núcleo familiar. {error}</p><button disabled={busy} onClick={()=>act(async()=>{setMembershipStatus("loading");await load(user)})}>Tentar novamente</button><button onClick={()=>db.auth.signOut()}>Sair</button></>}</main>;

 if(!household)return <main className="max-w-lg mx-auto p-8 space-y-5"><h1 className="text-2xl font-bold">Bem-vindo!</h1><div className="card space-y-3"><p>Crie seu núcleo familiar:</p><button onClick={createHousehold} disabled={busy}>Criar família</button></div><div className="card space-y-3"><p>Ou entre usando o código compartilhado pelo parceiro:</p><input placeholder="Código de convite" value={invite} onChange={e=>setInvite(e.target.value)}/><button disabled={busy} onClick={inviteMember}>Entrar na família</button></div>{error&&<p role="alert" className="text-red-700">{error}</p>}</main>;

 return <main className="max-w-6xl mx-auto p-4 md:p-8 space-y-6">

 <header className="flex justify-between items-center"><div><h1 className="text-2xl font-bold">Finanças a Dois</h1><p className="text-sm text-slate-500">Seu controle financeiro familiar</p></div><div className="flex gap-2"><button aria-label="Alternar tema" onClick={()=>{const value=!dark;setDark(value);localStorage.setItem("financas-theme",value?"dark":"light");document.documentElement.classList.toggle("dark",value)}}>{dark?"Modo claro":"Modo escuro"}</button><button onClick={()=>db.auth.signOut()}>Sair</button></div></header>

 {error&&<div className="card text-red-700">{error}</div>}

 <label>Horizonte da projeção<select value={horizon} onChange={e=>setHorizon(Number(e.target.value))}>{[30,60,90,180,365].map(d=><option key={d} value={d}>{d} dias</option>)}</select></label><section className="grid md:grid-cols-3 gap-4"><div className="card"><p>Saldo real consolidado</p><strong className="text-3xl">{brl(total)}</strong></div><div className="card"><p>Saldo projetado em 30 dias</p><strong className="text-3xl">{brl(projection[30]?.total??total)}</strong></div><div className="card"><p>Primeiro alerta por conta</p><strong>{deficit?`${dateLabel(deficit.date)} · ${accounts.filter(a=>deficit.byAccount[a.id]<0).map(a=>a.name+": "+brl(deficit.byAccount[a.id])).join("; ")}`:"Nenhum déficit no período"}</strong></div></section>

 <section className="card space-y-3"><h2>Resumo da semana</h2>{members.map(m=><p key={m.user_id}>{m.display_name}: disponível {brl(accounts.filter(a=>a.owner_id===m.user_id).reduce((sum,a)=>sum+a.balance,0))} · projetado {brl(accounts.filter(a=>a.owner_id===m.user_id).reduce((sum,a)=>sum+(projection.at(-1)?.byAccount[a.id]??0),0))}</p>)}{pending.filter(e=>e.kind==='expense'&&e.due_date<=projection[Math.min(7,horizon)].date).map(e=><p key={e.id}>{e.due_date<today()?'Atrasado':e.due_date===today()?'Hoje':e.due_date===projection[1]?.date?'Amanhã':dateLabel(e.due_date)} · {e.title} · {brl(Number(e.amount)-Number(e.paid_amount??0))}</p>)}<h3>Possíveis transferências para cobrir o período</h3>{suggestions.length?suggestions.map((s,i)=><p key={i}>{accounts.find(a=>a.id===s.from)?.name} → {accounts.find(a=>a.id===s.to)?.name}: {brl(s.amount)}</p>):<p>Sem transferência com folga suficiente nas contas do período.</p>}<p className="text-xs">Sugestões usam a menor folga de cada conta e o saldo atual. Confira antes de transferir.</p></section>
 <section className="grid md:grid-cols-2 gap-4">

 <div className="card space-y-3"><h2 className="font-bold text-lg">Contas</h2>{accounts.map(a=><div key={a.id} className="flex justify-between border-b py-2"><span>{a.name} {a.is_primary?"★":""}<small className="block text-slate-500">{members.find(m=>m.user_id===a.owner_id)?.display_name}</small></span><div><b>{brl(a.balance)}</b>{!a.is_primary&&<button disabled={busy} className="block text-xs" onClick={()=>act(async()=>{const {error}=await db.rpc("set_primary_account",{p_account:a.id});if(error)throw error;await load(user)})}>Tornar principal</button>}</div></div>)}

 <form onSubmit={addAccount} className="space-y-2"><h3 className="font-semibold">Adicionar conta</h3><input required name="name" placeholder="Nome da conta"/><select name="owner">{members.map(m=><option key={m.user_id} value={m.user_id}>{m.display_name}</option>)}</select><input required type="number" name="balance" step=".01" placeholder="Saldo inicial"/><button disabled={busy}>Salvar conta</button></form></div>

 <div className="card space-y-3"><h2 className="font-bold text-lg">Nova receita ou despesa</h2><form onSubmit={addEvent} className="space-y-3"><select value={kind} onChange={e=>setKind(e.target.value as typeof kind)}><option value="expense">Despesa</option><option value="income">Receita</option></select><input required placeholder="Descrição" value={title} onChange={e=>setTitle(e.target.value)}/><input required type="number" step=".01" min=".01" placeholder="Valor" value={amount} onChange={e=>setAmount(e.target.value)}/><label>Responsável</label><select value={owner} onChange={e=>{const id=e.target.value;setOwner(id);setAccount((accounts.find(a=>a.owner_id===id&&a.is_primary)??accounts.find(a=>a.owner_id===id))?.id??"")}}>{members.map(m=><option key={m.user_id} value={m.user_id}>{m.display_name}</option>)}</select><label>Conta de origem ou destino</label><select required value={account} onChange={e=>setAccount(e.target.value)}><option value="">Selecione uma conta</option>{accounts.map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select><label>Vencimento</label><input required type="date" value={due} onChange={e=>setDue(e.target.value)}/><label>Categoria<input value={category} maxLength={100} onChange={e=>setCategory(e.target.value)}/></label><label>Imóvel<select value={propertyId} onChange={e=>setPropertyId(e.target.value)}><option value="">Sem imóvel</option>{properties.map(p=><option key={p.id} value={p.id}>{p.name}</option>)}</select></label><label>Ocorrências mensais<input type="number" min="1" max="60" required value={months} onChange={e=>setMonths(Number(e.target.value))}/></label><label><input className="!w-auto" type="checkbox" checked={variable} onChange={e=>setVariable(e.target.checked)}/> Valor variável (estimativa inicial)</label><button disabled={busy||!accounts.length}>Salvar lançamento</button></form></div>

 </section>

 <section className="card"><h2 className="text-lg font-bold mb-3">Pendências</h2>{pending.length===0?<p>Nenhuma pendência.</p>:pending.map(e=><div key={e.id} className="flex flex-wrap items-center justify-between gap-3 py-3 border-b"><div><b>{e.title}</b><p className="text-sm text-slate-500">{dateLabel(e.due_date)} · {accounts.find(a=>a.id===e.account_id)?.name} · {e.kind==="expense"?"Despesa":"Receita"}</p></div><div className="flex items-center gap-3"><strong>{brl(Number(e.amount)-Number(e.paid_amount??0))}</strong>{!e.card_id&&<button disabled={busy} onClick={()=>{setEditing(e);setEditAmount(String(e.amount));setEditDue(e.due_date)}}>Editar</button>}<button disabled={busy} onClick={()=>{setPayment(e);setPaymentAccount(e.account_id);setPaidValue(String(Number(e.amount)-Number(e.paid_amount??0)));setPaidDate(today())}}>{e.kind==="expense"?"Marcar pago":"Confirmar recebimento"}</button></div></div>)}</section>

 <section className="grid md:grid-cols-2 gap-4"><div className="card space-y-3"><h2 className="text-lg font-bold">Transferência interna</h2><form onSubmit={transfer} className="space-y-2"><label>Origem</label><select name="from">{accounts.map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select><label>Destino</label><select name="to">{accounts.map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select><input required name="amount" min=".01" type="number" step=".01" placeholder="Valor"/><button disabled={busy||accounts.length<2}>Transferir</button></form></div>

 <div className="card space-y-3"><h2 className="text-lg font-bold">Projeção e saldo necessário por conta</h2>{accounts.map(a=>{const minimum=Math.min(...projection.map(p=>p.byAccount[a.id]??0));return <div key={a.id} className="border-b py-2 flex justify-between"><span>{a.name}<small className="block text-slate-500">Menor saldo no período</small></span><strong className={minimum<0?"text-red-700":""}>{brl(minimum)}{minimum<0&&<small className="block">Necessário: {brl(-minimum)}</small>}</strong></div>})}</div></section>

 {payment&&<section role="dialog" aria-modal="true" aria-label="Confirmar movimentação" className="card space-y-3"><h2>Confirmar: {payment.title} · {brl(payment.amount)}</h2><label>Conta efetiva<select value={paymentAccount} onChange={e=>setPaymentAccount(e.target.value)}>{accounts.map(a=><option key={a.id} value={a.id}>{a.name}</option>)}</select></label><label>Valor efetivo<input type="number" min=".01" max={Number(payment.amount)-Number(payment.paid_amount??0)} step=".01" value={paidValue} onChange={e=>setPaidValue(e.target.value)}/></label><label>Data efetiva<input type="date" max={today()} value={paidDate} onChange={e=>setPaidDate(e.target.value)}/></label><button disabled={busy||!paidDate||Number(paidValue)<=0} onClick={()=>pay(payment)}>Confirmar</button> <button onClick={()=>setPayment(null)}>Cancelar</button></section>}

 <section className="card"><h2>Histórico de confirmações</h2>{events.filter(e=>Number(e.paid_amount)>0).map(e=><div key={e.id} className="flex justify-between py-2"><span>{e.title} · {brl(Number(e.paid_amount))}</span><button disabled={busy} onClick={()=>act(async()=>{const {error}=await db.rpc("reverse_event",{p_event_id:e.id});if(error)throw error;await load(user)})}>Estornar</button></div>)}</section>

 {editing&&<section className="card space-y-3" role="dialog" aria-label="Editar ocorrência"><h2>{editing.title}</h2><label>Valor<input type="number" min=".01" step=".01" value={editAmount} onChange={e=>setEditAmount(e.target.value)}/></label><label>Vencimento<input type="date" value={editDue} onChange={e=>setEditDue(e.target.value)}/></label>{[false,true].map(cancel=><button key={String(cancel)} disabled={busy} onClick={()=>act(async()=>{const {error}=await db.rpc("edit_occurrence",{p_event:editing.id,p_amount:Number(editAmount),p_due:editDue,p_cancel:cancel});if(error)throw error;setEditing(null);await load(user)})}>{cancel?'Cancelar ocorrência':'Salvar ocorrência'}</button>)} <button onClick={()=>setEditing(null)}>Fechar</button><p>Somente esta ocorrência será alterada.</p></section>}

 <Planning db={db} household={household} accounts={accounts} members={members} events={events} reload={()=>load(user)}/>

 <footer className="card space-y-3"><button disabled={busy||members.length>=2} onClick={()=>act(async()=>{const {data,error}=await db.rpc("create_invite",{p_household:household});if(error)throw error;setInvite(data)})}>Gerar convite por 24 horas</button>{invite&&<p className="break-all">Compartilhe apenas com seu parceiro: <code>{invite}</code></p>}</footer>

 </main>

}



export default function Home(){

 const [ready,setReady]=useState(false);

 useEffect(()=>setReady(true),[]);

 if(!process.env.NEXT_PUBLIC_SUPABASE_URL||!process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY)return <main className="card max-w-lg mx-auto mt-16"><h1>Finanças a Dois</h1><p>Configure NEXT_PUBLIC_SUPABASE_URL e NEXT_PUBLIC_SUPABASE_ANON_KEY para conectar seu projeto Supabase.</p></main>;

 return ready?<FinanceApp/>:<main className="p-8" aria-live="polite">Carregando…</main>;

}

