-- Instalação inicial do Finanças a Dois.
-- Execute no SQL Editor do MESMO Supabase configurado na Vercel.
-- Não use para atualizar banco existente: aplique apenas as migrations pendentes.
-- Gerado a partir de supabase/migrations/001 a 010.
begin;
do $$
begin
 if exists (
  select 1 from information_schema.tables
  where table_schema='public' and table_name in (
   'households','household_members','financial_accounts','financial_events',
   'financial_transfers','household_invites','account_ledger','properties',
   'investments','credit_cards','card_purchases','event_audit',
   'event_payments','invoice_payments','categories','recurrence_requests','invite_attempts','scheduled_transfers','account_edits','income_corrections'
  )
 ) then
  raise exception 'Já existe estrutura do aplicativo. Instalação cancelada sem alterar dados. Aplique somente as migrations pendentes.';
 end if;
end $$;

-- 001_initial.sql

create extension if not exists pgcrypto;
create table if not exists public.households(id uuid primary key default gen_random_uuid(),name text not null,created_at timestamptz default now());
create table if not exists public.household_members(household_id uuid not null references public.households on delete cascade,user_id uuid not null references auth.users on delete cascade,display_name text not null,primary key(household_id,user_id));
create table if not exists public.financial_accounts(id uuid primary key default gen_random_uuid(),household_id uuid not null references public.households on delete cascade,owner_id uuid not null references auth.users, name text not null,balance numeric(16,2) not null default 0,is_primary boolean not null default false,active boolean not null default true,created_at timestamptz default now(),unique(id,household_id));
create unique index if not exists one_primary_account_per_owner on public.financial_accounts(household_id,owner_id) where is_primary and active;
create table if not exists public.financial_events(id uuid primary key default gen_random_uuid(),household_id uuid not null references public.households on delete cascade,created_by uuid not null references auth.users,owner_id uuid not null references auth.users,account_id uuid not null, title text not null,amount numeric(16,2) not null check(amount>0),due_date date not null,kind text not null check(kind in ('income','expense')),status text not null default 'pending' check(status in ('pending','settled','cancelled')),settled_at timestamptz,created_at timestamptz default now(),foreign key(account_id,household_id) references public.financial_accounts(id,household_id));
create table if not exists public.financial_transfers(id uuid primary key default gen_random_uuid(),household_id uuid not null references public.households,from_account uuid not null references public.financial_accounts,to_account uuid not null references public.financial_accounts,amount numeric(16,2) not null check(amount>0),created_by uuid not null references auth.users,created_at timestamptz default now(),check(from_account<>to_account));
create index if not exists events_household_due on public.financial_events(household_id,due_date);
create index if not exists accounts_household on public.financial_accounts(household_id);
create or replace function public.is_household_member(p_household uuid) returns boolean language sql stable security definer set search_path=public as $$select exists(select 1 from public.household_members where household_id=p_household and user_id=auth.uid())$$;
revoke all on function public.is_household_member(uuid) from public;
grant execute on function public.is_household_member(uuid) to authenticated;
alter table public.households enable row level security;
alter table public.household_members enable row level security;
alter table public.financial_accounts enable row level security;
alter table public.financial_events enable row level security;
alter table public.financial_transfers enable row level security;
create policy households_read on public.households for select to authenticated using(public.is_household_member(id));
create policy members_read on public.household_members for select to authenticated using(public.is_household_member(household_id));
create policy accounts_read on public.financial_accounts for select to authenticated using(public.is_household_member(household_id));
create policy accounts_insert on public.financial_accounts for insert to authenticated with check(public.is_household_member(household_id) and exists(select 1 from public.household_members where household_id=financial_accounts.household_id and user_id=owner_id));
create policy events_read on public.financial_events for select to authenticated using(public.is_household_member(household_id));
create policy events_insert on public.financial_events for insert to authenticated with check(public.is_household_member(household_id) and created_by=auth.uid() and exists(select 1 from public.household_members where household_id=financial_events.household_id and user_id=owner_id));
create policy transfers_read on public.financial_transfers for select to authenticated using(public.is_household_member(household_id));
create or replace function public.create_household(p_name text,p_display_name text) returns uuid language plpgsql security definer set search_path=public as $$
declare h uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 insert into public.households(name) values(p_name) returning id into h;
 insert into public.household_members(household_id,user_id,display_name) values(h,auth.uid(),p_display_name);
 return h;
end $$;
create or replace function public.join_household(p_code text,p_display_name text) returns void language plpgsql security definer set search_path=public as $$
declare h uuid;
begin
 if auth.uid() is null then raise exception 'Não autenticado'; end if;
 begin h:=p_code::uuid; exception when invalid_text_representation then raise exception 'Código inválido'; end;
 if not exists(select 1 from public.households where id=h) then raise exception 'Família não encontrada'; end if;
 if (select count(*) from public.household_members where household_id=h)>=2 then raise exception 'Família já possui dois membros'; end if;
 insert into public.household_members(household_id,user_id,display_name) values(h,auth.uid(),p_display_name) on conflict do nothing;
