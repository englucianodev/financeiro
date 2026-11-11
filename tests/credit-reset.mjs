import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
import {readFile,readdir} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';
for(const [version,restore] of [[19,false],[24,false],[24,true]]){
 const db=new PGlite({extensions:{pgcrypto}});
 try{
  await db.exec(`create schema extensions;create extension pgcrypto with schema extensions;create role authenticated;create role anon;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;`);
  for(const file of (await readdir('supabase/migrations')).sort().filter(f=>Number(f.slice(0,3))<=version))await db.exec(await readFile('supabase/migrations/'+file,'utf8'));
  const user=randomUUID(),otherUser=randomUUID(),account=randomUUID();for(const id of [user,otherUser])await db.query('insert into auth.users values($1)',[id]);
  const scalar=async(q,p=[])=>(await db.query(q,p)).rows[0]?.value;
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user]);
  const h=await scalar("select create_household('Alvo','Ana') as value");
  await scalar("select create_account($1,$2,$3,'Banco',1000) as value",[account,h,user]);
  const action=(a,data)=>scalar('select cc_action($1,$2,$3,$4::jsonb) as value',[randomUUID(),h,a,JSON.stringify(data)]);
  const c=(await action('save_card',{name:'Atual',owner_id:user,account_id:account,credit_limit:5000,closing_day:5,due_day:15,card_status:'active',color:'#765484'})).card_id;
  await action('purchase',{card_id:c,responsible_id:user,title:'Compra',category:'Casa',amount:100,date:'2024-01-01',installments:1,next_installment:1,first_cycle:'2024-01-01'});
  const invoice=await scalar('select id as value from cc_invoices where card_id=$1',[c]);
  if(version===24)await action('import_statement',{card_id:c,invoice_id:invoice,revision:Number(await scalar('select revision as value from cc_invoices where id=$1',[invoice])),confirmed:true,file_hash:'a'.repeat(64),file_name:'teste.csv',rows:[{decision:'new',kind:'purchase',description:'Importada',original:'Importada',date:'2024-01-01',category:'Casa',amount:20,total_amount:60,count:3,installment:1}]});
  await action('pay_invoice',{invoice_id:invoice,revision:Number(await scalar('select revision as value from cc_invoices where id=$1',[invoice])),account_id:account,amount:50,date:'2024-01-15'});
  const legacy=randomUUID();await db.query("insert into credit_cards(id,household_id,owner_id,account_id,name,closing_day,due_day) values($1,$2,$3,$4,'Antigo',5,15)",[legacy,h,user,account]);
  await scalar("select create_card_purchase($1,$2,'Legada',100,'2024-01-01',1) as value",[randomUUID(),legacy]);
  const event=await scalar('select id as value from financial_events where card_id=$1',[legacy]),payment=randomUUID();
  await db.query("insert into event_payments values($1,$2,$3,$4,10,'2024-01-15',$5,null)",[payment,h,event,account,user]);
  await db.query("insert into account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values($1,$2,-10,$3,$4,$5)",[h,account,'payment:'+payment,event,user]);
  await db.query('update financial_events set paid_amount=10 where id=$1',[event]);
  const manual=randomUUID();await db.query("insert into financial_events(id,household_id,created_by,owner_id,account_id,title,amount,due_date,kind) values($1,$2,$3,$3,$4,'Despesa bancária preservada',5,'2024-01-01','expense')",[manual,h,user,account]);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)",[otherUser]);const otherH=await scalar("select create_household('Outro','Bruno') as value"),otherAcc=randomUUID();
  await scalar("select create_account($1,$2,$3,'Outro banco',77) as value",[otherAcc,otherH,otherUser]);
  await db.query("select set_config('request.jwt.claim.sub','',false)");
  let sql=(await readFile('supabase/limpar_lancamentos_cartoes.sql','utf8')).replace('COLE_O_ID_DA_FAMILIA_AQUI',h);if(restore)sql=sql.replace('v_repor_saldos boolean := false','v_repor_saldos boolean := true');
  await db.exec(sql);await db.exec(sql);
  assert.equal(Number(await scalar('select balance as value from financial_accounts where id=$1',[account])),restore?1000:940);
  assert.equal(Number(await scalar('select balance as value from financial_accounts where id=$1',[otherAcc])),77);
  assert.equal(Number(await scalar('select count(*)::int as value from credit_cards where household_id=$1',[h])),2);
  assert.equal(await scalar('select id as value from financial_events where id=$1',[manual]),manual);
  for(const table of ['cc_lines','cc_purchases','cc_payments','cc_obligations','cc_recurrences','cc_invoices','card_purchases','invoice_payments'])assert.equal(Number(await scalar(`select count(*)::int as value from ${table} where household_id=$1`,[h])),0);
  assert.equal(Number(await scalar('select sum(amount) as value from account_ledger where account_id=$1',[account])),restore?1000:940);
  assert.ok(Number(await scalar('select count(*)::int as value from cc_audit'))>0);
  console.log(`Limpeza local: migration ${version}, repor_saldos=${restore}, legado/importação, conta/manual/outro grupo e repetição OK`);
 }finally{await db.close()}
}
