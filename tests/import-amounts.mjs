// Migration 027: desfazer por ID, renomear sem travar, fatura paga com confirmação,
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


 // Parcelamento 4x com centavo na 1ª parcela (91,39 + 3 × 91,37), valores lidos no PDF.
 const farm=row('FARMACIA T',{date:'2026-10-02',amount:91.39,total_amount:365.5,installment:1,count:4,amounts:[91.39,91.37,91.37,91.37]});
 const req={...pdf(hashA),rows:[farm,row('PADARIA',{date:'2026-10-03',amount:20,total_amount:20})]},key=randomUUID();
 const first=await action('import_statement',req,key);
 const amounts=(await db.query("select amount::float as a from cc_lines where title='FARMACIA T' order by installment")).rows.map(r=>r.a);
 assert.deepEqual(amounts,[91.39,91.37,91.37,91.37]);
 assert.equal(Number(await scalar("select amount as value from cc_purchases where title='FARMACIA T'")),365.5);
 assert.deepEqual(await action('import_statement',req,key),first,'repetir o pedido não duplica nem reaplica');
 assert.equal(await count("cc_lines where title='FARMACIA T'"),4);
 // Mês seguinte: a parcela 2/4 de 91,37 existe exatamente com esse valor.
 assert.equal(await count("cc_lines l join cc_invoices i on i.id=l.invoice_id where l.title='FARMACIA T' and l.installment=2 and l.amount=91.37 and i.cycle='2026-11-01'"),1);
 // Desfazer continua íntegro com os valores finais.
 const impact=await action('preview_undo_import',{import_id:key});assert.equal(impact.safe,true,JSON.stringify(impact.reasons));
 await action('undo_import',{import_id:key,confirmed:true});assert.equal(await count('cc_lines'),0);
 // Valores incoerentes são recusados por inteiro.
 await assert.rejects(()=>action('import_statement',{...pdf(createHash('sha256').update('z').digest('hex')),rows:[{...farm,amounts:[91.39,91.37]}]}),/incompletos/);
 assert.equal(await count('cc_lines'),0);
 console.log('Parcelas com valores exatos do PDF: centavo na 1ª parcela, total real, repetição idempotente, mês seguinte no centavo, desfazer e validação OK');
}finally{await db.close()}
