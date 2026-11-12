import assert from 'node:assert/strict';
import {emptyCredit,creditEvents,invoiceTotals,cardLimit,invoiceCycle,estimatedDue,cardCategorySummary} from '../.test-build/credit.js';
import {monthlyCashOutlook,monthlySummary,transactionView,isCashEvent} from '../.test-build/finance-view.js';
const card={id:'card',owner_id:'ana',account_id:'bank',name:'Nubank',closing_day:5,due_day:15,credit_limit:5000,parent_card_id:null,card_status:'active',module_version:2};
const data={...emptyCredit(),cards:[card],invoices:[{id:'invoice',card_id:'card',cycle:'2026-11-01',closing_date:'2026-11-05',due_date:'2026-11-15',revision:1}],purchases:[{id:'purchase',card_id:'card',responsible_id:'bruno',title:'Energia',category:'Casa',amount:100,charge_date:'2026-11-01',installments:1,next_installment:1,obligation_id:'manual'}],lines:[{id:'line',invoice_id:'invoice',card_id:'card',purchase_id:'purchase',responsible_id:'bruno',title:'Energia',category:'Casa',amount:100,paid:0,line_type:'principal',installment:1,charge_date:'2026-11-01'}],obligations:[{id:'manual',card_id:'card',responsible_id:'bruno',title:'Energia',category:'Casa',amount:100,due_date:'2026-11-01',mode:'manual',state:'posted',revision:1}]};
const bank=[{id:'bank',name:'Banco',owner_id:'ana',balance:1000,is_primary:true}];
let events=creditEvents(data,'2026-11-06');
assert.equal(events.filter(e=>e.source==='cc_invoice').length,1);assert.equal(events.filter(e=>e.source==='cc_obligation').length,0);
assert.equal(monthlyCashOutlook(bank,events,[],'2026-11-06').projected,900);
assert.equal(monthlySummary(events,'2026-11').expense,100);assert.equal(transactionView(events,{month:'2026-11',current:'2026-11-06'}).expense,100);
assert.equal(transactionView(events,{month:'2026-11',current:'2026-11-06'}).rows.filter(e=>e.source==='cc_charge').length,0);
assert.equal(cardLimit(data,card).used,100);
data.lines[0].paid=40;events=creditEvents(data,'2026-11-06');assert.equal(invoiceTotals(data.invoices[0],data.lines,'2026-11-06').status,'Parcialmente paga');assert.equal(monthlyCashOutlook([{...bank[0],balance:960}],events,[],'2026-11-06').projected,900);assert.equal(cardLimit(data,card).used,60);assert.equal(monthlySummary(events,'2026-11').expense,100);
data.lines[0].paid=100;events=creditEvents(data,'2026-11-06');assert.equal(cardLimit(data,card).used,0);assert.equal(monthlySummary(events,'2026-11').expense,100);assert.equal(invoiceTotals(data.invoices[0],data.lines,'2026-11-06').status,'Paga');
const pending={...emptyCredit(),cards:[card],obligations:[{...data.obligations[0],state:'pending',due_date:'2026-11-01'}]};
const pendingEvents=creditEvents(pending,'2026-11-01');assert.equal(pendingEvents.length,1);assert.equal(cardLimit(pending,card).used,0);assert.equal(pendingEvents[0].projection_due,'2026-11-15');assert.equal(monthlyCashOutlook(bank,pendingEvents,[],'2026-11-01').projected,900);
assert.equal(invoiceCycle('2024-02-29',31),'2024-03-01');assert.equal(invoiceCycle('2024-02-28',31),'2024-02-01');assert.equal(estimatedDue('2024-02-28',{...card,closing_day:31,due_day:3}),'2024-03-03');
assert.equal(cardCategorySummary(data,card,'2026-11').expense,100);
assert.equal(isCashEvent({source:'cc_charge',status:'settled'}),false);assert.equal(isCashEvent({source:'cc_obligation',status:'settled'}),false);
const additional={...card,id:'child',owner_id:'bruno',parent_card_id:'card'};data.cards.push(additional);data.lines.push({...data.lines[0],id:'additional-line',card_id:'child',amount:70,paid:0});assert.equal(cardLimit(data,additional).used,70);assert.equal(cardLimit(data,card).used,70);
assert.equal(cardLimit(data,card,[{card_id:'card',status:'pending',amount:20,paid_amount:5}]).used,85);
assert.equal(monthlySummary([{...events[0],source:undefined,credit_state:'planned',amount:500}],'2026-11').expense,0);
console.log('Crédito: consumo separado de caixa, fatura única, pagamento parcial, manual sem limite, ciclos e adicionais compartilhados OK');

