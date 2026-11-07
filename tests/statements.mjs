import assert from 'node:assert/strict';
import {parseStatement,compareRow,makeRow} from '../.test-build/statements.js';
import {dueSlots,emailText,nationalHoliday} from '../.test-build/email-notifications.js';
let p=parseStatement('Data;Descrição;Valor\n01/11/2026;LOJA 03/10;150,00\n02/11/2026;Estorno;-10,00\n03/11/2026;Juros;2,00','csv');assert.equal(p.rows.length,3);assert.equal(p.rows[0].installment,3);assert.equal(p.rows[0].total_amount,1500);assert.equal(p.rows[1].kind,'refund');assert.equal(p.rows[2].kind,'fee');
assert.equal(parseStatement('<STMTTRN><DTPOSTED>20261101<TRNAMT>-100.00<FITID>ABC<NAME>LOJA</STMTTRN>','ofx').rows[0].amount,100);
const data={lines:[{id:'l',card_id:'c',title:'LOJA',amount:150,installment:3,charge_date:'2026-11-01',bank_transaction_id:'ABC'}]};assert.equal(compareRow({...p.rows[0],description:'OUTRA LOJA'},data,'c').comparison,'Novo lançamento');assert.equal(compareRow({...p.rows[0],bank_id:'ABC'},data,'c').comparison,'Já cadastrado');assert.equal(compareRow({...p.rows[0],bank_id:'ABC',amount:151},data,'c').comparison,'Divergente');
assert.equal(parseStatement('01/11 LOJA 150,00','pdf').rows[0].date,'');assert.equal(parseStatement('01/11/2026 LOJA 03/10 150,00','pdf').rows[0].count,10);
const settings={timezone:'America/Fortaleza',weekdays:[1,2,3,4,5],holidays:[],skip_holidays:true,morning:'08:00',evening:'20:00'};assert.deepEqual(dueSlots(settings,new Date('2026-11-06T11:03:00Z')).slots,['morning']);assert.deepEqual(dueSlots(settings,new Date('2026-11-06T23:03:00Z')).slots,['evening']);assert.equal(dueSlots(settings,new Date('2026-11-07T11:03:00Z')).slots.length,0);assert.ok(nationalHoliday('2026-11-20'));assert.equal(dueSlots({...settings,holidays:['2026-11-06']},new Date('2026-11-06T11:03:00Z')).slots.length,0);assert.match(emailText([{title:'Conta',owner_id:'a',amount:10,due_date:'2026-11-05'}],[{user_id:'a',display_name:'Ana'}],'2026-11-06','https://example.test'),/Em atraso/);
console.log('CSV/OFX/PDF textual, parcelas, duplicidade, horários, fins de semana, feriados e subtotais OK');

// Synthetic bank patterns: no personal data from supplied statements.
const c6=parseStatement('Transações feitas até 03/11/26.\n15 set LOJA A - Parcela 2/4 120,00\n02 out LOJA B 15,00\n02 out LOJA B IOF Transações Exterior 0,60\n02 out Estorno Tarifa - Estorno 15,00','pdf');
assert.equal(c6.rows.length,4);assert.deepEqual(c6.rows.map(r=>r.date),['2026-09-15','2026-10-02','2026-10-02','2026-10-02']);assert.equal(c6.rows[0].installment,2);assert.equal(c6.rows[2].kind,'fee');assert.equal(c6.rows[3].kind,'refund');assert.equal(c6.rows[3].amount,-15);
const azul=parseStatement('Emissão:25/10/2026\nPrevisão próx Fechamento24/11/2026\n09/10 LOJA A 12/12 50,00\n03/10 LOJA B 20,00\nCompras parceladas - próximas faturas\n09/10 LOJA A 01/12 50,00\n\f\n24/10 LOJA C 30,00','pdf');
assert.equal(azul.rows.length,3);assert.deepEqual(azul.rows.map(r=>r.date),['2025-10-09','2026-10-03','2026-10-24']);
assert.equal(parseStatement('31/12 COMPRA 20,00','pdf','2027-01-05').rows[0].date,'2026-12-31');
assert.equal(parseStatement('31/02 COMPRA 20,00','pdf','2026-03-05').rows[0].date,'');
assert.equal(parseStatement('Previsão próximo Fechamento 10/12/2026\n12/11 COMPRA 20,00','pdf','2026-11-15').rows[0].date,'2026-11-12');
import {statementPageText} from '../.test-build/pdf-layout.js';
const item=(str,x,y)=>({str,transform:[1,0,0,1,x,y]});
const layout=statementPageText([item('Emissão:25/10/2026',50,800),item('DATA',133,700),item('ESTABELECIMENTO',161,700),item('VALOR EM R$',289,700),item('DATA',351,700),item('ESTABELECIMENTO',379,700),item('VALOR EM R$',507,700),item('03/10',133,680),item('LOJA A',161,680),item('20,00',302,680),item('04/10',351,680),item('LOJA B',379,680),item('30,00',520,680),item('Compras parceladas - próximas faturas',133,660),item('03/10',133,640),item('LOJA FUTURA 02/03',161,640),item('20,00',302,640)]);
const columns=parseStatement(layout,'pdf');assert.equal(columns.rows.length,2);assert.deepEqual(columns.rows.map(r=>r.date),['2026-10-03','2026-10-04']);assert.deepEqual(columns.rows.map(r=>r.amount),[20,30]);
console.log('Padrões Itaú/C6: colunas, datas, anos, parcelas futuras, IOF e estornos OK');