end $$;
create or replace function public.settle_event(p_event_id uuid,p_account_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare ev public.financial_events%rowtype; acc public.financial_accounts%rowtype;
begin
 select * into ev from public.financial_events where id=p_event_id for update;
 if not found or not public.is_household_member(ev.household_id) then raise exception 'Sem permissão'; end if;
 if ev.status<>'pending' then raise exception 'Lançamento já processado'; end if;
 select * into acc from public.financial_accounts where id=p_account_id for update;
 if not found or acc.household_id<>ev.household_id or not acc.active then raise exception 'Conta inválida'; end if;
 update public.financial_accounts set balance=balance+(case when ev.kind='income' then ev.amount else -ev.amount end) where id=p_account_id;
 update public.financial_events set account_id=p_account_id,status='settled',settled_at=now() where id=p_event_id;
end $$;
create or replace function public.transfer_funds(p_from uuid,p_to uuid,p_amount numeric) returns void language plpgsql security definer set search_path=public as $$
declare a public.financial_accounts%rowtype; b public.financial_accounts%rowtype;
begin
 if p_amount<=0 or p_from=p_to then raise exception 'Transferência inválida'; end if;
 perform id from public.financial_accounts where id in(p_from,p_to) order by id for update;
 select * into a from public.financial_accounts where id=p_from;
 select * into b from public.financial_accounts where id=p_to;
 if a.id is null or b.id is null or a.household_id<>b.household_id or not public.is_household_member(a.household_id) or not a.active or not b.active then raise exception 'Contas inválidas'; end if;
 update public.financial_accounts set balance=balance-p_amount where id=p_from;
 update public.financial_accounts set balance=balance+p_amount where id=p_to;
 insert into public.financial_transfers(household_id,from_account,to_account,amount,created_by) values(a.household_id,p_from,p_to,p_amount,auth.uid());
end $$;
revoke all on function public.create_household(text,text),public.join_household(text,text),public.settle_event(uuid,uuid),public.transfer_funds(uuid,uuid,numeric) from public;
grant execute on function public.create_household(text,text),public.join_household(text,text),public.settle_event(uuid,uuid),public.transfer_funds(uuid,uuid,numeric) to authenticated;

-- 002_security_ledger.sql
-- Apply after 001, first in a development project. No existing financial data is removed.

create table public.household_invites(token_hash text primary key,household_id uuid not null references public.households,expires_at timestamptz not null,used_by uuid references auth.users);

alter table public.household_invites enable row level security;

create function public.create_invite(p_household uuid) returns text language plpgsql security definer set search_path=public,extensions as $$

declare token text;

begin

 if not public.is_household_member(p_household) then raise exception 'Sem permissão'; end if;

 perform 1 from public.households where id=p_household for update;

 if (select count(*) from public.household_members where household_id=p_household)>=2 then raise exception 'Família completa'; end if;

 token:=encode(gen_random_bytes(32),'hex');

 insert into public.household_invites values(encode(digest(token,'sha256'),'hex'),p_household,now()+interval '24 hours',null);return token;

end $$;

create or replace function public.join_household(p_code text,p_display_name text) returns void language plpgsql security definer set search_path=public,extensions as $$

declare invitation public.household_invites%rowtype;

begin

 if auth.uid() is null then raise exception 'Não autenticado'; end if;

 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));

 if exists(select 1 from public.household_members where user_id=auth.uid()) then raise exception 'Usuário já possui família'; end if;

 select * into invitation from public.household_invites where token_hash=encode(digest(p_code,'sha256'),'hex') for update;

 if not found or invitation.used_by is not null or invitation.expires_at<=now() then raise exception 'Convite inválido ou expirado'; end if;

 perform 1 from public.households where id=invitation.household_id for update;

 if (select count(*) from public.household_members where household_id=invitation.household_id)>=2 then raise exception 'Família completa'; end if;

 if length(trim(p_display_name)) not between 1 and 120 then raise exception 'Nome inválido'; end if;

 insert into public.household_members values(invitation.household_id,auth.uid(),trim(p_display_name));

 update public.household_invites set used_by=auth.uid() where token_hash=invitation.token_hash;

end $$;

create or replace function public.create_household(p_name text,p_display_name text) returns uuid language plpgsql security definer set search_path=public,extensions as $$

declare h uuid;

begin

 if auth.uid() is null then raise exception 'Não autenticado'; end if;

 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));

 if exists(select 1 from public.household_members where user_id=auth.uid()) then raise exception 'Usuário já possui família'; end if;

 if length(trim(p_name)) not between 1 and 120 or length(trim(p_display_name)) not between 1 and 120 then raise exception 'Nome inválido'; end if;

 insert into public.households(name) values(trim(p_name)) returning id into h;

 insert into public.household_members values(h,auth.uid(),trim(p_display_name));return h;

end $$;

create table public.account_ledger(id uuid primary key default gen_random_uuid(),household_id uuid not null references public.households,account_id uuid not null references public.financial_accounts,amount numeric(16,2) not null,operation_key text not null,event_id uuid references public.financial_events,actor_id uuid references auth.users,occurred_at timestamptz not null default now(),unique(account_id,operation_key));

alter table public.account_ledger enable row level security;

create policy ledger_read on public.account_ledger for select to authenticated using(public.is_household_member(household_id));

insert into public.account_ledger(household_id,account_id,amount,operation_key) select household_id,id,balance,'opening' from public.financial_accounts;

-- Reconstruct known legacy postings before installing the balance trigger.
insert into public.account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id,occurred_at)
select household_id,account_id,case when kind='income' then amount else -amount end,'legacy-settle:'||id,id,created_by,coalesce(settled_at,created_at) from public.financial_events where status='settled';
insert into public.account_ledger(household_id,account_id,amount,operation_key,actor_id,occurred_at)
select household_id,from_account,-amount,'legacy-transfer:'||id,created_by,created_at from public.financial_transfers
union all select household_id,to_account,amount,'legacy-transfer:'||id,created_by,created_at from public.financial_transfers;
update public.account_ledger opening set amount=opening.amount-coalesce((select sum(posting.amount) from public.account_ledger posting where posting.account_id=opening.account_id and posting.operation_key<>'opening'),0) where opening.operation_key='opening';
create function public.post_ledger() returns trigger language plpgsql security definer set search_path=public,extensions as $$

begin

 update public.financial_accounts set balance=balance+new.amount where id=new.account_id and household_id=new.household_id;

 if not found then raise exception 'Conta inválida'; end if;return new;

end $$;

create trigger ledger_post after insert on public.account_ledger for each row execute function public.post_ledger();

create function public.open_account_ledger() returns trigger language plpgsql security definer set search_path=public,extensions as $$

begin

 update public.financial_accounts set balance=0 where id=new.id;

 insert into public.account_ledger(household_id,account_id,amount,operation_key,actor_id) values(new.household_id,new.id,new.balance,'opening',auth.uid());return new;

end $$;

create trigger account_open after insert on public.financial_accounts for each row execute function public.open_account_ledger();

create or replace function public.settle_event(p_event_id uuid,p_account_id uuid) returns void language plpgsql security definer set search_path=public,extensions as $$

declare ev public.financial_events%rowtype;

begin

 select * into ev from public.financial_events where id=p_event_id for update;

 if not found or not public.is_household_member(ev.household_id) then raise exception 'Sem permissão'; end if;

 if ev.status='settled' then return; end if;

 if ev.status<>'pending' then raise exception 'Lançamento cancelado'; end if;

 perform 1 from public.financial_accounts where id=p_account_id and household_id=ev.household_id and active for update;

 if not found then raise exception 'Conta inválida'; end if;

 insert into public.account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(ev.household_id,p_account_id,case when ev.kind='income' then ev.amount else -ev.amount end,'settle:'||ev.id,ev.id,auth.uid());

 update public.financial_events set account_id=p_account_id,status='settled',settled_at=now() where id=ev.id;

end $$;

create function public.reverse_event(p_event_id uuid) returns void language plpgsql security definer set search_path=public,extensions as $$

declare ev public.financial_events%rowtype;

