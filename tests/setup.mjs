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
 console.log('Instalação inicial, criação autenticada de família e proteção de dados existentes OK');
} finally {await db.close()}
