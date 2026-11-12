"use client";
import {useEffect,useMemo,useState,useRef} from 'react';
import type {SupabaseClient} from '@supabase/supabase-js';
import {BalanceChart,CashFlowChart,PeriodNav,AccountMark} from './finance-visuals';
import {useViewState,validPeriod,validDate,validMonth} from '@/lib/use-view-state';
import {dailyMovements,alphabetic,isCashEvent,isConsumptionEvent,cashDate,type ViewEvent} from '@/lib/finance-view';
import {CashFlowView,ReportsView,SimulatorView} from './planning-views';
import PropertiesPanel,{type PropertyRecord} from './properties-panel';
import {errorMessage} from '@/lib/errors';
import {brl,project,today,transferFlows,type ScheduledTransfer} from '@/lib/money';
type Account={id:string;name:string;owner_id:string;balance:number;account_type?:string;color?:string};
type Member={user_id:string;display_name:string};
type Event=ViewEvent;
/* legacy shape
type LegacyEvent={id:string;title:string;amount:number;paid_amount:number;due_date:string;account_id:string;owner_id:string;status:string;kind:'income'|'expense';category?:string;property_id?:string|null;credit_state?:string;card_id?:string}; */
type Property=PropertyRecord;

type Card={module_version?:number;id:string;name:string;owner_id:string;closing_day:number;due_day:number};
export default function Planning({creditData,view,persistenceKey,transfers,db,household,accounts,members,events,reload}:{creditData?:import('@/lib/credit').CreditData;view:'calendar'|'more';persistenceKey:string;transfers:ScheduledTransfer[];db:SupabaseClient;household:string;accounts:Account[];members:Member[];events:Event[];reload:()=>Promise<void>}){

 const retries=useRef(new Map<string,string>());
 const [invoice,setInvoice]=useState<{card:string;due:string;amount:number}|null>(null);
 const [period,setPeriod]=useViewState('financas:view:'+persistenceKey+':period',0,validPeriod);
 const defaultUntil=new Date(today()+'T12:00:00Z');defaultUntil.setUTCDate(defaultUntil.getUTCDate()+179);
 const [simulateUntil,setSimulateUntil]=useViewState('financas:view:'+persistenceKey+':until',defaultUntil.toISOString().slice(0,10),validDate);
 const [storedTab,setTab]=useViewState('financas:view:'+persistenceKey+':tab','Calendário',(v):v is string=>typeof v==='string'&&['Fluxo de caixa','Cartões','Imóveis','Patrimônio','Relatórios','Simulador'].includes(v)),[error,setError]=useState(''),[busy,setBusy]=useState(false);
 const tab=view==='calendar'?'Calendário':storedTab==='Calendário'||storedTab==='Cartões'?'Fluxo de caixa':storedTab==='Patrimônio'?'Imóveis':storedTab;
 const available=accounts.filter(a=>a.account_type!=='investment');
 const [avgMonths,setAvgMonths]=useViewState('financas:view:'+persistenceKey+':avg-months',0,(v):v is number=>v===0||v===3||v===6||v===12);
 const avgAccount=((available as (Account&{is_primary?:boolean})[]).find(a=>a.is_primary)??available[0])?.id??'';
 const average={events,months:avgMonths,setMonths:setAvgMonths,account:avgAccount};
 const [properties,setProperties]=useState<Property[]>([]),[cards,setCards]=useState<Card[]>([]);
 const [month,setMonth]=useViewState('financas:view:'+persistenceKey+':month',today().slice(0,7),validMonth),[day,setDay]=useViewState('financas:view:'+persistenceKey+':day',today(),validDate);
 const [person,setPerson]=useState(''),[account,setAccount]=useState(''),[category,setCategory]=useState(''),[property,setProperty]=useState('');
 const [reportCard,setReportCard]=useState(''),[reportNature,setReportNature]=useState('all');
 const [from,setFrom]=useState(today().slice(0,7)+'-01'),[to,setTo]=useState(today().slice(0,4)+'-12-31');
 const [scenarios,setScenarios]=useState<{id:string;title:string;account_id:string;amount:number;due_date:string;status:string}[]>([]);
 async function loadAssets(){const results=await Promise.all([db.from('properties').select('*').eq('household_id',household),db.from('credit_cards').select('*').eq('household_id',household)]);for(const r of results)if(r.error)throw r.error;setProperties(results[0].data??[]);setCards(results[1].data??[]);}
 useEffect(()=>{loadAssets().catch(e=>setError(errorMessage(e)))},[household,db,events]);
 async function run(fn:()=>Promise<void>){setBusy(true);setError('');try{await fn();await loadAssets();await reload()}catch(e){setError(errorMessage(e))}finally{setBusy(false)}}
 async function insert(table:string,data:object){const {error}=await db.from(table).insert({...data,household_id:household});if(error)throw error;}
 const options=accounts.map(a=><option key={a.id} value={a.id}>{a.name}</option>);
 const people=members.map(m=><option key={m.user_id} value={m.user_id}>{m.display_name}</option>);
 const remaining=(e:Event)=>Number(e.amount)-Number(e.paid_amount??0);
 const flows=[...transferFlows(transfers),...events.filter(e=>isCashEvent(e)&&e.status==='pending').map(e=>({...e,due_date:cashDate(e),amount:(e.kind==='income'?1:-1)*remaining(e)}))];
 const simulationDays=Math.max(0,Math.min(365,Math.round((Date.parse(simulateUntil+'T12:00:00Z')-Date.parse(today()+'T12:00:00Z'))/86400000)));
 const simulation=useMemo(()=>project(available,[...flows,...scenarios],simulationDays),[accounts,events,scenarios,simulationDays,transfers]);
 const simulationFlows=[...flows,...scenarios].filter(e=>e.status==='pending'&&e.due_date<=simulateUntil);
 const revenue=simulationFlows.filter(e=>e.amount>0&&!e.id.endsWith('-to')).reduce((n,e)=>n+e.amount,0);
 const expenses=simulationFlows.filter(e=>e.amount<0&&![...scenarios,...transferFlows(transfers)].some(s=>s.id===e.id+'-to')).reduce((n,e)=>n-e.amount,0);
 const filtered=events.filter(e=>isConsumptionEvent(e)&&e.status!=='cancelled'&&e.due_date>=from&&e.due_date<=to&&(reportNature==='all'||(reportNature==='realized'?(e.source==='cc_charge'||(!e.source&&e.status==='settled')):e.status==='pending'))&&(!reportCard||e.card_id===reportCard)&&(!person||e.owner_id===person||e.card_owner_id===person)&&(!account||e.account_id===account)&&(!category||e.category===category)&&(!property||e.property_id===property));
 const groups=Object.entries(filtered.filter(e=>e.kind==='expense').reduce<Record<string,number>>((out,e)=>{const key=e.category??'Outros';out[key]=Math.round(((out[key]??0)+Number(e.amount))*100)/100;return out},{}));
 const calendarEvents:Event[]=[...events.filter(e=>!e.hidden_transaction),...transferFlows(transfers).map(t=>({...t,title:'Transferência interna',kind:(t.amount>0?'income':'expense') as 'income'|'expense',amount:Math.abs(t.amount),paid_amount:t.status==='settled'?Math.abs(t.amount):0,owner_id:accounts.find(a=>a.id===t.account_id)?.owner_id??''}))];
 const monthly=calendarEvents.filter(e=>e.due_date.startsWith(month)&&e.status!=='cancelled');
 const first=new Date(month+'-01T12:00:00Z');const offset=first.getUTCDay();const days=new Date(first.getUTCFullYear(),first.getUTCMonth()+1,0).getDate();
 const monthProjection=project(available,flows,365);const monthBalances=Object.fromEntries(monthProjection.map(p=>[p.date,p.total]));
 const max=Math.max(1,...groups.map(([,value])=>value));
 function navigate(delta:number){const d=new Date(month+'-01T12:00:00Z');d.setUTCMonth(d.getUTCMonth()+delta);setMonth(d.toISOString().slice(0,7));}
 return <section id={'planning-'+view} className="space-y-4">{view==='more'&&<nav aria-label="Planejamento" className="more-menu">{['Fluxo de caixa','Imóveis','Relatórios','Simulador'].map(t=><button key={t} aria-pressed={tab===t} onClick={()=>setTab(t)}>{t}</button>)}</nav>}{error&&<p role="alert" className="card text-red-700">{error}</p>}
 {tab==='Fluxo de caixa'&&<CashFlowView accounts={available} flows={flows} average={average}/>}
 {tab==='Calendário' &&<div className="card space-y-4"><div className="flex justify-between items-center"><button aria-label="Mês anterior" onClick={()=>navigate(-1)}>←</button><h2 className="font-bold">Calendário · {month.split('-').reverse().join('/')}</h2><button aria-label="Próximo mês" onClick={()=>navigate(1)}>→</button></div><div className="calendar-grid">{['Dom','Seg','Ter','Qua','Qui','Sex','Sáb'].map(d=><span key={d} className="weekday-heading text-xs text-center">{d}</span>)}{Array.from({length:offset},(_,i)=><span className="calendar-blank" key={'blank'+i}/>)}{Array.from({length:days},(_,i)=>{const date=month+'-'+String(i+1).padStart(2,'0'),entries=monthly.filter(e=>e.due_date===date);return <button key={date} aria-label={date.split('-').reverse().join('/')+' · '+entries.length+' compromissos'} className={'calendar-day '+(day===date?'selected':'')} onClick={()=>setDay(date)}><b>{i+1}<span className="calendar-weekday">{new Date(date+'T12:00:00Z').toLocaleDateString('pt-BR',{weekday:'short',timeZone:'UTC'})}</span></b>{entries.slice(0,2).map(e=><small key={e.id} style={{borderLeft:'3px solid '+(accounts.find(a=>a.id===e.account_id)?.color??'#6366f1')}}>{e.status==='settled'?'✓ ':''}{e.title}</small>)}{entries.length>2&&<small>+{entries.length-2} · ver todos</small>}</button>})}</div><h3>{day.split('-').reverse().join('/')}</h3>{monthly.filter(e=>e.due_date===day).map(e=><p key={e.id}><AccountMark name={accounts.find(a=>a.id===e.account_id)?.name??'Conta'} color={accounts.find(a=>a.id===e.account_id)?.color}/>{members.find(m=>m.user_id===e.owner_id)?.display_name} · {e.kind==='income'?'+':'−'} {e.title} · {e.source==='cc_closing'?'Fechamento':e.source==='cc_obligation'&&e.status==='pending'?'Pendente de lançamento no cartão':e.source==='cc_invoice'?'Fatura '+(e.status==='settled'?'paga':'a pagar'):e.status==='settled'?'Confirmado':'Pendente'}</p>)}</div>}
 {tab==='Imóveis'&&<PropertiesPanel db={db} household={household} properties={properties} reload={async()=>{await loadAssets();await reload()}}/>}
 {tab==='Relatórios'&&<ReportsView events={events} accounts={accounts} members={members} properties={properties} cards={creditData?.cards??[]}/>}
 {tab==='Simulador'&&<SimulatorView accounts={available} flows={flows} average={average} until={simulateUntil} setUntil={setSimulateUntil} maxDate={monthProjection.at(-1)?.date??today()}/>}
 </section>;
}
