import assert from 'node:assert/strict';
import {categoryAverages,averageFlows} from '../.test-build/forecast.js';
const ev=(id,cat,date,amount,extra={})=>({id,title:id,category:cat,due_date:date,amount,paid_amount:amount,status:'settled',kind:'expense',account_id:'a',owner_id:'o',...extra});
const events=[
 ev('m1','Mercado','2026-08-05',600),ev('m2','Mercado','2026-09-05',900),ev('m3','Mercado','2026-10-05',900),
 ev('l1','Lazer','2026-10-10',300),
 ev('old','Mercado','2026-04-05',5000), // fora da janela de 3 meses
 ev('inc','Salário','2026-10-05',8000,{kind:'income'}),
 ev('can','Lazer','2026-09-10',999,{status:'cancelled'}),
 ev('cur','Mercado','2026-11-03',250),                       // já gasto no mês atual
 ev('fut','Lazer','2026-12-10',500,{status:'pending',paid_amount:0}), // já previsto acima da média
];
const avg=categoryAverages(events,3,'2026-11-12');
assert.deepEqual(avg.map(a=>[a.category,a.average,a.months]),[['Mercado',800,3],['Lazer',100,3]]);
const flows=averageFlows(events,'acc',3,3,'2026-11-12');
const pick=(c,m)=>flows.find(f=>f.category===c&&f.due_date.startsWith(m));
assert.equal(pick('Mercado','2026-11').amount,-550,'desconta o que já foi gasto no mês');
assert.equal(pick('Mercado','2026-11').due_date,'2026-11-15');
assert.equal(pick('Mercado','2026-12').amount,-800);
assert.equal(pick('Lazer','2026-12'),undefined,'mês com previsão maior que a média não ganha extra');
assert.equal(pick('Lazer','2027-01').amount,-100);
assert.ok(flows.every(f=>f.account_id==='acc'&&f.status==='pending'&&f.amount<0));
assert.equal(averageFlows(events,'acc',3,3,'2026-11-20').find(f=>f.due_date.startsWith('2026-11')).due_date,'2026-11-20','mês atual após o dia 15 usa hoje');
assert.deepEqual(categoryAverages([],3,'2026-11-12'),[]);
assert.deepEqual(averageFlows(events,'',3),[]);
// app novo: só 1 mês de dados não é diluído por 3
assert.equal(categoryAverages([ev('x','Mercado','2026-10-02',400)],3,'2026-11-12')[0].average,400);
console.log('Previsão por média de categoria OK');
