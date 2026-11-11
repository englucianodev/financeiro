import assert from 'node:assert/strict';
import {readHeader} from '../.test-build/statement-banks.js';
import {suggestReference,referenceOptions,classifyRows,importTotals,importPayload,pending,invoiceDates} from '../.test-build/statement-import.js';
import {parseStatement} from '../.test-build/statements.js';

// Cabeçalhos sintéticos nos padrões C6 e Azul/Itaú (sem dados pessoais).
const c6=readHeader('C6 Bank\nTransações feitas até 03/11/26.\nVencimento: 13/11/2026\nValor da fatura: R$ 1.234,56\nCartão final 4321');
assert.deepEqual([c6.bank,c6.closing,c6.due,c6.total,c6.last4],['c6','2026-11-03','2026-11-13',1234.56,'4321']);
const azul=readHeader('Azul Itaucard\nEmissão:25/10/2026\nPrevisão próx Fechamento24/11/2026\nVencimento\t01/11/2026\nTotal desta fatura\tR$ 300,00');
assert.deepEqual([azul.bank,azul.closing,azul.due,azul.total],['itau','2026-10-25','2026-11-01',300]);
assert.equal(readHeader('Fatura qualquer').bank,'generico');
assert.equal(readHeader('Previsão próximo fechamento 24/11/2026').closing,'','previsão do próximo fechamento não é o fechamento');

// Caso real relatado: Azul fecha dia 25 e vence dia 1; fatura de outubro (vence 01/11) importada em 11/11.
const azulCard={id:'azul',closing_day:25,due_day:1,parent_card_id:null};
const oct={id:'oct',card_id:'azul',cycle:'2026-10-01',closing_date:'2026-10-25',due_date:'2026-11-01',revision:3};
const nov={id:'nov',card_id:'azul',cycle:'2026-11-01',closing_date:'2026-11-25',due_date:'2026-12-01',revision:0};
assert.equal(suggestReference([nov,oct],azulCard,azul,'2026-11-11').cycle,'2026-10-01');
assert.equal(suggestReference([nov],azulCard,azul,'2026-11-11').cycle,'2026-10-01','sem fatura cadastrada, calcula pelo vencimento');
assert.equal(suggestReference([nov,oct],azulCard,{due:'',closing:''},'2026-11-11').cycle,'2026-10-01','sem datas no PDF: última fatura fechada, nunca a aberta');
assert.equal(suggestReference([],azulCard,{due:'',closing:'2026-10-25'},'2026-11-11').cycle,'2026-10-01');
assert.deepEqual(invoiceDates(azulCard,'2026-10-01'),{closing:'2026-10-25',due:'2026-11-01'});
const c6Card={id:'c6',closing_day:3,due_day:13,parent_card_id:null};
assert.equal(suggestReference([],c6Card,c6,'2026-11-20').cycle,'2026-11-01');
const options=referenceOptions([oct,nov],azulCard,'2026-10-01');
assert.ok(options.some(o=>o.cycle==='2026-10-01'&&o.invoice?.id==='oct'&&o.label==='Outubro/2026 · fecha 25/10 · vence 01/11'));
assert.ok(options.some(o=>o.cycle==='2026-04-01'&&!o.invoice));

// Classificação: parcela existente vira vínculo; nova parcela lança restantes; à vista igual pede decisão; pagamento ignorado.
const purchase={id:'p1',card_id:'azul',installments:10};
const line=(n,inv)=>({id:'l'+n,invoice_id:inv,card_id:'azul',purchase_id:'p1',title:'LOJA A',category:'Casa',amount:50,paid:0,line_type:'principal',installment:n,charge_date:'2026-08-09'});
const data={cards:[azulCard],invoices:[oct,nov],purchases:[purchase],obligations:[],payments:[],recurrences:[],lines:[line(3,'oct'),line(4,'nov'),{id:'m',invoice_id:'nov',card_id:'azul',purchase_id:null,title:'MERCADO',category:'Mercado',amount:80,paid:0,line_type:'principal',installment:1,charge_date:'2026-11-02'}]};
const parsed=parseStatement('Emissão:25/11/2026\n09/08 LOJA A 04/10 50,00\n05/11 NOVA LOJA 02/06 30,00\n02/11 MERCADO 80,00\n06/11 PADARIA 12,00\n06/11 PADARIA 12,00\n10/11 PAGAMENTO EFETUADO -500,00','pdf').rows;
const rows=classifyRows(parsed,data,'azul');
const by=d=>rows.filter(r=>r.description===d);
assert.equal(by('LOJA A')[0].group,'existente');assert.equal(by('LOJA A')[0].decision,'link');assert.equal(by('LOJA A')[0].match_id,'l4');
assert.equal(by('LOJA A')[0].category,'Casa');
assert.equal(by('NOVA LOJA')[0].group,'parcela-nova');assert.equal(by('NOVA LOJA')[0].total_amount,180);assert.ok(by('NOVA LOJA')[0].estimated);
assert.equal(by('MERCADO')[0].group,'revisar');assert.equal(by('MERCADO')[0].decision,'');assert.equal(by('MERCADO')[0].match_id,'m');assert.equal(by('MERCADO')[0].category,'Mercado','categoria aprendida do histórico');
assert.deepEqual(by('PADARIA').map(r=>[r.group,r.decision,r.repeated]),[['avista','new',2],['avista','new',2]]);
assert.equal(rows.find(r=>r.kind==='payment').group,'ignorado');
assert.equal(pending(rows).length,1,'só o possível duplicado exige decisão');

// Totais: fatura de novembro já tem 4/10 (50) + mercado (80); entram nova loja 30 + padarias 24.
const decided=rows.map(r=>r.description==='MERCADO'?{...r,decision:'link'}:r);
const t=importTotals(decided,data,nov,184);
assert.deepEqual([t.items,t.current,t.added,t.after,t.adjustment,t.pdfDifference],[184,130,54,184,0,0]);
assert.equal(t.onlyInSystem.length,0);
const payload=importPayload({fileName:'f.pdf',hash:'h',header:azul,rows:decided,cycle:'2026-11-01',suggestedCycle:'2026-11-01',reason:'',adjust:true},'azul',nov);
assert.equal(payload.cycle,'2026-11-01');assert.equal(payload.invoice_id,'nov');assert.equal(payload.revision,0);assert.equal(payload.adjust_to_statement,true);assert.equal(payload.confirm_duplicates,true);
assert.ok(payload.rows.every(r=>!('group' in r)&&!('note' in r)));
console.log('Importação: cabeçalhos C6/Azul, mês de referência (caso dia 11 → outubro, vence 01/11), parcelas existentes sem duplicar, possíveis duplicados, totais e pedido OK');
