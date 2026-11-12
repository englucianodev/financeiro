import assert from 'node:assert/strict';
import {readHeader} from '../.test-build/statement-banks.js';
import {suggestReference,referenceOptions,referenceLabel,classifyRows,importTotals,importPayload,pending,invoiceDates} from '../.test-build/statement-import.js';
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
assert.ok(options.some(o=>o.cycle==='2026-10-01'&&o.invoice?.id==='oct'&&o.label==='Fatura de Novembro/2026 · fecha 25/10 · vence 01/11'),'Azul: a fatura que vence em 01/11 é a de novembro');
assert.equal(referenceLabel([oct,nov],azulCard,'2026-10-01'),'Novembro/2026');assert.equal(referenceLabel([],azulCard,'2026-11-01'),'Dezembro/2026','sem fatura criada: calcula pelo vencimento');
assert.equal(referenceLabel([],c6Card,'2026-11-01'),'Novembro/2026','C6 fecha e vence no mesmo mês');
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
console.log('Importação: cabeçalhos C6/Azul, fatura pelo mês do vencimento (fecha em outubro, vence 01/11 = novembro), parcelas existentes sem duplicar, possíveis duplicados, totais e pedido OK');

// Padrões reais do Itaú/Azul (dados sintéticos): parcela colada ao nome, total da fatura anterior,
// cartão mascarado com pontos, adicional "(final NNNN)", produtos e serviços e próximas faturas.
{
 const text=['Total da fatura anterior\t500,00','Pagamento efetuado em 01/10/2026\t-500,00','Vencimento: 01/11/2026\t=\tTotal desta fatura\t258,79','Emissão: 23/10/2026','Previsão prox. Fechamento: 23/11/2026','Cartão\t5162.XXXX.XXXX.1234',
  'Lançamentos: compras e saques','FULANO DE TAL (final 1234)','DATA\tESTABELECIMENTO\tVALOR EM R$',
  '24/11\tCIA AEREA X11/12\t45,00','TURISMO .CIDADE','02/10\tFARMACIA T 01/04\t91,39','03/10\tPADARIA BOA\t20,00','Lançamentos no cartão (final 1234)\t156,39',
  'FULANO DE TAL (final 9999)','25/09\tCLUBE SAUDE01/03\t90,00','Lançamentos no cartão (final 9999)\t90,00',
  'Lançamentos: produtos e serviços','DATA\tPRODUTOS/SERVIÇOS\tVALOR EM R$','25/09\tANUIDADE DIFERENCI12/12\t24,80','23/10\tREDUÇÃO ANUIDADE\t-12,40',
  'Compras parceladas - próximas faturas','DATA\tESTABELECIMENTO\tVALOR EM R$','24/11\tCIA AEREA X12/12\t45,00','02/10\tFARMACIA T 02/04\t91,37','25/09\tCLUBE SAUDE02/03\t90,00','Próxima fatura\t226,37'].join('\n');
 const h=readHeader(text);assert.deepEqual([h.total,h.last4,h.closing,h.due],[258.79,'1234','2026-10-23','2026-11-01']);
 const parsed=parseStatement(text,'pdf',h.closing);
 assert.equal(parsed.future.length,3,'próximas faturas lidas, não importadas');
 const rows=classifyRows(parsed.rows,{cards:[],invoices:[],purchases:[],lines:[],obligations:[],payments:[],recurrences:[]},'c',parsed.future);
 const get=d=>rows.find(r=>r.description===d);
 assert.deepEqual([get('CIA AEREA X').installment,get('CIA AEREA X').count,get('CIA AEREA X').date],[11,12,'2025-11-24'],'parcela colada ao nome');
 assert.deepEqual(get('FARMACIA T').amounts,[91.39,91.37,91.37,91.37],'centavo da 1ª parcela, próximas lidas do PDF');assert.equal(get('FARMACIA T').total_amount,365.5);assert.equal(get('FARMACIA T').estimated,false);
 assert.equal(get('CLUBE SAUDE').card_final,'9999');assert.match(get('CLUBE SAUDE').note,/final 9999/);
 assert.deepEqual([get('ANUIDADE DIFERENCI').kind,get('ANUIDADE DIFERENCI').date,get('ANUIDADE DIFERENCI').card_final],['fee','2026-09-25',undefined]);
 assert.equal(get('REDUÇÃO ANUIDADE').kind,'refund');
 assert.equal(rows.reduce((s,r)=>s+Math.round(r.amount*100),0)/100,258.79,'soma dos itens = total do PDF');
 assert.equal(makeRowSafe('MERCADO 24/7'),1,'"24/7" não é parcela');
}
function makeRowSafe(d){return parseStatement('01/10/2026 '+d+' 10,00','pdf').rows[0].count}
console.log('PDF Itaú/Azul: parcela colada, total atual (não o anterior), cartão mascarado, adicional, produtos/serviços, próximas faturas e centavos OK');
// Categoria pela compra anterior parecida (qualquer cartão), ignorando "Outros"; várias → a mais recente.
{
 const {guessCategory,storeSimilarity}=await import('../.test-build/statement-import.js');
 const L=(title,category,charge_date,card_id='x')=>({id:title+charge_date,title,category,charge_date,card_id,line_type:'principal',invoice_id:'i',purchase_id:null,responsible_id:'u',amount:10,paid:0,installment:null});
 const r=(description,kind='purchase')=>({description,kind,category:'Outros'});
 const lines=[L('HORTIPLUS MIGUELBELO H','Supermercado','2026-06-29'),L('HORTIPLUS MIGUEL','Outros','2026-10-18'),L('DL*UberRidesSao PauloBR','Transporte','2026-06-25'),L('DL *UBERRIDES','Lazer','2026-05-01'),
  L('MED CLUBE ADMI','Saúde','2026-06-03'),L('AZUL LINHAS NF6BMB','Viagem','2026-10-12','outro-cartao'),L('POSTO MAXXI INFINIT','Transporte','2026-10-11'),L('IFD*DROGARIA ARAUJO SBE','Farmácia','2026-08-30'),L('SUPERMERCADOS BH','Supermercado','2026-10-19'),L('MERCADO*MERCADOLIVRE','Compras','2026-10-12')];
 assert.equal(guessCategory(r('HORTIPLUS MIGUEL'),lines).category,'Supermercado','ignora "Outros" e usa a compra categorizada com nome parecido');
 assert.equal(guessCategory(r('DL*UberRides'),lines).category,'Transporte','prefixo DL* e cidade colada; a mais recente vence');
 assert.equal(guessCategory(r('MED CLUBE ADMINISTRADO'),lines).category,'Saúde','nome cortado');
 assert.equal(guessCategory(r('Azul Linhas Aereas'),lines).category,'Viagem','mesmas duas primeiras palavras, de outro cartão');
 assert.equal(guessCategory(r('POSTO MAXXI 03'),lines).category,'Transporte');
 assert.equal(guessCategory(r('IFD*DROGARIA ARAUJO S'),lines).category,'Farmácia');
 assert.equal(guessCategory(r('POSTO CERTO 2'),lines).category,'Outros','posto diferente não herda');
 assert.equal(guessCategory(r('SUPERMERCADOS ABC'),lines).category,'Outros','primeira palavra igual não basta');
 assert.equal(guessCategory(r('IOF COMPRA','fee'),lines).category,'Encargos');
 assert.match(guessCategory(r('MED CLUBE ADMINISTRADO'),lines).hint,/MED CLUBE ADMI.*03\/06\/2026/);
 // várias categorias para a mesma loja: vale a última atribuída (compra mais recente)
 const many=[L('PADARIA SOL','Alimentação','2026-08-01'),L('PADARIA SOL','Lanches','2026-10-01'),L('PADARIA SOL','Café','2026-09-01')];
 assert.equal(guessCategory(r('PADARIA SOL'),many).category,'Lanches');
 assert.equal(storeSimilarity('SCRIBD R682065294 SA USD 5,15 | Cotação USD: R$5,66','SCRIBD R682065294 SA USD 5,36 | Cotação USD: R$5,48'),3,'câmbio ignorado');
 console.log('Categoria pela compra anterior parecida OK');
}
