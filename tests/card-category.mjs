// Migration 028: desfazer por ID, renomear sem travar, fatura paga com confirmação,
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



 const farm=row('NOTEBOOK',{date:'2026-10-02',amount:100,total_amount:300,installment:1,count:3});
 await action('import_statement',{...pdf(hashA),rows:[farm,row('PADARIA',{date:'2026-10-03',amount:20,total_amount:20}),row('IOF',{kind:'fee',amount:1.5,total_amount:null,date:'2026-10-03'})]});
 const lineN=await scalar("select id as value from cc_lines where title='NOTEBOOK' and installment=1");
 const before=Number(await scalar('select sum(amount) as value from cc_lines'));
 const r1=await action('set_category',{line_id:lineN,category:'Eletrônicos',scope:'purchase'});assert.equal(r1.updated,3);
 assert.equal(await count("cc_lines where title='NOTEBOOK' and category='Eletrônicos'"),3);assert.equal(await scalar("select category as value from cc_purchases where title='NOTEBOOK'"),'Eletrônicos');
 await action('set_category',{line_id:lineN,category:'Presente',scope:'line'});assert.equal(await count("cc_lines where title='NOTEBOOK' and category='Eletrônicos'"),2);
 const fee=await scalar("select id as value from cc_lines where title='IOF'");await action('set_category',{line_id:fee,category:'Encargos'});assert.equal(await scalar("select category as value from cc_lines where id=$1",[fee]),'Encargos');
 await assert.rejects(()=>action('set_category',{line_id:lineN,category:'  '}),/categoria/);
 assert.equal(Number(await scalar('select sum(amount) as value from cc_lines')),before,'valores intactos');
 const imp=await scalar("select id as value from cc_imports where status='active'");assert.equal((await action('preview_undo_import',{import_id:imp})).safe,true,'trocar categoria não trava o desfazer');
 console.log('Categoria no cartão: compra inteira ou só a parcela, encargos, validação, valores intactos e desfazer liberado OK');
}finally{await db.close()}