begin

 select * into ev from public.financial_events where id=p_event_id for update;

 if not found or not public.is_household_member(ev.household_id) then raise exception 'Sem permissão'; end if;

 if ev.status='cancelled' then return; end if;

 if ev.status<>'settled' then raise exception 'Lançamento não confirmado'; end if;

 insert into public.account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(ev.household_id,ev.account_id,case when ev.kind='income' then -ev.amount else ev.amount end,'reverse:'||ev.id,ev.id,auth.uid());

 update public.financial_events set status='cancelled' where id=ev.id;

end $$;

revoke execute on function public.transfer_funds(uuid,uuid,numeric) from authenticated;

create function public.transfer_funds(p_from uuid,p_to uuid,p_amount numeric,p_key uuid) returns void language plpgsql security definer set search_path=public,extensions as $$

declare a public.financial_accounts%rowtype;b public.financial_accounts%rowtype;

begin

 if p_key is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_from=p_to then raise exception 'Transferência inválida'; end if;

 perform pg_advisory_xact_lock(hashtextextended(p_key::text,1));

 perform id from public.financial_accounts where id in(p_from,p_to) order by id for update;

 select * into a from public.financial_accounts where id=p_from;select * into b from public.financial_accounts where id=p_to;

 if a.id is null or b.id is null or a.household_id<>b.household_id or not public.is_household_member(a.household_id) or not a.active or not b.active then raise exception 'Contas inválidas'; end if;

 if exists(select 1 from public.account_ledger where operation_key='transfer:'||p_key) then

 if not exists(select 1 from public.account_ledger where operation_key='transfer:'||p_key and account_id=p_from and amount=-p_amount) or not exists(select 1 from public.account_ledger where operation_key='transfer:'||p_key and account_id=p_to and amount=p_amount) then raise exception 'Chave já utilizada'; end if;return;end if;

 insert into public.account_ledger(household_id,account_id,amount,operation_key,actor_id) values(a.household_id,p_from,-p_amount,'transfer:'||p_key,auth.uid()),(a.household_id,p_to,p_amount,'transfer:'||p_key,auth.uid());

 insert into public.financial_transfers(household_id,from_account,to_account,amount,created_by) values(a.household_id,p_from,p_to,p_amount,auth.uid());

end $$;

create function public.set_primary_account(p_account uuid) returns void language plpgsql security definer set search_path=public,extensions as $$

declare a public.financial_accounts%rowtype;

begin

 select * into a from public.financial_accounts where id=p_account;

 if not found or not public.is_household_member(a.household_id) or not a.active then raise exception 'Sem permissão'; end if;

 perform 1 from public.households where id=a.household_id for update;

 update public.financial_accounts set is_primary=false where household_id=a.household_id and owner_id=a.owner_id and is_primary;

 update public.financial_accounts set is_primary=true where id=p_account;

end $$;

revoke all on function public.create_invite(uuid),public.reverse_event(uuid),public.transfer_funds(uuid,uuid,numeric,uuid),public.set_primary_account(uuid),public.post_ledger(),public.open_account_ledger() from public;

grant execute on function public.create_invite(uuid),public.reverse_event(uuid),public.transfer_funds(uuid,uuid,numeric,uuid),public.set_primary_account(uuid) to authenticated;

-- Prevent forged settled events and invalid ownership on direct inserts.

drop policy events_insert on public.financial_events;

create policy events_insert on public.financial_events for insert to authenticated with check(

 public.is_household_member(household_id) and created_by=auth.uid() and status='pending' and settled_at is null

 and exists(select 1 from public.household_members m where m.household_id=financial_events.household_id and m.user_id=owner_id)

 and exists(select 1 from public.financial_accounts a where a.id=account_id and a.household_id=financial_events.household_id and a.active)

);

alter table public.financial_events add constraint event_title_valid check(length(trim(title)) between 1 and 200) not valid;

alter table public.financial_accounts add constraint account_name_valid check(length(trim(name)) between 1 and 120) not valid;


-- 003_planning.sql
create table public.properties(id uuid primary key default gen_random_uuid(),household_id uuid not null references public.households,name text not null check(length(trim(name)) between 1 and 120),estimated_value numeric(16,2) not null default 0 check(estimated_value>=0),unique(id,household_id));
create table public.investments(id uuid primary key default gen_random_uuid(),household_id uuid not null references public.households,owner_id uuid not null references auth.users,name text not null,kind text not null,amount numeric(16,2) not null check(amount>=0),liquidity_date date,unique(id,household_id));
alter table public.financial_events add column category text not null default 'Outros',add column property_id uuid,add column series_id uuid,add column variable_amount boolean not null default false;
alter table public.financial_events add constraint event_property_fk foreign key(property_id,household_id) references public.properties(id,household_id);
create table public.credit_cards(id uuid primary key default gen_random_uuid(),household_id uuid not null references public.households,owner_id uuid not null references auth.users,account_id uuid not null,name text not null,closing_day integer not null check(closing_day between 1 and 31),due_day integer not null check(due_day between 1 and 31),foreign key(account_id,household_id) references public.financial_accounts(id,household_id),unique(id,household_id));
create table public.card_purchases(id uuid primary key,household_id uuid not null references public.households,card_id uuid not null,title text not null,amount numeric(16,2) not null check(amount>0),purchase_date date not null,installments integer not null check(installments between 1 and 120),created_by uuid not null references auth.users,foreign key(card_id,household_id) references public.credit_cards(id,household_id));
alter table public.financial_events add column card_id uuid,add column purchase_id uuid references public.card_purchases,add column installment integer;
alter table public.financial_events add constraint event_card_fk foreign key(card_id,household_id) references public.credit_cards(id,household_id);
-- Card installments are projected expenses. Only actual invoice payments post to the bank ledger.
create function public.create_card_purchase(p_id uuid,p_card uuid,p_title text,p_amount numeric,p_date date,p_installments integer) returns void language plpgsql security definer set search_path=public as $$
declare c public.credit_cards%rowtype; month_start date; closing date; due date; part numeric;remaining numeric;i integer;
begin
 select * into c from public.credit_cards where id=p_card;
 if not found or not public.is_household_member(c.household_id) then raise exception 'Sem permissão'; end if;
 if p_id is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_installments not between 1 and 120 or p_date is null or length(trim(p_title)) not between 1 and 200 or p_amount*100<p_installments then raise exception 'Compra inválida'; end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,2));
 if exists(select 1 from public.card_purchases where id=p_id) then
 if not exists(select 1 from public.card_purchases where id=p_id and card_id=p_card and title=p_title and amount=p_amount and purchase_date=p_date and installments=p_installments) then raise exception 'Chave já utilizada';end if;return;end if;
 insert into public.card_purchases values(p_id,c.household_id,p_card,p_title,p_amount,p_date,p_installments,auth.uid());
 month_start:=date_trunc('month',p_date)::date;
 closing:=month_start+least(c.closing_day,extract(day from month_start+interval '1 month - 1 day')::integer)-1;
 if p_date>=closing then month_start:=(month_start+interval '1 month')::date;end if;
 if c.due_day<=c.closing_day then month_start:=(month_start+interval '1 month')::date;end if;
 part:=trunc(p_amount/p_installments,2);remaining:=p_amount;
 for i in 1..p_installments loop
 due:=month_start+least(c.due_day,extract(day from month_start+interval '1 month - 1 day')::integer)-1;
 insert into public.financial_events(household_id,created_by,owner_id,account_id,title,amount,due_date,kind,category,card_id,purchase_id,installment) values(c.household_id,auth.uid(),c.owner_id,c.account_id,p_title||' ('||i||'/'||p_installments||')',case when i=p_installments then remaining else part end,due,'expense','Cartão',c.id,p_id,i);
 remaining:=remaining-part;month_start:=(month_start+interval '1 month')::date;
 end loop;
