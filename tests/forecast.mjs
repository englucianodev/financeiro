import assert from 'node:assert/strict';
import {cardAverages,cardAverageFlows} from '../.test-build/forecast.js';
// Cartão Azul: fecha 24, vence 1 (fatura de novembro fecha 24/10). Cartão C6: fecha 4, vence 10.
const azul={id:'az',name:'Azul',owner_id:'o',account_id:'acc-a',closing_day:24,due_day:1,parent_card_id:null,card_status:'active'};
const adic={id:'az2',name:'Azul adicional',owner_id:'o',account_id:'acc-a',closing_day:24,due_day:1,parent_card_id:'az',card_status:'active'};
const c6={id:'c6',name:'C6',owner_id:'o',account_id:'acc-b',closing_day:4,due_day:10,parent_card_id:null,card_status:'active'};
const inv=(card,cycle,closing,due)=>({id:card+cycle,card_id:card,cycle:cycle+'-01',closing_date:closing,due_date:due,revision:0});
const invoices=[inv('az','2026-07','2026-07-24','2026-08-01'),inv('az','2026-08','2026-08-24','2026-09-01'),inv('az','2026-09','2026-09-24','2026-10-01'),inv('az','2026-10','2026-10-24','2026-11-01'),inv('az','2026-11','2026-11-24','2026-12-01'),inv('az','2026-12','2026-12-24','2027-01-01'),
 inv('c6','2026-10','2026-10-04','2026-10-10'),inv('c6','2026-11','2026-11-04','2026-11-10'),inv('c6','2026-12','2026-12-04','2026-12-10')];
let n=0;const line=(invoice,amount,card='az',type='principal')=>({id:'l'+(n++),invoice_id:invoice,card_id:card,purchase_id:null,responsible_id:'o',title:'x',category:'y',amount,paid:0,line_type:type,installment:null,charge_date:'2026-01-01'});
const lines=[line('az2026-08',1000),line('az2026-08',200,'az2','principal'),line('az2026-09',1500),line('az2026-09',30,'az','fee'),line('az2026-09',-100,'az','refund'),line('az2026-07',1000),line('az2026-10',900),
 line('az2026-11',700), // fatura de dezembro (aberta) já tem 700 em parcelas
 line('az2026-12',2000), // fatura de janeiro já tem mais que a média
 line('c62026-10',400),line('c62026-11',800)];
const data={cards:[azul,adic,c6],invoices,lines,purchases:[],obligations:[],payments:[],recurrences:[]};
const today='2026-11-12';
const avg=cardAverages(data,3,today);
// Janela de 3 meses antes de novembro pelo VENCIMENTO: ago, set, out (a fatura que vence em novembro não entra)
assert.deepEqual(avg.map(a=>[a.name,a.average,a.invoices]),[['Azul',1210,3],['C6',400,1]],'média por cartão, adicional somado ao principal, encargo e estorno contam');
const flows=cardAverageFlows(data,3,3,today);
const f=(card,ym)=>flows.find(x=>x.card_id===card&&x.due_date.startsWith(ym));
assert.equal(f('az','2026-11'),undefined,'fatura de novembro (fechou 24/10) já é conhecida');
assert.equal(f('az','2026-12').amount,-510,'dezembro: média − parcelas já lançadas');
assert.equal(f('az','2026-12').due_date,'2026-12-01');assert.equal(f('az','2026-12').account_id,'acc-a','conta que paga o cartão');
assert.equal(f('az','2027-01'),undefined,'janeiro já passa da média');
assert.equal(f('c6','2026-11'),undefined,'C6 de novembro já fechou (04/11)');
assert.equal(f('c6','2026-12').amount,-400);assert.equal(f('c6','2027-01').due_date,'2027-01-10','sem fatura criada: vencimento pelo dia do cartão');
assert.ok(flows.every(x=>x.status==='pending'&&x.amount<0&&x.id.startsWith('avg-')));
assert.deepEqual(cardAverages({...data,lines:[]},3,today),[]);
console.log('Previsão pela média das faturas dos cartões OK');
