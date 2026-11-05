import assert from 'node:assert/strict';
import {project,transferSuggestions} from '../.test-build/money.js';
const account=(id,balance)=>({id,name:id,balance});
const event=(id,account_id,amount,due_date,status='pending')=>({id,account_id,amount,due_date,status});
const start='2026-11-05';
let rows=project([account('a',1000)],[event('1','a',-2500,start),event('2','a',2000,'2026-11-07')],30,start);
assert.equal(rows[0].total,-1500);assert.equal(Math.min(...rows.map(r=>r.byAccount.a)),-1500);assert.equal(rows[2].total,500);
rows=project([account('a',0.1)],[event('1','a',0.2,'2026-11-01'),event('2','a',100,start,'settled')],365,start);
assert.equal(rows[0].total,0.3);assert.equal(rows[365].total,0.3);assert.equal(rows.length,366);
rows=project([account('a',100),account('b',200)],[event('out','a',-50,start),event('in','b',50,start)],0,start);
assert.equal(rows[0].total,300);assert.equal(rows[0].byAccount.a,50);
assert.equal(project([],[],365,'2028-02-28')[1].date,'2028-02-29');
assert.throws(()=>project([],[],366,start));
console.log('Projeções: vencidos, hoje, centavos, liquidações, transferências, déficit e ano bissexto OK');

assert.deepEqual(transferSuggestions([account('a',1000),account('b',2000)],[{byAccount:{a:-500,b:700}},{byAccount:{a:100,b:900}}]),[{from:'b',to:'a',amount:500}]);