end $$;
create function public.create_series(p_id uuid,p_household uuid,p_owner uuid,p_account uuid,p_title text,p_amount numeric,p_due date,p_kind text,p_months integer,p_category text,p_property uuid,p_variable boolean) returns void language plpgsql security definer set search_path=public as $$
declare i integer;month_start date;day_num integer;due date;
begin
 if not public.is_household_member(p_household) or not exists(select 1 from public.household_members where household_id=p_household and user_id=p_owner) or not exists(select 1 from public.financial_accounts where id=p_account and household_id=p_household and active) then raise exception 'Sem permissão';end if;
 if p_id is null or p_due is null or p_months is null or p_months not between 1 and 60 or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_kind not in ('income','expense') or length(trim(p_title)) not between 1 and 200 then raise exception 'Lançamento inválido';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,3));
 if exists(select 1 from public.financial_events where series_id=p_id) then return;end if;
 day_num:=extract(day from p_due)::integer;
 for i in 0..p_months-1 loop
 month_start:=(date_trunc('month',p_due)+make_interval(months=>i))::date;
 due:=month_start+least(day_num,extract(day from month_start+interval '1 month - 1 day')::integer)-1;
 insert into public.financial_events(household_id,created_by,owner_id,account_id,title,amount,due_date,kind,category,property_id,series_id,variable_amount) values(p_household,auth.uid(),p_owner,p_account,p_title,p_amount,due,p_kind,p_category,p_property,p_id,p_variable);
 end loop;
end $$;
create function public.edit_occurrence(p_event uuid,p_amount numeric,p_due date,p_cancel boolean) returns void language plpgsql security definer set search_path=public as $$
declare e public.financial_events%rowtype;
begin
 select * into e from public.financial_events where id=p_event for update;
 if not found or not public.is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if e.status<>'pending' or e.card_id is not null then raise exception 'Apenas ocorrências pendentes sem cartão';end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_due is null then raise exception 'Valor ou data inválidos';end if;
 update public.financial_events set amount=p_amount,due_date=p_due,status=case when p_cancel then 'cancelled' else 'pending' end where id=p_event;
end $$;
create table public.event_audit(id bigint generated always as identity primary key,household_id uuid not null,actor_id uuid,event_id uuid not null,before_data jsonb,after_data jsonb,occurred_at timestamptz not null default now());
alter table public.event_audit enable row level security;
create policy audit_read on public.event_audit for select to authenticated using(public.is_household_member(household_id));
create function public.audit_event() returns trigger language plpgsql security definer set search_path=public as $$
begin insert into public.event_audit(household_id,actor_id,event_id,before_data,after_data) values(new.household_id,auth.uid(),new.id,case when tg_op='UPDATE' then to_jsonb(old) else null end,to_jsonb(new));return new;end $$;
create trigger event_audit after insert or update on public.financial_events for each row execute function public.audit_event();
alter table public.properties enable row level security;
alter table public.investments enable row level security;
alter table public.credit_cards enable row level security;
alter table public.card_purchases enable row level security;
create policy properties_read on public.properties for select to authenticated using(public.is_household_member(household_id));
create policy properties_insert on public.properties for insert to authenticated with check(public.is_household_member(household_id));
create policy investments_read on public.investments for select to authenticated using(public.is_household_member(household_id));
create policy investments_insert on public.investments for insert to authenticated with check(public.is_household_member(household_id) and exists(select 1 from public.household_members m where m.household_id=investments.household_id and m.user_id=owner_id));
create policy cards_read on public.credit_cards for select to authenticated using(public.is_household_member(household_id));
create policy cards_insert on public.credit_cards for insert to authenticated with check(public.is_household_member(household_id) and exists(select 1 from public.household_members m where m.household_id=credit_cards.household_id and m.user_id=owner_id) and exists(select 1 from public.financial_accounts a where a.id=account_id and a.household_id=credit_cards.household_id and a.active));
create policy purchases_read on public.card_purchases for select to authenticated using(public.is_household_member(household_id));
revoke all on function public.create_card_purchase(uuid,uuid,text,numeric,date,integer),public.create_series(uuid,uuid,uuid,uuid,text,numeric,date,text,integer,text,uuid,boolean),public.edit_occurrence(uuid,numeric,date,boolean),public.audit_event() from public;
grant execute on function public.create_card_purchase(uuid,uuid,text,numeric,date,integer),public.create_series(uuid,uuid,uuid,uuid,text,numeric,date,text,integer,text,uuid,boolean),public.edit_occurrence(uuid,numeric,date,boolean) to authenticated;

