// Migration 026: desfazer por ID, renomear sem travar, fatura paga com confirmação,
// lançamentos apagados à mão, importação antiga e reimportação de órfãs.
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
 const asUser=async()=>{await db.exec('reset role');await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user]);await db.exec('set role authenticated')};
 const asAdmin=async()=>db.exec('reset role');
 await asUser();
 const scalar=async(q,p=[])=>(await db.query(q,p)).rows[0]?.value;
 const house=await scalar("select create_household('Casa','Luciano') as value");
 await scalar("select create_account($1,$2,$3,'Banco',5000) as value",[account,house,user]);
 const action=async(name,data,id=randomUUID())=>scalar('select cc_action($1,$2,$3,$4::jsonb) as value',[id,house,name,JSON.stringify(data)]);
 const card=(await action('save_card',{name:'Azul',owner_id:user,account_id:account,credit_limit:100000,closing_day:25,due_day:1,card_status:'active',color:'#1e40af'})).card_id;
 const row=(d,x={})=>({original:d,description:d,category:'Outros',date:'2026-10-03',amount:10,total_amount:10,installment:1,count:1,bank_id:'',kind:'purchase',decision:'new',match_id:'',...x});
 const pdf=hash=>({card_id:card,cycle:'2026-10-01',invoice_id:null,revision:null,confirmed:true,keep_target:false,file_hash:hash,file_name:'azul.pdf',statement:{bank:'itau',due:'2026-11-01',closing:'2026-10-25',total:null},adjust_to_statement:false,
  rows:[row('MERCADO',{amount:200,total_amount:200}),row('CURSO 5/6',{description:'CURSO',date:'2026-06-09',amount:100,total_amount:600,installment:5,count:6})]});
 const count=async(q,p=[])=>Number(await scalar(`select count(*)::int as value from ${q}`,p));
 const bank=async()=>Number(await scalar('select balance as value from financial_accounts where id=$1',[account]));
 const hashA=createHash('sha256').update('a').digest('hex');

 // 1) Lançamentos apagados à mão no Supabase: a mesma fatura pode ser importada de novo (importação órfã liberada).
 const first=randomUUID();await action('import_statement',pdf(hashA),first);
 await asAdmin();await db.query("delete from cc_lines where title in ('MERCADO','CURSO')");await db.query('delete from cc_purchases');await asUser();
 assert.equal((await action('preview_undo_import',{import_id:first})).orphan,true);
 const again=await action('import_statement',pdf(hashA));assert.equal(again.released_orphans,1);
 assert.equal(await scalar('select status as value from cc_imports where id=$1',[first]),'undone');
 assert.equal(await count("cc_lines where title='MERCADO'"),1);

 // 2) Renomear (tirar "5/6", trocar categoria) não bloqueia o desfazer; a descrição original fica guardada.
 const second=again.import_id;
 await asAdmin();await db.query("update cc_lines set title='Curso de inglês',category='Educação' where title='CURSO'");await db.query("update cc_purchases set title='Curso de inglês' where title='CURSO'");await asUser();
 assert.equal(await scalar("select original_description as value from cc_lines where title='Curso de inglês' and installment=5"),'CURSO 5/6');
 // 3) Fatura paga: pede confirmação, mantém o pagamento e a fatura fica com crédito.
 const inv=await scalar("select id as value from cc_invoices where card_id=$1 and cycle='2026-10-01'",[card]);
 const rev=Number(await scalar('select revision as value from cc_invoices where id=$1',[inv]));
 await action('pay_invoice',{invoice_id:inv,revision:rev,amount:300,date:'2026-10-30',account_id:account});
 const before=await bank();
 const impact=await action('preview_undo_import',{import_id:second});
 assert.equal(impact.safe,true,JSON.stringify(impact.reasons));assert.equal(impact.needs_confirmation,true);assert.equal(Number(impact.paid),300);
 await assert.rejects(()=>action('undo_import',{import_id:second,confirmed:true}),/Confirme/);
 await action('undo_import',{import_id:second,confirmed:true,confirm_warnings:true});
 assert.equal(await count("cc_lines where title in ('MERCADO','Curso de inglês')"),0);assert.equal(await count('cc_purchases'),0);
 assert.equal(await bank(),before,'saldo bancário intacto');assert.equal(await count('cc_payments where reversed_at is null'),1,'pagamento preservado');
 assert.ok(await count("cc_audit where table_name='cc_allocations'")>=1,'alocações removidas ficam na auditoria');

 // 4) Mudança financeira depois de importar continua bloqueando, com mensagem clara.
 const third=(await action('import_statement',{...pdf(createHash('sha256').update('c').digest('hex')),rows:[row('LOJA',{date:'2026-10-04'})]})).import_id;
 await asAdmin();await db.query("update cc_lines set amount=11 where title='LOJA'");await asUser();
 assert.match((await action('preview_undo_import',{import_id:third})).reasons.join(' '),/Valor, parcela/);
 await asAdmin();await db.query("update cc_lines set amount=10 where title='LOJA'");await asUser();
 await action('undo_import',{import_id:third,confirmed:true});

 // 5) Importação antiga (sem manifesto): identificar pelos IDs do próprio resumo e desfazer.
 const legacy=(await action('import_statement',{...pdf(createHash('sha256').update('d').digest('hex')),rows:[row('ANTIGA',{date:'2026-10-05'}),row('PARC',{date:'2026-09-01',amount:50,total_amount:150,installment:1,count:3})]})).import_id;
 await asAdmin();await db.query('delete from cc_import_items where import_id=$1',[legacy]);await db.query('update cc_imports set provenance_version=0 where id=$1',[legacy]);await asUser();
 assert.equal((await action('preview_undo_import',{import_id:legacy})).legacy,true);
 const adopted=await action('adopt_legacy_import',{import_id:legacy});assert.equal(adopted.safe,true,JSON.stringify(adopted.reasons));assert.equal(adopted.created_lines,4);
 await action('undo_import',{import_id:legacy,confirmed:true});assert.equal(await count("cc_lines where title in ('ANTIGA','PARC')"),0);

 // 6) Forçar limpeza só para importação sem lançamentos.
 const stuck=(await action('import_statement',{...pdf(createHash('sha256').update('e').digest('hex')),rows:[row('X',{date:'2026-10-06'})]})).import_id;
 await assert.rejects(()=>action('force_clear_import',{import_id:stuck,confirmed:true}),/ainda tem lançamentos/);
 await asAdmin();await db.query("delete from cc_lines where title='X'");await db.query("delete from cc_purchases where title='X'");await asUser();
 await action('force_clear_import',{import_id:stuck,confirmed:true});assert.equal(await scalar('select status as value from cc_imports where id=$1',[stuck]),'undone');
 assert.equal(await count('cc_imports'),5,'nenhum registro de histórico é apagado');

 await asAdmin();await db.query(await readFile('supabase/diagnostico/02_importacoes_orfas.sql','utf8'));
 console.log('Desfazer/limpeza: órfã liberada para reimportar, renomear sem travar, fatura paga com confirmação, bloqueio por valor alterado, importação antiga identificada pelo resumo, forçar limpeza e diagnóstico OK');
}finally{await db.close()}
