import {brl,today,project,transferFlows,type ScheduledTransfer} from './money';
export type ViewEvent={id:string;title:string;amount:number;paid_amount:number;category?:string;due_date:string;account_id:string;owner_id:string;status:string;kind:'income'|'expense';card_id?:string;settled_at?:string;auto_receipt_suppressed?:boolean;property_id?:string|null;series_id?:string|null;edit_version?:number;is_property_installment?:boolean;credit_state?:'none'|'planned'|'paid';payment_card_id?:string|null;credit_paid_date?:string|null};
export type CreditCard={id:string;name:string;owner_id:string};
export const isCashEvent=(event:{credit_state?:string})=>!event.credit_state||event.credit_state==='none';
export const eventIsPaid=(event:ViewEvent)=>event.status==='settled'||event.credit_state==='paid';
export function weekStart(current:string){const date=new Date(current+'T12:00:00Z');return shiftDate(current,-((date.getUTCDay()+6)%7))}
export function transactionView(events:ViewEvent[],{month,current=today(),search='',kind='',category='',status='week'}:{month:string;current?:string;search?:string;kind?:string;category?:string;status?:string}){
 const filtered=Boolean(search||kind||category||status!=='week');
 const rows=events.filter(e=>e.status!=='cancelled'&&e.due_date.startsWith(month)&&(!search||(e.title+' '+(e.category??'')).toLocaleLowerCase('pt-BR').includes(search.toLocaleLowerCase('pt-BR')))&&(!kind||e.kind===kind)&&(!category||e.category===category))
  .filter(e=>status==='paid'?eventIsPaid(e):status==='late'?!eventIsPaid(e)&&e.due_date<current:status==='upcoming'?!eventIsPaid(e)&&e.due_date>=current:true)
  .filter(e=>filtered||month!==current.slice(0,7)||e.due_date>=weekStart(current)).sort((a,b)=>a.due_date.localeCompare(b.due_date)||alphabetic(a.title,b.title));
 const cents=rows.filter(isCashEvent).reduce((sum,e)=>{sum[e.kind]+=Math.round(Number(e.amount)*100);return sum},{income:0,expense:0});
 return {rows,income:cents.income/100,expense:cents.expense/100,balance:(cents.income-cents.expense)/100};
}
export function propertyEquity(properties:{estimated_value:number;debt?:number;tenure?:string}[]){return properties.filter(p=>p.tenure==='owned').reduce((sum,p)=>sum+Math.round(Number(p.estimated_value)*100)-Math.round(Number(p.debt??0)*100),0)/100}
export type ViewAccount={id:string;name:string;owner_id:string;balance:number;is_primary:boolean;color?:string;account_type?:'checking'|'recurring'|'investment'};
/** Current bank cash plus unpaid commitments through the calendar month end. */
export function monthlyCashOutlook(accounts:ViewAccount[],events:ViewEvent[],transfers:ScheduledTransfer[]=[],current=today()){
 const through=shiftDate(moveMonth(current.slice(0,7),1)+'-01',-1),cashAccounts=accounts.filter(a=>a.account_type!=='investment'),ids=new Set(cashAccounts.map(a=>a.id));
 const pending=events.filter(e=>isCashEvent(e)&&e.status==='pending'&&e.due_date<=through&&ids.has(e.account_id));
 const remaining=(e:ViewEvent)=>Math.round(Number(e.amount)*100)-Math.round(Number(e.paid_amount??0)*100);
 const totals=pending.reduce((sum,e)=>{sum[e.kind]+=remaining(e);return sum},{income:0,expense:0});
 const days=Math.round((Date.parse(through+'T12:00:00Z')-Date.parse(current+'T12:00:00Z'))/86400000);
 const projection=project(cashAccounts,[...pending.map(e=>({...e,amount:(e.kind==='income'?1:-1)*remaining(e)/100})),...transferFlows(transfers)],days,current);
 return {through,available:cashAccounts.reduce((sum,a)=>sum+Math.round(Number(a.balance)*100),0)/100,income:totals.income/100,expense:totals.expense/100,projected:projection[projection.length-1]?.total??0};
}
export const alphabetic=(a:string,b:string)=>a.localeCompare(b,'pt-BR',{sensitivity:'base',numeric:true});
export function moveMonth(month:string,delta:number){const date=new Date(month+'-01T12:00:00Z');date.setUTCMonth(date.getUTCMonth()+delta);return date.toISOString().slice(0,7)}
export const monthLabel=(month:string)=>new Intl.DateTimeFormat('pt-BR',{month:'long',year:'numeric',timeZone:'UTC'}).format(new Date(month+'-01T12:00:00Z'));
const expensePalette=['#167d8d','#e67a59','#7464bb','#c49632','#3489c9','#cc5c88','#409a70','#b96b43','#6377bd','#a25caa','#859b3b','#dd6267'];
export function monthlySummary(events:ViewEvent[],month:string,categories:{name:string;kind:string;color:string}[]=[]){
 const names=Array.from(new Set([...categories.filter(c=>c.kind==='expense').map(c=>c.name),...events.filter(e=>e.kind==='expense').map(e=>e.category?.trim()||'Outros')])).sort(alphabetic);
 const colors=new Map<string,string>(),used=new Set<string>();
 names.forEach((name,i)=>{const preferred=categories.find(c=>c.kind==='expense'&&c.name===name)?.color.toLowerCase();const color=preferred&&/^#[0-9a-f]{6}$/.test(preferred)&&!used.has(preferred)?preferred:expensePalette.find(c=>!used.has(c))??`hsl(${(i*137.508)%360} 52% 48%)`;colors.set(name,color);used.add(color)});
 let income=0,expense=0;const totals=new Map<string,number>();
 for(const event of events){if(!isCashEvent(event)||event.status==='cancelled'||!event.due_date.startsWith(month))continue;const cents=Math.round(Number(event.amount)*100);if(event.kind==='income')income+=cents;else{expense+=cents;const name=event.category?.trim()||'Outros';totals.set(name,(totals.get(name)??0)+cents)}}
 return {income:income/100,expense:expense/100,balance:(income-expense)/100,categories:Array.from(totals,([name,cents])=>({name,value:cents/100,percent:expense?cents/expense*100:0,color:colors.get(name)!})).sort((a,b)=>b.value-a.value||alphabetic(a.name,b.name))};
}
export function shiftDate(date:string,days:number){const d=new Date(date+'T12:00:00Z');d.setUTCDate(d.getUTCDate()+days);return d.toISOString().slice(0,10)}
export function checklist(events:ViewEvent[],month=today().slice(0,7),current=today()){
 const rows=events.filter(e=>isCashEvent(e)&&e.kind==='expense'&&e.status!=='cancelled'&&e.due_date.startsWith(month)).sort((a,b)=>a.due_date.localeCompare(b.due_date)||alphabetic(a.title,b.title));
 return 'Despesas · '+month.split('-').reverse().join('/')+'\n'+(rows.length?rows.map(e=>{const paid=e.status==='settled',partial=Number(e.paid_amount)>0&&!paid;return `${paid?'☑':'☐'} ${e.due_date.slice(8)} · ${e.title.replace(/[\r\n]+/g,' ')} · ${brl(Number(e.amount))} · ${paid?'Pago':e.due_date<current?'Em atraso':'Pendente'}${partial?' (parcial: '+brl(Number(e.paid_amount))+')':''}`}).join('\n'):'Nenhuma despesa neste mês.');
}
export function dailyMovements(rows:{date:string;byAccount:Record<string,number>}[],events:{id?:string;due_date:string;amount:number;status:string;account_id:string}[],current=today()){
 return rows.map(r=>{const internal=new Set(events.filter(e=>e.id?.endsWith('-to')&&e.account_id in r.byAccount&&events.some(out=>out.id===e.id?.slice(0,-3)&&out.account_id in r.byAccount)).flatMap(e=>[e.id,e.id?.slice(0,-3)]));const day=events.filter(e=>!internal.has(e.id)&&e.status==='pending'&&(e.due_date<current?current:e.due_date)===r.date&&e.account_id in r.byAccount);return {date:r.date,income:day.filter(e=>e.amount>0).reduce((s,e)=>s+Math.round(e.amount*100),0)/100,expense:day.filter(e=>e.amount<0).reduce((s,e)=>s-Math.round(e.amount*100),0)/100,deficit:Object.values(r.byAccount).some(v=>v<0)}}).filter(r=>r.income>0||r.expense>0);
}