-- 004_partial_payments.sql
alter table public.financial_events add column paid_amount numeric(16,2) not null default 0 check(paid_amount>=0 and paid_amount<=amount);
update public.financial_events set paid_amount=amount where status='settled';
create table public.event_payments(id uuid primary key,household_id uuid not null references public.households,event_id uuid not null references public.financial_events,account_id uuid not null references public.financial_accounts,amount numeric(16,2) not null,paid_date date not null,actor_id uuid not null references auth.users,reversed_at timestamptz);
alter table public.event_payments enable row level security;
create policy payments_read on public.event_payments for select to authenticated using(public.is_household_member(household_id));
create function public.pay_event(p_id uuid,p_event uuid,p_account uuid,p_amount numeric,p_date date,p_expected_paid numeric) returns void language plpgsql security definer set search_path=public as $$
declare e public.financial_events%rowtype;existing public.event_payments%rowtype;
begin
 select * into e from public.financial_events where id=p_event for update;
 if not found or not public.is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if p_id is null then raise exception 'Chave obrigatória';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,4));
 select * into existing from public.event_payments where id=p_id;
 if found then
 if existing.event_id<>p_event or existing.account_id<>p_account or existing.amount<>p_amount or existing.paid_date<>p_date then raise exception 'Chave já utilizada';end if;return;end if;
 if p_expected_paid is null or e.paid_amount<>p_expected_paid then raise exception 'Lançamento alterado. Atualize a página';end if;
 if e.status<>'pending' or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount>e.amount-e.paid_amount or p_date is null or p_date>(now() at time zone 'America/Fortaleza')::date then raise exception 'Pagamento inválido';end if;
 perform 1 from public.financial_accounts where id=p_account and household_id=e.household_id and active for update;
 if not found then raise exception 'Conta inválida';end if;
 insert into public.event_payments values(p_id,e.household_id,e.id,p_account,p_amount,p_date,auth.uid(),null);
 insert into public.account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(e.household_id,p_account,case when e.kind='income' then p_amount else -p_amount end,'payment:'||p_id,e.id,auth.uid());
 update public.financial_events set paid_amount=paid_amount+p_amount,status=case when paid_amount+p_amount=amount then 'settled' else 'pending' end,settled_at=case when paid_amount+p_amount=amount then now() else null end where id=e.id;
end $$;
-- Legacy endpoint is no longer exposed: all confirmations require retry and concurrency keys.
revoke execute on function public.settle_event(uuid,uuid) from authenticated;
create or replace function public.reverse_event(p_event_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare e public.financial_events%rowtype;entry record;operation uuid:=gen_random_uuid();
begin
 select * into e from public.financial_events where id=p_event_id for update;
 if not found or not public.is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if e.paid_amount=0 then return;end if;
 perform id from public.financial_accounts where id in(select account_id from public.account_ledger where event_id=e.id) order by id for update;
 for entry in select account_id,sum(amount) amount from public.account_ledger where event_id=e.id group by account_id having sum(amount)<>0 loop
 insert into public.account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(e.household_id,entry.account_id,-entry.amount,'reversal:'||operation,e.id,auth.uid());
 end loop;
 update public.event_payments set reversed_at=now() where event_id=e.id and reversed_at is null;
 update public.financial_events set status='pending',paid_amount=0,settled_at=null where id=e.id;
end $$;
-- A partially paid event cannot be reduced below its confirmed amount or cancelled.
create or replace function public.edit_occurrence(p_event uuid,p_amount numeric,p_due date,p_cancel boolean) returns void language plpgsql security definer set search_path=public as $$
declare e public.financial_events%rowtype;
begin
 select * into e from public.financial_events where id=p_event for update;
 if not found or not public.is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if e.status<>'pending' or e.card_id is not null or e.paid_amount>0 then raise exception 'Estorne os pagamentos antes de editar';end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_due is null then raise exception 'Valor ou data inválidos';end if;
 update public.financial_events set amount=p_amount,due_date=p_due,status=case when p_cancel then 'cancelled' else 'pending' end where id=p_event;
end $$;
-- Supabase grants table privileges by default; RLS restricts every read, mutations use RPC only.
revoke all on function public.pay_event(uuid,uuid,uuid,numeric,date,numeric) from public;
grant execute on function public.pay_event(uuid,uuid,uuid,numeric,date,numeric) to authenticated;
drop policy events_insert on public.financial_events;
create policy events_insert on public.financial_events for insert to authenticated with check(public.is_household_member(household_id) and created_by=auth.uid() and status='pending' and settled_at is null and paid_amount=0 and card_id is null and purchase_id is null and series_id is null and exists(select 1 from public.household_members m where m.household_id=financial_events.household_id and m.user_id=owner_id) and exists(select 1 from public.financial_accounts a where a.id=account_id and a.household_id=financial_events.household_id and a.active));

-- 005_integrity.sql
create function public.default_primary_account() returns trigger language plpgsql security definer set search_path=public as $$
begin
 perform 1 from public.households where id=new.household_id for update;
 if not exists(select 1 from public.financial_accounts where household_id=new.household_id and owner_id=new.owner_id and active and is_primary) then new.is_primary:=true;end if;return new;
end $$;
create trigger account_primary before insert on public.financial_accounts for each row execute function public.default_primary_account();
revoke all on function public.default_primary_account() from public;
alter table public.financial_accounts add constraint balance_finite check(balance<>'NaN'::numeric and abs(balance)<=9000000000000) not valid;
alter table public.financial_events add constraint amount_finite check(amount<>'NaN'::numeric and amount<=9000000000000) not valid;
alter table public.account_ledger add constraint ledger_amount_finite check(amount<>'NaN'::numeric and abs(amount)<=9000000000000) not valid;

-- 006_invoice_payments.sql
create table public.invoice_payments(id uuid primary key,household_id uuid not null references public.households,card_id uuid not null references public.credit_cards,due_date date not null,account_id uuid not null references public.financial_accounts,amount numeric(16,2) not null,paid_date date not null);
alter table public.invoice_payments enable row level security;
create policy invoice_payments_read on public.invoice_payments for select to authenticated using(public.is_household_member(household_id));
create function public.pay_invoice(p_id uuid,p_card uuid,p_due date,p_account uuid,p_amount numeric,p_date date) returns void language plpgsql security definer set search_path=public as $$
declare c public.credit_cards%rowtype;previous public.invoice_payments%rowtype;e public.financial_events%rowtype;remaining numeric;portion numeric;
begin
 select * into c from public.credit_cards where id=p_card;
 if not found or not public.is_household_member(c.household_id) then raise exception 'Sem permissão';end if;
 if p_id is null or p_due is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) then raise exception 'Pagamento inválido';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,5));
 select * into previous from public.invoice_payments where id=p_id;
 if found then
 if previous.card_id<>p_card or previous.due_date<>p_due or previous.account_id<>p_account or previous.amount<>p_amount or previous.paid_date<>p_date then raise exception 'Chave já utilizada';end if;return;end if;
 perform id from public.financial_events where card_id=p_card and due_date=p_due order by id for update;
 if p_amount>coalesce((select sum(amount-paid_amount) from public.financial_events where card_id=p_card and due_date=p_due and status='pending'),0) then raise exception 'Valor superior ao saldo da fatura';end if;
 insert into public.invoice_payments values(p_id,c.household_id,p_card,p_due,p_account,p_amount,p_date);
 remaining:=p_amount;
 for e in select * from public.financial_events where card_id=p_card and due_date=p_due and status='pending' order by id loop
 exit when remaining=0;portion:=least(remaining,e.amount-e.paid_amount);
 perform public.pay_event(gen_random_uuid(),e.id,p_account,portion,p_date,e.paid_amount);
 remaining:=remaining-portion;
 end loop;