const consolidated=transactionView(creditEvents(data,'2026-11-06'),{month:'2026-11',current:'2026-11-06'});
assert.equal(consolidated.rows.filter(e=>e.source==='cc_invoice').length,1);
assert.equal(consolidated.rows.filter(e=>e.source==='cc_charge').length,0);
assert.equal(transactionView(creditEvents(data),{month:'2026-12'}).rows.length,0);

const unpaidData={...data,lines:data.lines.map(l=>({...l,paid:0}))};
assert.equal(transactionView(creditEvents(unpaidData,'2026-11-20'),{month:'2026-11',current:'2026-11-20',status:'paid'}).rows.length,0);
assert.equal(transactionView(creditEvents(unpaidData,'2026-11-20'),{month:'2026-11',current:'2026-11-20',status:'late'}).rows.length,1);
assert.equal(transactionView(creditEvents(unpaidData,'2026-11-20'),{month:'2026-11',current:'2026-11-20',status:'late'}).expense,170);
assert.equal(transactionView(creditEvents(unpaidData),{month:'2026-11',search:'Energia',category:'Casa'}).rows[0].source,'cc_invoice');
const multi={...unpaidData,cards:[...data.cards,{...card,id:'second'}],invoices:[...data.invoices,{...data.invoices[0],id:'invoice2',card_id:'second'},{...data.invoices[0],id:'next-month',cycle:'2026-12-01',due_date:'2026-12-15'}],lines:[...unpaidData.lines,{...data.lines[0],id:'another',invoice_id:'invoice2',card_id:'second',amount:25,paid:0},{...data.lines[0],id:'future',invoice_id:'next-month',amount:30,paid:0}]};
assert.equal(transactionView(creditEvents(multi),{month:'2026-11'}).rows.length,2);
assert.equal(transactionView(creditEvents(multi),{month:'2026-11'}).expense,195);
assert.equal(transactionView(creditEvents(multi),{month:'2026-12'}).rows.length,1);
assert.equal(transactionView(creditEvents(multi),{month:'2026-12'}).expense,30);
console.log('Consolidação: cartões/faturas separados, mês, categoria, busca e situação bancária sem dupla contagem OK');

const credited={...unpaidData,lines:[{...unpaidData.lines[0],amount:-20,paid:0,line_type:'refund',installment:null}]};
assert.equal(creditEvents(credited).find(e=>e.source==='cc_invoice').amount,-20);
assert.equal(transactionView(creditEvents(credited),{month:'2026-11'}).rows.length,1);
const refundedPaid={...unpaidData,lines:[{...unpaidData.lines[0],amount:100,paid:100},{...unpaidData.lines[0],id:'refund',amount:-20,paid:0,line_type:'refund',installment:null}]};
assert.equal(creditEvents(refundedPaid).find(e=>e.source==='cc_invoice').amount,80);
// Mês da fatura para o usuário = mês do vencimento (Azul: fecha 24, vence 1 → fecha em outubro, é a fatura de novembro).
{
 const {dueShift,invoiceMonth,cycleToDueMonth,dueMonthToCycle}=await import('../.test-build/credit.js');
 const azul={closing_day:24,due_day:1},c6={closing_day:4,due_day:10};
 assert.equal(dueShift(azul),1);assert.equal(dueShift(c6),0);
 assert.equal(cycleToDueMonth(azul,'2026-10-01'),'2026-11');assert.equal(dueMonthToCycle(azul,'2026-11'),'2026-10');assert.equal(dueMonthToCycle(azul,'2027-01'),'2026-12');
 assert.equal(cycleToDueMonth(c6,'2026-11-01'),'2026-11');assert.equal(invoiceMonth({due_date:'2026-11-01'}),'2026-11');
 console.log('Mês da fatura pelo vencimento OK');
}
