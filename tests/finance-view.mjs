import assert from 'node:assert/strict';
import {checklist,dailyMovements,alphabetic} from '../.test-build/finance-view.js';
const make=(id,title,date,status='pending',paid=0)=>({id,title,due_date:date,status,paid_amount:paid,kind:'expense',amount:100,account_id:'a',owner_id:'one'});
const text=checklist([make('1','Luz','2026-11-01'),make('2','Internet','2026-11-03','settled',100),make('3','Condomínio','2026-12-01'),make('4','Cancelada','2026-11-02','cancelled')],'2026-11','2026-11-05');
assert.match(text,/01 · Luz.*Em atraso/);assert.match(text,/☑ 03 · Internet.*Pago/);assert.doesNotMatch(text,/Condomínio|Cancelada/);
const rows=[{date:'2026-11-05',byAccount:{a:-50,b:100}},{date:'2026-11-06',byAccount:{a:0,b:100}}];
const flows=[{id:'in',account_id:'a',amount:100,due_date:'2026-11-05',status:'pending'},{id:'out',account_id:'a',amount:-150,due_date:'2026-11-05',status:'pending'},{id:'t',account_id:'a',amount:-10,due_date:'2026-11-05',status:'pending'},{id:'t-to',account_id:'b',amount:10,due_date:'2026-11-05',status:'pending'}];
assert.deepEqual(dailyMovements(rows,flows,'2026-11-05'),[{date:'2026-11-05',income:100,expense:150,deficit:true}]);
assert.deepEqual(['Zebra','Água','Energia'].sort(alphabetic),['Água','Energia','Zebra']);console.log('Checklist mensal, categorias e barras diárias com déficit e sem dupla contagem de transferências OK');