end $$;
revoke all on function public.pay_invoice(uuid,uuid,date,uuid,numeric,date) from public;
grant execute on function public.pay_invoice(uuid,uuid,date,uuid,numeric,date) to authenticated;

-- 007_accounts.sql
create function public.create_account(p_id uuid,p_household uuid,p_owner uuid,p_name text,p_balance numeric) returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.is_household_member(p_household) or not exists(select 1 from public.household_members where household_id=p_household and user_id=p_owner) then raise exception 'Sem permissão';end if;
 if p_id is null or p_balance is null or p_balance<>round(p_balance,2) or p_balance='NaN'::numeric or abs(p_balance)>9000000000000 or length(trim(p_name)) not between 1 and 120 then raise exception 'Conta inválida';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,6));
 if exists(select 1 from public.financial_accounts where id=p_id) then
 if not exists(select 1 from public.financial_accounts a join public.account_ledger l on l.account_id=a.id and l.operation_key='opening' where a.id=p_id and a.household_id=p_household and a.owner_id=p_owner and a.name=trim(p_name) and l.amount=p_balance) then raise exception 'Chave já utilizada';end if;return;end if;
 insert into public.financial_accounts(id,household_id,owner_id,name,balance) values(p_id,p_household,p_owner,trim(p_name),p_balance);
end $$;
revoke all on function public.create_account(uuid,uuid,uuid,text,numeric) from public;
grant execute on function public.create_account(uuid,uuid,uuid,text,numeric) to authenticated;
-- Direct inserts remain protected by RLS for legacy clients, but the app uses the retry-safe RPC.

-- 008_modernization.sql
-- Additive modernization; preserves historical events and balances.
alter table public.financial_accounts add column color text not null default '#6366f1' check(color ~ '^#[0-9a-fA-F]{6}$');
create function public.set_account_color(p_account uuid,p_color text) returns void language plpgsql security definer set search_path=public as $$
begin
 if p_color is null or p_color !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Cor inválida';end if;
 update financial_accounts set color=p_color where id=p_account and public.is_household_member(household_id);
 if not found then raise exception 'Sem permissão';end if;
end $$;
create function public.rename_member(p_name text) returns void language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or p_name is null or length(trim(p_name)) not between 1 and 120 or p_name like '%@%' then raise exception 'Informe seu nome';end if;
 update household_members set display_name=trim(p_name) where user_id=auth.uid();
end $$;
create table public.categories(id uuid primary key default gen_random_uuid(),household_id uuid not null references households,name text not null check(length(trim(name)) between 1 and 100),kind text not null check(kind in ('income','expense')),color text not null check(color ~ '^#[0-9a-fA-F]{6}$'),icon text not null check(icon in ('wallet','home','heart','car','shopping','briefcase')),active boolean not null default true,unique(household_id,kind,name));
alter table categories enable row level security;
create policy categories_read on categories for select to authenticated using(is_household_member(household_id));
create policy categories_add on categories for insert to authenticated with check(is_household_member(household_id));
create policy categories_edit on categories for update to authenticated using(is_household_member(household_id)) with check(is_household_member(household_id));
-- No delete policy. Deactivation preserves all historic category labels.
create table public.recurrence_requests(id uuid primary key,household_id uuid not null references households,parameters jsonb not null);
alter table recurrence_requests enable row level security;
create function public.schedule_events(p_id uuid,p_household uuid,p_owner uuid,p_account uuid,p_title text,p_amount numeric,p_due date,p_kind text,p_category text,p_variable boolean,p_unit text,p_every integer,p_end date,p_property uuid default null) returns void language plpgsql security definer set search_path=public as $$
declare params jsonb;previous recurrence_requests%rowtype;d date;anchor date;i integer:=0;last_date date;
begin
 if not is_household_member(p_household) or not exists(select 1 from household_members where household_id=p_household and user_id=p_owner) or not exists(select 1 from financial_accounts where id=p_account and household_id=p_household and active) then raise exception 'Sem permissão';end if;
 if p_id is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_title is null or length(trim(p_title)) not between 1 and 200 or p_due is null or p_kind is null or p_kind not in ('income','expense') or p_unit is null or p_unit not in ('once','days','months') or p_every is null or p_every not between 1 and 365 or p_category is null or length(p_category)>100 or p_variable is null or (p_end is not null and p_end<p_due) then raise exception 'Lançamento inválido';end if;
 params:=jsonb_build_array(p_household,p_owner,p_account,p_title,p_amount,p_due,p_kind,p_category,p_variable,p_unit,p_every,p_end,p_property);
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,8));
 select * into previous from recurrence_requests where id=p_id;
 if found then if previous.household_id<>p_household or previous.parameters<>params then raise exception 'Chave já utilizada';end if;return;end if;
 insert into recurrence_requests values(p_id,p_household,params);
 last_date:=coalesce(p_end,p_due+interval '1 year');
 if last_date>p_due+interval '5 years' then raise exception 'Limite de cinco anos';end if;
 loop
 if p_unit='months' then
 anchor:=(date_trunc('month',p_due)+make_interval(months=>i*p_every))::date;
 d:=anchor+least(extract(day from p_due)::int,extract(day from anchor+interval '1 month - 1 day')::int)-1;
 else d:=p_due+i*p_every;end if;
 exit when d>last_date;
 if i>=2000 then raise exception 'Muitas ocorrências';end if;
 insert into financial_events(household_id,created_by,owner_id,account_id,title,amount,due_date,kind,category,series_id,variable_amount,property_id) values(p_household,auth.uid(),p_owner,p_account,trim(p_title),p_amount,d,p_kind,p_category,p_id,p_variable,p_property);
 exit when p_unit='once';i:=i+1;
 end loop;
end $$;
create function public.edit_future(p_event uuid,p_amount numeric) returns void language plpgsql security definer set search_path=public as $$
declare e financial_events%rowtype;
begin
 select * into e from financial_events where id=p_event for update;
 if not found or not is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or e.series_id is null or e.card_id is not null then raise exception 'Série inválida';end if;
 update financial_events set amount=p_amount where household_id=e.household_id and series_id=e.series_id and due_date>=e.due_date and status='pending' and paid_amount=0;
end $$;
create function public.estimate_variable() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.variable_amount and new.series_id is not null and new.status='settled' and old.status<>'settled' then
 update financial_events set amount=new.amount where series_id=new.series_id and household_id=new.household_id and due_date>new.due_date and status='pending' and paid_amount=0;
 end if;return new;
