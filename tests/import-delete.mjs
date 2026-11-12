// Migration 029: excluir do histórico uma importação já desfeita.
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




 await action('import_statement',pdf(hashA));
 const imp=await scalar("select id as value from cc_imports");
 const totalBefore=await count('cc_lines');
 await assert.rejects(()=>action('delete_import_history',{import_id:imp,confirmed:true}),/desfeitas/,'ativa não pode');
 await action('undo_import',{import_id:imp,confirmed:true});
 assert.equal(await count('cc_lines'),0);
 await assert.rejects(()=>action('delete_import_history',{import_id:imp}),/Confirme/);
 const items=await count('cc_import_items where import_id=$1',[imp]);assert.ok(items>0);
 const r=await action('delete_import_history',{import_id:imp,confirmed:true});
 assert.equal(r.manifest_items,items);assert.equal(r.file_name,'azul.pdf');
 assert.equal(await count('cc_imports'),0);assert.equal(await count('cc_import_items'),0);
 assert.equal(await bank(),5000,'saldo intacto');
 assert.equal(await count("cc_requests where action='delete_import_history'"),1,'auditoria');
 // reimportar o mesmo arquivo continua funcionando e a nova importação não é afetada
 await action('import_statement',pdf(hashA));assert.equal(await count('cc_lines'),totalBefore);
 const imp2=await scalar("select id as value from cc_imports");
 await assert.rejects(()=>action('delete_import_history',{import_id:imp2,confirmed:true}),/desfeitas/);
 // desfeita, mas com lançamento recriado à força no manifesto: bloqueia
 await action('undo_import',{import_id:imp2,confirmed:true});
 await asAdmin();const lid=await scalar("select entity_id as value from cc_import_items where import_id=$1 and table_name='cc_lines' limit 1",[imp2]);
 const inv=await scalar('select id as value from cc_invoices limit 1');
 await db.query("insert into cc_lines(id,household_id,card_id,invoice_id,line_type,title,amount,category,charge_date,responsible_id) values($1,$2,$3,$4,'principal','X',1,'Outros','2026-10-03',$5)",[lid,house,card,inv,user]).catch(e=>{throw new Error('setup: '+e.message)});
 await asUser();
 await assert.rejects(()=>action('delete_import_history',{import_id:imp2,confirmed:true}),/ainda tem lançamentos/);
 console.log('Excluir histórico de importação desfeita: só desfeitas, confirmação, manifesto sem lançamentos vivos, auditoria e saldos intactos OK');
}finally{await db.close()}