assert.equal(parseStatement('01/11/2026 R$ 6.000,00','pdf').rows.length,0);
const trailingDash=statementPageText([item('Emissão:25/10/2026',50,800),item('09 out',60,700),item('ACADEMIA -',100,700),item('129,90',526,700)]);assert.equal(parseStatement(trailingDash,'pdf').rows[0].amount,129.9);
assert.equal(parseStatement('09/10/2026 Crédito - 31,00','pdf').rows[0].amount,-31);

assert.equal(parseStatement('Total desta fatura 300,00','pdf').metadata.total,'300,00');assert.equal(parseStatement('Valor da fatura: R$ 300,00','pdf').metadata.total,'300,00');

const splitSign=statementPageText([item('01/11/2026',60,700),item('Crédito',100,700),item('-',520,700),item('31,00',526,700)]);assert.equal(parseStatement(splitSign,'pdf').rows[0].amount,-31);
const distantDash=statementPageText([item('01/11/2026',60,700),item('LOJA',100,700),item('-',160,700),item('31,00',526,700)]);assert.equal(parseStatement(distantDash,'pdf').rows[0].amount,31);

for(const suffix of [' - Parcela 03/10',' 03/10',' - 03 / 10',' (03/10)',' [03/10]',' – Parc. 03/10',' — PARCELA: 03 de 10',' - Parcelamento 03/10']){
 const original='LOJA CENTRAL'+suffix,row=makeRow(original,'2026-11-01',150);
 assert.equal(row.description,'LOJA CENTRAL');assert.equal(row.original,original);assert.equal(row.installment,3);assert.equal(row.count,10);assert.equal(row.total_amount,1500);
 const existing={lines:[{...data.lines[0],title:original}]};assert.equal(compareRow(row,existing,'c').comparison,'Possível duplicidade');
}
assert.equal(makeRow('LOJA 03/10 CENTRO','2026-11-01',150).description,'LOJA 03/10 CENTRO');
assert.equal(makeRow('LOJA SEM PARCELAS','2026-11-01',150).description,'LOJA SEM PARCELAS');
for(const [text,format] of [['Data;Descrição;Valor\n01/11/2026;LOJA - Parcela 03/10;150,00','csv'],['01/11/2026 LOJA 03/10 150,00','pdf'],['<STMTTRN><DTPOSTED>20261101<TRNAMT>-150.00<NAME>LOJA - Parcela 03/10</STMTTRN>','ofx']]){
 const row=parseStatement(text,format).rows[0];assert.equal(row.description,'LOJA');assert.equal(row.installment,3);assert.equal(row.count,10);
}
console.log('Descrições limpas em CSV/OFX/PDF com parcelas, original e duplicidades preservados OK');

assert.equal(makeRow('LOJA 02/12','2026-11-01',49.99).total_amount,599.88);
assert.equal(makeRow('LOJA 02/03','2026-11-01',0.29).total_amount,0.87);