end $$;
create trigger variable_estimate after update on financial_events for each row execute function estimate_variable();
alter table household_invites add column revoked boolean not null default false;
create policy invites_read on household_invites for select to authenticated using(is_household_member(household_id));
create function public.issue_invite(p_household uuid,p_code text,p_hours integer) returns text language plpgsql security definer set search_path=public,extensions as $$
declare code text;
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 if p_hours is null or p_hours not between 1 and 168 then raise exception 'Validade de 1 a 168 horas';end if;
 code:=case when coalesce(trim(p_code),'')='' then upper(encode(gen_random_bytes(32),'hex')) else upper(trim(p_code)) end;
 if code !~ '^[A-Z0-9-]{8,64}$' then raise exception 'Código deve ter de 8 a 64 letras, números ou hífen';end if;
 insert into household_invites(token_hash,household_id,expires_at) values(encode(digest(code,'sha256'),'hex'),p_household,now()+make_interval(hours=>p_hours));
 return code;
exception when unique_violation then raise exception 'Código já utilizado. Escolha outro';
end $$;
create function public.revoke_invite(p_hash text) returns void language plpgsql security definer set search_path=public as $$
begin
 update household_invites set revoked=true where token_hash=p_hash and is_household_member(household_id);
 if not found then raise exception 'Sem permissão';end if;
end $$;
-- Failed attempts must commit, so return false instead of raising for invalid codes.
create table public.invite_attempts(user_id uuid primary key references auth.users,window_start timestamptz not null,attempts integer not null);
alter table invite_attempts enable row level security;
create function public.accept_invite(p_code text,p_name text) returns boolean language plpgsql security definer set search_path=public,extensions as $$
declare invitation household_invites%rowtype;attempt invite_attempts%rowtype;
begin
 if auth.uid() is null then raise exception 'Não autenticado';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
 if p_name is null or length(trim(p_name)) not between 1 and 120 or p_name like '%@%' then raise exception 'Informe seu nome';end if;
 if exists(select 1 from household_members where user_id=auth.uid()) then raise exception 'Usuário já possui família';end if;
 insert into invite_attempts values(auth.uid(),now(),0) on conflict do nothing;
 select * into attempt from invite_attempts where user_id=auth.uid() for update;
 if attempt.window_start<now()-interval '1 hour' then update invite_attempts set window_start=now(),attempts=0 where user_id=auth.uid();elsif attempt.attempts>=10 then return false;end if;
 update invite_attempts set attempts=attempts+1 where user_id=auth.uid();
 select * into invitation from household_invites where token_hash in(encode(digest(upper(trim(p_code)),'sha256'),'hex'),encode(digest(trim(p_code),'sha256'),'hex')) for update;
 if not found or invitation.used_by is not null or invitation.revoked or invitation.expires_at<=now() then return false;end if;
 perform 1 from households where id=invitation.household_id for update;
 insert into household_members values(invitation.household_id,auth.uid(),trim(p_name));
 update household_invites set used_by=auth.uid() where token_hash=invitation.token_hash;
 return true;
end $$;
-- Close legacy invite endpoints to prevent bypass of revocation/rate limits.
revoke execute on function public.join_household(text,text),public.create_invite(uuid) from authenticated;
revoke all on function public.set_account_color(uuid,text),public.rename_member(text),public.schedule_events(uuid,uuid,uuid,uuid,text,numeric,date,text,text,boolean,text,integer,date,uuid),public.edit_future(uuid,numeric),public.estimate_variable(),public.issue_invite(uuid,text,integer),public.revoke_invite(text),public.accept_invite(text,text) from public;
grant execute on function public.set_account_color(uuid,text),public.rename_member(text),public.schedule_events(uuid,uuid,uuid,uuid,text,numeric,date,text,text,boolean,text,integer,date,uuid),public.edit_future(uuid,numeric),public.issue_invite(uuid,text,integer),public.revoke_invite(text),public.accept_invite(text,text) to authenticated;
notify pgrst,'reload schema';

-- 009_scheduled_transfers.sql
create table public.scheduled_transfers(id uuid primary key,household_id uuid not null references households,from_account uuid not null,to_account uuid not null,amount numeric(16,2) not null check(amount>0 and amount<>'NaN'::numeric),due_date date not null,status text not null default 'pending' check(status in ('pending','settled')),foreign key(from_account,household_id) references financial_accounts(id,household_id),foreign key(to_account,household_id) references financial_accounts(id,household_id),check(from_account<>to_account));
alter table scheduled_transfers enable row level security;
create policy scheduled_read on scheduled_transfers for select to authenticated using(is_household_member(household_id));
create function public.schedule_transfer(p_id uuid,p_from uuid,p_to uuid,p_amount numeric,p_date date) returns void language plpgsql security definer set search_path=public as $$
declare h uuid;previous scheduled_transfers%rowtype;
begin
 select household_id into h from financial_accounts where id=p_from and active;
 if h is null or not is_household_member(h) or not exists(select 1 from financial_accounts where id=p_to and household_id=h and active) then raise exception 'Sem permissão';end if;
 if p_id is null or p_date is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount='NaN'::numeric then raise exception 'Transferência inválida';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,9));
 select * into previous from scheduled_transfers where id=p_id;
 if found then if previous.household_id<>h or previous.from_account<>p_from or previous.to_account<>p_to or previous.amount<>p_amount or previous.due_date<>p_date then raise exception 'Chave já utilizada';end if;return;end if;
 insert into scheduled_transfers(id,household_id,from_account,to_account,amount,due_date) values(p_id,h,p_from,p_to,p_amount,p_date);
