import {today} from './money';
import {type ViewEvent,monthlySummary,moveMonth} from './finance-view';
/** Meses entre o fechamento (ciclo interno) e o vencimento: 1 quando o vencimento cai no mês seguinte ao fechamento. */
export const dueShift=(root:{closing_day:number;due_day:number})=>root.due_day<=root.closing_day?1:0;
/** Mês da fatura para o usuário = mês do vencimento (o ciclo interno continua sendo o mês do fechamento). */
export const invoiceMonth=(i:{due_date:string})=>i.due_date.slice(0,7);
export const cycleToDueMonth=(root:{closing_day:number;due_day:number},cycle:string)=>cycle?moveMonth(cycle.slice(0,7),dueShift(root)):'';
export const dueMonthToCycle=(root:{closing_day:number;due_day:number},month:string)=>month?moveMonth(month.slice(0,7),-dueShift(root)):'';
export type Card={id:string;name:string;owner_id:string;account_id:string;closing_day:number;due_day:number;issuer:string;brand:string;last_four:string;credit_limit:number;automatic_debit:boolean;color:string;card_status:'active'|'blocked'|'archived';parent_card_id:string|null;module_version:number;revision:number};
export type Invoice={id:string;card_id:string;cycle:string;closing_date:string;due_date:string;revision:number};
export type Obligation={id:string;card_id:string;responsible_id:string;title:string;category:string;amount:number;due_date:string;mode:'automatic'|'manual';state:'pending'|'posted'|'cancelled';recurrence_id:string|null;revision:number;generation_error?:string};
export type Purchase={id:string;card_id:string;responsible_id:string;title:string;category:string;amount:number;charge_date:string;installments:number;next_installment:number;obligation_id:string|null;revision?:number};
export type Line={id:string;invoice_id:string;card_id:string;purchase_id:string|null;responsible_id:string;title:string;category:string;amount:number;paid:number;line_type:'principal'|'fee'|'refund'|'discount'|'credit'|'adjustment';installment:number|null;charge_date:string};
export type CardPayment={id:string;invoice_id:string;account_id:string;amount:number;paid_date:string;reversed_at:string|null};
export type Recurrence={id:string;card_id:string;responsible_id:string;title:string;category:string;amount:number;mode:'automatic'|'manual';variable:boolean;unit:'days'|'months';every:number;start_date:string;end_date:string|null;state:'active'|'paused'|'ended';revision:number};
export type CreditData={cards:Card[];invoices:Invoice[];obligations:Obligation[];purchases:Purchase[];lines:Line[];payments:CardPayment[];recurrences:Recurrence[]};
export const emptyCredit=():CreditData=>({cards:[],invoices:[],obligations:[],purchases:[],lines:[],payments:[],recurrences:[]});
const cents=(n:number)=>Math.round(Number(n)*100);
export const sumMoney=(rows:{amount:number}[])=>rows.reduce((sum,r)=>sum+cents(r.amount),0)/100;
export function invoiceTotals(invoice:Invoice,lines:Line[],current=today()){
 const rows=lines.filter(l=>l.invoice_id===invoice.id),total=sumMoney(rows),paid=rows.reduce((s,l)=>s+cents(l.paid),0)/100,balance=(cents(total)-cents(paid))/100;
 const status=balance<0?'Crédito':balance===0&&paid>0?'Paga':balance>0&&invoice.due_date<current?'Vencida':paid>0?'Parcialmente paga':invoice.closing_date<=current?'Fechada':'Aberta';
 return {total,paid,balance,status};
}
export function rootCard(cards:Card[],card:Card){return cards.find(c=>c.id===card.parent_card_id)??card}
export function cardLimit(data:CreditData,card:Card,legacy:ViewEvent[]=[]){
 const root=rootCard(data.cards,card),ids=new Set(data.cards.filter(c=>c.id===root.id||c.parent_card_id===root.id).map(c=>c.id));
 const lines=data.lines.filter(l=>ids.has(l.card_id));
 const old=legacy.filter(e=>e.card_id&&ids.has(e.card_id)&&e.status==='pending').reduce((s,e)=>s+cents(e.amount)-cents(e.paid_amount),0);
 const used=Math.max(0,(lines.filter(l=>l.line_type!=='fee').reduce((s,l)=>s+cents(l.amount)-cents(l.paid),0)+old)/100);
 const installmentBalance=data.lines.filter(l=>ids.has(l.card_id)&&['principal','refund','discount'].includes(l.line_type)&&(data.purchases.find(p=>p.id===l.purchase_id)?.installments??1)>1).reduce((s,l)=>s+cents(l.amount)-cents(l.paid),0)/100;
 return {total:Number(root.credit_limit),used,available:Number(root.credit_limit)-used,percent:Number(root.credit_limit)>0?used/Number(root.credit_limit)*100:0,installmentBalance,root};
}
export function invoiceCycle(date:string,close:number){const d=new Date(date+'T12:00:00Z'),last=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,0)).getUTCDate();if(d.getUTCDate()>=Math.min(close,last))d.setUTCMonth(d.getUTCMonth()+1,1);else d.setUTCDate(1);return d.toISOString().slice(0,10)}
export function estimatedDue(date:string,card:Card){const d=new Date(invoiceCycle(date,card.closing_day)+'T12:00:00Z');if(card.due_day<=card.closing_day)d.setUTCMonth(d.getUTCMonth()+1,1);const last=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth()+1,0)).getUTCDate();d.setUTCDate(Math.min(card.due_day,last));return d.toISOString().slice(0,10)}
export function creditEvents(data:CreditData,current=today()):ViewEvent[]{
 const rows:ViewEvent[]=[];
 for(const invoice of data.invoices){
  const card=data.cards.find(c=>c.id===invoice.card_id);if(!card)continue;const t=invoiceTotals(invoice,data.lines,current);
  if(t.total===0&&t.paid===0)continue;
  rows.push({id:'cc-invoice:'+invoice.id,source:'cc_invoice',source_id:invoice.id,card_id:card.id,card_owner_id:card.owner_id,title:card.name+' · Fatura '+invoiceMonth(invoice).split('-').reverse().join('/'),category:'Fatura de cartão',kind:'expense',amount:t.total,paid_amount:t.paid,due_date:invoice.due_date,account_id:card.account_id,owner_id:card.owner_id,status:t.balance<=0?'settled':'pending',edit_version:invoice.revision});
  if(invoice.closing_date>=current)rows.push({id:'cc-closing:'+invoice.id,source:'cc_closing',source_id:invoice.id,title:'Fechamento · '+card.name,category:'Fechamento',kind:'expense',amount:0,paid_amount:0,due_date:invoice.closing_date,account_id:card.account_id,owner_id:card.owner_id,status:'pending',card_id:card.id});
 }
 for(const ob of data.obligations){
  const card=data.cards.find(c=>c.id===ob.card_id);if(!card)continue;const root=rootCard(data.cards,card);
  const purchase=data.purchases.find(p=>p.obligation_id===ob.id);
  const rule=data.recurrences.find(r=>r.id===ob.recurrence_id);
  // Pausing suppresses future forecasts; already overdue obligations still require a decision.
  if(rule&&rule.state!=='active'&&ob.due_date>=current&&ob.state==='pending')continue;
  if(ob.state==='posted')continue;
  rows.push({id:'cc-obligation:'+ob.id,source:'cc_obligation',source_id:ob.id,title:ob.title,category:ob.category,kind:'expense',amount:Number(ob.amount),paid_amount:0,due_date:ob.due_date,projection_due:estimatedDue(ob.due_date,root),account_id:root.account_id,owner_id:ob.responsible_id,card_owner_id:card.owner_id,card_id:card.id,card_mode:ob.mode,status:ob.state==='cancelled'?'cancelled':'pending',edit_version:ob.revision,linked_purchase_id:purchase?.id,generation_error:ob.generation_error});
 }
 for(const line of data.lines){
  if(line.line_type==='credit'||(line.line_type==='principal'&&line.installment===null&&Number(line.amount)===0))continue;const invoice=data.invoices.find(i=>i.id===line.invoice_id),card=data.cards.find(c=>c.id===line.card_id);if(!invoice||!card)continue;
  const purchase=data.purchases.find(p=>p.id===line.purchase_id);
  // Posted charges replace the pending obligation in the general list; history stays linked.
  rows.push({id:'cc-line:'+line.id,source:'cc_charge',source_id:line.id,invoice_id:invoice.id,charge_date:line.charge_date,installment:line.installment,installments:purchase?.installments,title:line.title+(line.installment&&purchase?' ('+line.installment+'/'+purchase.installments+')':''),category:line.category,kind:'expense',amount:Number(line.amount),paid_amount:Number(line.paid),due_date:invoice.due_date,account_id:rootCard(data.cards,card).account_id,owner_id:line.responsible_id,card_owner_id:card.owner_id,card_id:card.id,status:'settled',linked_purchase_id:line.purchase_id??undefined,hidden_transaction:false,card_mode:data.obligations.find(o=>o.id===purchase?.obligation_id)?.mode});
 }
 return rows;
}
export const creditStatus=(e:ViewEvent,current=today())=>e.source==='cc_invoice'?'Fatura consolidada':e.source==='cc_closing'?'Fechamento da fatura':e.source==='cc_charge'?'Compra lançada no cartão':e.status==='cancelled'?'Cancelada':e.status==='settled'?(e.card_mode==='automatic'?'Cobrança automática registrada':'Lançada no cartão'):e.due_date<current?(e.card_mode==='manual'?'Vencida e não lançada':'Cobrança automática não registrada'):(e.card_mode==='manual'?'Pendente de lançamento no cartão':'Cobrança automática prevista');
export function cardCategorySummary(data:CreditData,card:Card,month:string,legacy:ViewEvent[]=[]){return monthlySummary([...creditEvents(data).filter(e=>e.source==='cc_charge'&&e.card_id===card.id).map(e=>({...e,due_date:data.invoices.find(i=>i.id===data.lines.find(l=>l.id===e.source_id)?.invoice_id)?.due_date??e.due_date})),...legacy.filter(e=>e.card_id===card.id)],month)}
