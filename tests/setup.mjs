import {PGlite} from '@electric-sql/pglite';
import {pgcrypto} from '@electric-sql/pglite/contrib/pgcrypto';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import assert from 'node:assert/strict';

const db=new PGlite({extensions:{pgcrypto}});
try {
 await db.exec(`create schema extensions;create extension pgcrypto with schema extensions;
 create role authenticated;create role anon;create schema auth;
 create table auth.users(id uuid primary key);
 create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
 grant usage on schema auth,public to authenticated;
 grant execute on function auth.uid() to authenticated;
 alter default privileges in schema public grant select,insert,update,delete on tables to authenticated;`);
 const setup=await readFile('supabase/setup.sql','utf8');
 await db.exec(setup);
 const user=randomUUID();
 await db.query('insert into auth.users values($1)',[user]);
 await db.query("select set_config('request.jwt.claim.sub',$1,false)",[user]);
 await db.exec('set role authenticated');
 const {rows}=await db.query("select public.create_household('Nossa família','Ana') as id");
 assert.equal((await db.query('select household_id from public.household_members')).rows[0].household_id,rows[0].id);
 await db.exec('reset role');
 await assert.rejects(()=>db.exec(setup),/Já existe estrutura/);
 await db.exec('rollback');
 assert.equal((await db.query('select id from public.households')).rows[0].id,rows[0].id);
 // Restore a missing quick-adjustment RPC without changing existing financial data.
 const repair=await readFile('supabase/repair_balance_adjustment.sql','utf8');
 await db.exec('set role authenticated');const account=randomUUID();
 await db.query("select public.create_account($1,$2,$3,'Conta preservada',100)",[account,rows[0].id,user]);
 await db.exec('reset role');
 const before=(await db.query('select count(*)::int as count from account_ledger')).rows[0].count;
 await db.exec('drop function public.adjust_account_balance(uuid,uuid,numeric,numeric)');
 await db.exec(repair);await db.exec(repair);
 assert.equal(Number((await db.query('select balance from financial_accounts where id=$1',[account])).rows[0].balance),100);
 assert.equal((await db.query('select count(*)::int as count from account_ledger')).rows[0].count,before);
 assert.equal((await db.query("select has_function_privilege('anon','public.adjust_account_balance(uuid,uuid,numeric,numeric)','execute') as allowed")).rows[0].allowed,false);
 await db.exec('set role authenticated');const adjust=randomUUID();
 await db.query('select public.adjust_account_balance($1,$2,120,100)',[adjust,account]);
 await db.query('select public.adjust_account_balance($1,$2,120,100)',[adjust,account]);
 await assert.rejects(()=>db.query('select public.adjust_account_balance($1,$2,130,100)',[randomUUID(),account]),/Saldo alterado/);
 assert.equal(Number((await db.query('select balance from financial_accounts where id=$1',[account])).rows[0].balance),120);
 assert.equal((await db.query('select name from financial_accounts where id=$1',[account])).rows[0].name,'Conta preservada');
 await db.exec('reset role');await db.exec(repair);
 assert.equal((await db.query('select count(*)::int as count from account_ledger')).rows[0].count,before+1);
 console.log('Instalação inicial, criação autenticada de família e proteção de dados existentes OK');
 console.log('Reparo repetível do ajuste de saldo, permissões, saldo preservado e ajuste único OK');
} finally {await db.close()}