end $$;
create function public.execute_transfer(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare t scheduled_transfers%rowtype;
begin
 select * into t from scheduled_transfers where id=p_id for update;
 if not found or not is_household_member(t.household_id) then raise exception 'Sem permissão';end if;
 if t.status='settled' then return;end if;
 if t.due_date>(now() at time zone 'America/Fortaleza')::date then raise exception 'Confirme somente na data prevista ou depois';end if;
 perform transfer_funds(t.from_account,t.to_account,t.amount,t.id);
 update scheduled_transfers set status='settled' where id=p_id;
end $$;
revoke all on function schedule_transfer(uuid,uuid,uuid,numeric,date),execute_transfer(uuid) from public;
grant execute on function schedule_transfer(uuid,uuid,uuid,numeric,date),execute_transfer(uuid) to authenticated;
notify pgrst,'reload schema';

-- 010_accounts_and_receipts.sql
-- Additive account editing, owner validation and auditable automatic income.
alter table public.financial_accounts add column account_type text not null default 'checking' check(account_type in ('checking','recurring','investment'));
create table public.account_edits(id uuid primary key,household_id uuid not null references households,parameters jsonb not null);
alter table account_edits enable row level security;
create function public.save_account(p_id uuid,p_account uuid,p_name text,p_owner uuid,p_color text,p_primary boolean,p_type text,p_balance numeric,p_expected_balance numeric) returns void language plpgsql security definer set search_path=public as $$
declare a financial_accounts%rowtype;params jsonb;previous account_edits%rowtype;
begin
 select * into a from financial_accounts where id=p_account;
 if not found or not is_household_member(a.household_id) then raise exception 'Sem permissão';end if;
 perform 1 from households where id=a.household_id for update;
 select * into a from financial_accounts where id=p_account for update;
 if p_id is null or p_name is null or length(trim(p_name)) not between 1 and 120 or p_color is null or p_color !~ '^#[0-9a-fA-F]{6}$' or p_type is null or p_type not in ('checking','recurring','investment') or p_primary is null or p_balance is null or p_balance='NaN'::numeric or abs(p_balance)>9000000000000 or p_balance<>round(p_balance,2) or not exists(select 1 from household_members where household_id=a.household_id and user_id=p_owner) then raise exception 'Dados da conta inválidos';end if;
 params:=jsonb_build_array(p_account,p_name,p_owner,p_color,p_primary,p_type,p_balance,p_expected_balance);
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,10));
 select * into previous from account_edits where id=p_id;
 if found then if previous.household_id<>a.household_id or previous.parameters<>params then raise exception 'Chave já utilizada';end if;return;end if;
 if p_expected_balance is null or a.balance<>p_expected_balance then raise exception 'Saldo alterado. Atualize a conta antes de salvar';end if;
 if a.owner_id<>p_owner and (exists(select 1 from financial_events where account_id=a.id) or exists(select 1 from account_ledger where account_id=a.id and operation_key<>'opening') or exists(select 1 from credit_cards where account_id=a.id) or exists(select 1 from scheduled_transfers where from_account=a.id or to_account=a.id)) then raise exception 'Conta com histórico: preserve o titular e crie outra conta';end if;
 insert into account_edits values(p_id,a.household_id,params);
 if p_primary then update financial_accounts set is_primary=false where household_id=a.household_id and owner_id=p_owner and is_primary;end if;
 update financial_accounts set name=trim(p_name),owner_id=p_owner,color=p_color,account_type=p_type,is_primary=p_primary where id=a.id;
 if p_balance<>a.balance then insert into account_ledger(household_id,account_id,amount,operation_key,actor_id) values(a.household_id,a.id,p_balance-a.balance,'adjustment:'||p_id,auth.uid());end if;
end $$;
-- New predictions must use an active account belonging to their responsible person.
-- Existing historical links are left intact.
create function public.validate_event_owner() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from financial_accounts where id=new.account_id and household_id=new.household_id and owner_id=new.owner_id and active) then raise exception 'Selecione uma conta do responsável';end if;
 return new;
end $$;
create trigger event_owner before insert on financial_events for each row execute function validate_event_owner();
alter table financial_events add column auto_receipt_suppressed boolean not null default false;
create function public.suppress_reversed_income() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.kind='income' and old.paid_amount>0 and new.paid_amount=0 then new.auto_receipt_suppressed:=true;end if;return new;
end $$;
create trigger income_reversal before update on financial_events for each row execute function suppress_reversed_income();
-- Private worker callable by cron; every posting locks the event and uses a unique key.
create function public.post_due_income(p_household uuid) returns integer language plpgsql security definer set search_path=public as $$
declare e financial_events%rowtype;pid uuid;n integer:=0;remaining numeric;
begin
 for e in select ev.* from financial_events ev join financial_accounts a on a.id=ev.account_id where ev.kind='income' and ev.status='pending' and not ev.auto_receipt_suppressed and ev.due_date<=(now() at time zone 'America/Fortaleza')::date and a.active and (p_household is null or ev.household_id=p_household) order by ev.id for update of ev skip locked loop
 remaining:=e.amount-e.paid_amount;pid:=gen_random_uuid();
 perform 1 from financial_accounts where id=e.account_id for update;
 insert into event_payments(id,household_id,event_id,account_id,amount,paid_date,actor_id) values(pid,e.household_id,e.id,e.account_id,remaining,e.due_date,e.created_by);
 insert into account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(e.household_id,e.account_id,remaining,'auto-income:'||e.id,e.id,e.created_by);
 update financial_events set paid_amount=amount,status='settled',settled_at=now() where id=e.id;n:=n+1;
 end loop;return n;
end $$;
create function public.confirm_due_income(p_household uuid) returns integer language plpgsql security definer set search_path=public as $$
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 return post_due_income(p_household);
end $$;
create table public.income_corrections(id uuid primary key,household_id uuid not null references households,parameters jsonb not null);
alter table income_corrections enable row level security;
create function public.correct_income(p_id uuid,p_event uuid,p_amount numeric,p_date date,p_expected numeric) returns void language plpgsql security definer set search_path=public as $$
declare e financial_events%rowtype;previous income_corrections%rowtype;params jsonb;
begin
 select * into e from financial_events where id=p_event for update;
 if not found or not is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if p_id is null or p_amount is null or p_amount<=0 or p_amount='NaN'::numeric or p_amount<>round(p_amount,2) or p_date is null or p_date>(now() at time zone 'America/Fortaleza')::date or e.kind<>'income' then raise exception 'Recebimento inválido';end if;
 params:=jsonb_build_array(p_event,p_amount,p_date,p_expected);
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,11));select * into previous from income_corrections where id=p_id;
 if found then if previous.household_id<>e.household_id or previous.parameters<>params then raise exception 'Chave já utilizada';end if;return;end if;
 if e.status<>'settled' or p_expected is null or e.paid_amount<>p_expected then raise exception 'Recebimento alterado. Atualize a página';end if;
 insert into income_corrections values(p_id,e.household_id,params);
 perform reverse_event(e.id);
 update financial_events set amount=p_amount where id=e.id;
 perform pay_event(p_id,e.id,e.account_id,p_amount,p_date,0);
end $$;
revoke all on function public.save_account(uuid,uuid,text,uuid,text,boolean,text,numeric,numeric),public.validate_event_owner(),public.suppress_reversed_income(),public.post_due_income(uuid),public.confirm_due_income(uuid),public.correct_income(uuid,uuid,numeric,date,numeric) from public;
grant execute on function public.save_account(uuid,uuid,text,uuid,text,boolean,text,numeric,numeric),public.confirm_due_income(uuid),public.correct_income(uuid,uuid,numeric,date,numeric) to authenticated;
-- Cron is configured separately after pg_cron is enabled; fallback also runs at login/foreground.
notify pgrst,'reload schema';


notify pgrst, 'reload schema';
commit;
