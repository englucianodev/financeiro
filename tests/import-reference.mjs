// Migration 025: mês de referência explícito, total do PDF, ajuste desfazível, parcelas sem duplicar.
import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
import {readFile,readdir} from 'node:fs/promises';
import {randomUUID,createHash} from 'node:crypto';
import assert from 'node:assert/strict';
const db=new PGlite({extensions:{pgcrypto}});
try{
 await db.exec(`create schema extensions;create extension pgcrypto with schema extensions;create role authenticated;create role anon;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;grant usage on schema auth,public to authenticated;grant execute on function auth.uid() to authenticated;`);
 for(const file of (await readdir('supabase/migrations')).sort())await db.exec(await readFile('supabase/migrations/'+file,'utf8'));
 const user=randomUUID(),account=randomUUID();await db.query('insert into auth.users values($1)',[user]);
 await db.exec('grant select,insert,update,delete on all tables in schema public to authenticated;grant usage,select on all sequences in schema public to authenticated');
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user]);await db.exec('set role authenticated');
 const scalar=async(q,p=[])=>(await db.query(q,p)).rows[0]?.value;
 const house=await scalar("select create_household('Casa','Luciano') as value");
 await scalar("select create_account($1,$2,$3,'Banco',5000) as value",[account,house,user]);
 const action=async(name,data,id=randomUUID())=>scalar('select cc_action($1,$2,$3,$4::jsonb) as value',[id,house,name,JSON.stringify(data)]);
 // Azul: fecha dia 25, vence dia 1. Limite baixo de propósito: importação não pode ser barrada pelo limite do app.
 const card=(await action('save_card',{name:'Azul',owner_id:user,account_id:account,credit_limit:100,closing_day:25,due_day:1,card_status:'active',color:'#1e40af'})).card_id;
 const bankBefore=Number(await scalar('select balance as value from financial_accounts where id=$1',[account]));
 const hash=()=>createHash('sha256').update(randomUUID()).digest('hex');
 const row=(description,extra={})=>({original:description,description,category:'Outros',date:'2026-10-03',amount:10,total_amount:10,installment:1,count:1,bank_id:'',kind:'purchase',decision:'new',match_id:'',...extra});
 const invoiceTotal=async cycle=>Number(await scalar('select coalesce(sum(l.amount),0) as value from cc_lines l join cc_invoices i on i.id=l.invoice_id where i.card_id=$1 and i.cycle=$2',[card,cycle]));

 // 1) Fatura de outubro (vence 01/11), importada em novembro, SEM fatura pré-existente: o mês escolhido manda.
 const october={card_id:card,cycle:'2026-10-01',invoice_id:null,revision:null,confirmed:true,confirm_duplicates:false,keep_target:false,file_hash:hash(),file_name:'azul-out.pdf',
  statement:{bank:'itau',due:'2026-11-01',closing:'2026-10-25',total:300},adjust_to_statement:true,metadata:{due:'01/11/2026'},
  rows:[row('MERCADO',{amount:200,total_amount:200}),row('LOJA A',{date:'2026-08-09',amount:50,total_amount:500,installment:3,count:10}),row('IOF',{kind:'fee',amount:1.2,total_amount:null,category:'Encargos'}),row('NO FECHAMENTO',{date:'2026-10-25'}),row('PAGAMENTO EFETUADO',{kind:'payment',amount:-500,decision:'skip'})]};
 const key=randomUUID(),first=await action('import_statement',october,key);
 assert.equal(first.cycle,'2026-10-01');assert.equal(Number(first.adjustment),38.8);
 assert.equal(await scalar("select to_char(due_date,'YYYY-MM-DD') as value from cc_invoices where card_id=$1 and cycle='2026-10-01'",[card]),'2026-11-01');
 assert.equal(await invoiceTotal('2026-10-01'),300);
 assert.equal(Number(await scalar("select count(*)::int as value from cc_lines where title='LOJA A'")),8);
 assert.deepEqual(await action('import_statement',october,key),first,'repetir o mesmo pedido não duplica');
 assert.equal(await scalar('select reference_cycle::text as value from cc_imports where id=$1',[key]),'2026-10-01');
 assert.equal(Number(await scalar('select statement_total as value from cc_imports where id=$1',[key])),300);
 await assert.rejects(()=>action('import_statement',{...october,file_name:'de novo.pdf'}),/já importado/);

 // 2) Compra depois do fechamento da fatura escolhida é recusada.
 await assert.rejects(()=>action('import_statement',{...october,file_hash:hash(),adjust_to_statement:false,rows:[row('DEPOIS',{date:'2026-10-27'})]}),/posterior ao fechamento/);

 // 3) Fatura seguinte: a parcela 4/10 já existe e é vinculada, sem criar compra nova.
 const line4=await scalar("select id as value from cc_lines where title='LOJA A' and installment=4");
 const nov=await scalar("select row_to_json(i) as value from cc_invoices i where card_id=$1 and cycle='2026-11-01'",[card]);
 const novKey=randomUUID();
 await action('import_statement',{card_id:card,cycle:'2026-11-01',invoice_id:nov.id,revision:Number(nov.revision),confirmed:true,keep_target:false,file_hash:hash(),file_name:'azul-nov.pdf',statement:{bank:'itau',due:'2026-12-01',closing:'2026-11-25',total:70},adjust_to_statement:false,
  rows:[row('LOJA A',{date:'2026-08-09',amount:50,total_amount:null,installment:4,count:10,decision:'link',match_id:line4}),row('PADARIA',{date:'2026-11-05',amount:20,total_amount:20})]},novKey);
 assert.equal(Number(await scalar("select count(*)::int as value from cc_purchases where title='LOJA A'")),1);
 assert.equal(await invoiceTotal('2026-11-01'),70);
 await assert.rejects(()=>action('import_statement',{card_id:card,cycle:'2026-11-01',invoice_id:nov.id,revision:Number(nov.revision),confirmed:true,file_hash:hash(),file_name:'x.pdf',statement:{},rows:[row('X')]}),/Fatura atualizada/);

 // 4) Desfazer: outubro está bloqueado enquanto novembro (que vinculou a parcela 4) estiver ativo.
 assert.equal((await action('preview_undo_import',{import_id:key})).safe,false);
 await action('undo_import',{import_id:novKey,confirmed:true});
 assert.equal(Number(await scalar("select count(*)::int as value from cc_lines where title='PADARIA'")),0);
 assert.equal(Number(await scalar('select count(*)::int as value from cc_lines where id=$1',[line4])),1);
 const impact=await action('preview_undo_import',{import_id:key});assert.equal(impact.safe,true,JSON.stringify(impact.reasons));
 await action('undo_import',{import_id:key,confirmed:true});
 assert.equal(await invoiceTotal('2026-10-01'),0,'desfazer remove também o ajuste');
 assert.equal(Number(await scalar('select count(*)::int as value from cc_purchases')),0);
 assert.equal(Number(await scalar('select balance as value from financial_accounts where id=$1',[account])),bankBefore,'importar/desfazer não mexe no saldo bancário');

 // 5) Pedido no formato antigo (sem "cycle") continua funcionando pelo caminho anterior.
 const inv=await scalar("select row_to_json(i) as value from cc_invoices i where card_id=$1 and cycle='2026-10-01'",[card]);
 await action('save_card',{card_id:card,revision:Number(await scalar('select revision as value from credit_cards where id=$1',[card])),name:'Azul',owner_id:user,account_id:account,credit_limit:100000,closing_day:25,due_day:1,card_status:'active',color:'#1e40af'});
 await action('import_statement',{card_id:card,invoice_id:inv.id,revision:Number(inv.revision),confirmed:true,keep_target:false,file_hash:hash(),file_name:'antigo.csv',rows:[row('ANTIGO')]});
 assert.equal(await invoiceTotal('2026-10-01'),10);
 assert.equal(await scalar("select has_function_privilege('authenticated','public.cc_post_imported_purchase(uuid,uuid,text,text,numeric,date,integer,integer,date)','execute') as value"),false);

 // 6) Diagnósticos somente leitura executam sem erro sobre o esquema completo.
 await db.exec('reset role');
 for(const f of ['00_fotografia.sql','01_checkup_dados.sql'])await db.query(await readFile('supabase/diagnostico/'+f,'utf8'));
 console.log('Importação com mês de referência: fatura criada no mês certo, vencimento 01/11, sem bloqueio por limite, fechamento do PDF, ajuste ao total e desfazer integral, parcela seguinte vinculada sem duplicar, revisão concorrente, formato antigo e diagnósticos OK');
}finally{await db.close()}
