-- Instalação inicial do Finanças a Dois.
-- Execute no SQL Editor do MESMO Supabase configurado na Vercel.
-- Não use para atualizar banco existente: aplique apenas as migrations pendentes.
-- Gerado a partir de supabase/migrations/001 a 028.
begin;
do $$
begin
 if exists (
  select 1 from information_schema.tables
  where table_schema='public' and table_name in (
   'households','household_members','financial_accounts','financial_events',
   'financial_transfers','household_invites','account_ledger','properties',
   'investments','credit_cards','card_purchases','event_audit',
   'event_payments','invoice_payments','categories','recurrence_requests','invite_attempts','scheduled_transfers','account_edits','income_corrections','property_installment_payments','installment_series_flags','event_series_rules','event_change_requests','credit_annotation_requests','payment_action_requests'
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


-- 011_editable_categories.sql

-- Predefined categories become editable household records. Existing labels remain intact.
alter table public.categories add column deleted_at timestamptz;
create function public.seed_household_categories(p_household uuid) returns void language sql security definer set search_path=public as $$
 insert into categories(household_id,name,kind,color,icon)
 select p_household,v.name,v.kind,case when v.kind='income' then '#0284c7' else '#e11d48' end,'wallet'
 from (values ('income','Salário'),('income','Aluguel recebido'),('income','Serviços'),('income','Rendimentos'),('income','Reembolso'),('income','Venda'),('income','Outros'),('expense','Alimentação'),('expense','Supermercado'),('expense','Transporte'),('expense','Combustível'),('expense','Moradia'),('expense','Energia'),('expense','Água'),('expense','Internet'),('expense','Condomínio'),('expense','Saúde'),('expense','Educação'),('expense','Lazer'),('expense','Cartão de crédito'),('expense','Financiamento'),('expense','Impostos'),('expense','Manutenção'),('expense','Outros')) as v(kind,name)
 on conflict(household_id,kind,name) do nothing;
$$;
do $$ declare h record;begin for h in select id from public.households loop perform public.seed_household_categories(h.id);end loop;end $$;
-- Expose legacy category labels too, without modifying the movements themselves.
insert into public.categories(household_id,name,kind,color,icon)
select distinct household_id,category,kind,case when kind='income' then '#0284c7' else '#e11d48' end,'wallet'
from public.financial_events where length(trim(category)) between 1 and 100
on conflict(household_id,kind,name) do nothing;
create function public.seed_new_household_categories() returns trigger language plpgsql security definer set search_path=public as $$
begin perform seed_household_categories(new.id);return new;end $$;
create trigger household_categories after insert on public.households for each row execute function public.seed_new_household_categories();
create function public.delete_category(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin
 update categories set active=false,deleted_at=coalesce(deleted_at,now()) where id=p_id and is_household_member(household_id);
 if not found then raise exception 'Sem permissão';end if;
end $$;
revoke all on function public.seed_household_categories(uuid),public.seed_new_household_categories(),public.delete_category(uuid) from public;
grant execute on function public.delete_category(uuid) to authenticated;
notify pgrst,'reload schema';


-- 012_quick_balance.sql

-- Update only the balance, preserving concurrent edits to account details.
create function public.adjust_account_balance(p_id uuid,p_account uuid,p_balance numeric,p_expected_balance numeric) returns void
language plpgsql security definer set search_path=public as $$
declare a financial_accounts%rowtype;previous account_edits%rowtype;
begin
 select * into a from financial_accounts where id=p_account;
 if not found or not is_household_member(a.household_id) then raise exception 'Sem permissão';end if;
 perform 1 from households where id=a.household_id for update;
 select * into a from financial_accounts where id=p_account for update;
 if p_id is null then raise exception 'Chave obrigatória';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,10));
 select * into previous from account_edits where id=p_id;
 if found then
  if previous.household_id<>a.household_id or previous.parameters->>0<>p_account::text or p_balance is null or p_expected_balance is null or (previous.parameters->>6)::numeric<>p_balance or (previous.parameters->>7)::numeric<>p_expected_balance then raise exception 'Chave já utilizada';end if;
  return;
 end if;
 perform save_account(p_id,a.id,a.name,a.owner_id,a.color,a.is_primary,a.account_type,p_balance,p_expected_balance);
end $$;
revoke all on function public.adjust_account_balance(uuid,uuid,numeric,numeric) from public;
grant execute on function public.adjust_account_balance(uuid,uuid,numeric,numeric) to authenticated;
notify pgrst,'reload schema';


-- 013_properties_and_investments.sql

-- Additive property details; all existing links and investment records are preserved.
alter table public.properties
 add column city text not null default '' check(length(city)<=120),
 add column tenure text not null default 'owned' check(tenure in ('owned','rented')),
 add column payment_status text not null default 'paid' check(payment_status in ('paid','financed')),
 add column debt numeric(16,2) not null default 0 check(debt>=0 and debt<>'NaN'::numeric and debt<=9000000000000),
 add column pending_installments integer;
alter table public.properties add constraint property_financing_details check(
 (payment_status='financed' or debt=0) and
 ((tenure='owned' and payment_status='financed' and pending_installments is not null and pending_installments>=0)
 or ((tenure<>'owned' or payment_status<>'financed') and pending_installments is null))
);
alter table public.properties add constraint property_value_finite check(estimated_value<>'NaN'::numeric and estimated_value<=9000000000000) not valid;
alter table public.investments add constraint investment_value_finite check(amount<>'NaN'::numeric and amount<=9000000000000) not valid;
create function public.save_property(p_id uuid,p_household uuid,p_name text,p_city text,p_tenure text,p_status text,p_value numeric,p_debt numeric,p_installments integer) returns void
language plpgsql security definer set search_path=public as $$
declare old_property properties%rowtype;
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 if p_id is null or p_name is null or length(trim(p_name)) not between 1 and 120 or p_city is null or length(trim(p_city)) not between 1 and 120 or p_tenure is null or p_tenure not in ('owned','rented') or p_status is null or p_status not in ('paid','financed') or p_value is null or p_value='NaN'::numeric or p_value<0 or p_value>9000000000000 or p_value<>round(p_value,2) or p_debt is null or p_debt='NaN'::numeric or p_debt<0 or p_debt>9000000000000 or p_debt<>round(p_debt,2) then raise exception 'Dados do imóvel inválidos';end if;
 if (p_status='paid' and p_debt<>0) or (p_tenure='owned' and p_status='financed' and (p_installments is null or p_installments<0)) or ((p_tenure<>'owned' or p_status<>'financed') and p_installments is not null) then raise exception 'Dados do financiamento inválidos';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,13));
 select * into old_property from properties where id=p_id for update;
 if found then
 if old_property.household_id<>p_household then raise exception 'Sem permissão';end if;
 update properties set name=trim(p_name),city=trim(p_city),tenure=p_tenure,payment_status=p_status,estimated_value=p_value,debt=p_debt,pending_installments=p_installments where id=p_id;
 else insert into properties(id,household_id,name,city,tenure,payment_status,estimated_value,debt,pending_installments) values(p_id,p_household,trim(p_name),trim(p_city),p_tenure,p_status,p_value,p_debt,p_installments);
 end if;
end $$;
create function public.register_investment(p_id uuid,p_household uuid,p_owner uuid,p_name text,p_kind text,p_amount numeric,p_liquidity date) returns void
language plpgsql security definer set search_path=public as $$
declare old_investment investments%rowtype;
begin
 if not is_household_member(p_household) or not exists(select 1 from household_members where household_id=p_household and user_id=p_owner) then raise exception 'Sem permissão';end if;
 if p_id is null or p_name is null or length(trim(p_name)) not between 1 and 120 or p_kind is null or length(trim(p_kind)) not between 1 and 60 or p_amount is null or p_amount='NaN'::numeric or p_amount<0 or p_amount>9000000000000 or p_amount<>round(p_amount,2) then raise exception 'Investimento inválido';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,14));
 select * into old_investment from investments where id=p_id;
 if found then
 if old_investment.household_id<>p_household or old_investment.owner_id<>p_owner or old_investment.name<>trim(p_name) or old_investment.kind<>trim(p_kind) or old_investment.amount<>p_amount or old_investment.liquidity_date is distinct from p_liquidity then raise exception 'Chave já utilizada';end if;return;
 end if;
 insert into investments(id,household_id,owner_id,name,kind,amount,liquidity_date) values(p_id,p_household,p_owner,trim(p_name),trim(p_kind),p_amount,p_liquidity);
end $$;
revoke all on function public.save_property(uuid,uuid,text,text,text,text,numeric,numeric,integer),public.register_investment(uuid,uuid,uuid,text,text,numeric,date) from public;
grant execute on function public.save_property(uuid,uuid,text,text,text,text,numeric,numeric,integer),public.register_investment(uuid,uuid,uuid,text,text,numeric,date) to authenticated;
notify pgrst,'reload schema';


-- 014_event_editing_and_property_installments.sql

-- Preserve paid history and ledger entries. Edits and exclusions affect unpaid forecasts only.
alter table public.properties drop constraint properties_tenure_check;
alter table public.properties add constraint properties_tenure_check check(tenure in ('owned','rented','third_party'));
alter table public.properties add column financing_epoch uuid not null default gen_random_uuid();
create function public.property_financing_epoch() returns trigger language plpgsql set search_path=public as $$
begin
 if new.tenure<>old.tenure or new.payment_status<>old.payment_status then new.financing_epoch:=gen_random_uuid();end if;
 return new;
end $$;
create trigger property_financing_epoch before update on public.properties for each row execute function public.property_financing_epoch();

create or replace function public.save_property(p_id uuid,p_household uuid,p_name text,p_city text,p_tenure text,p_status text,p_value numeric,p_debt numeric,p_installments integer) returns void
language plpgsql security definer set search_path=public as $$
declare old_property properties%rowtype;
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 if p_id is null or p_name is null or length(trim(p_name)) not between 1 and 120 or p_city is null or length(trim(p_city)) not between 1 and 120 or p_tenure is null or p_tenure not in ('owned','rented','third_party') or p_status is null or p_status not in ('paid','financed') or p_value is null or p_value='NaN'::numeric or p_value<0 or p_value>9000000000000 or p_value<>round(p_value,2) or p_debt is null or p_debt='NaN'::numeric or p_debt<0 or p_debt>9000000000000 or p_debt<>round(p_debt,2) then raise exception 'Dados do imóvel inválidos';end if;
 if (p_status='paid' and p_debt<>0) or (p_tenure='owned' and p_status='financed' and (p_installments is null or p_installments<0)) or ((p_tenure<>'owned' or p_status<>'financed') and p_installments is not null) then raise exception 'Dados do financiamento inválidos';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,13));
 select * into old_property from properties where id=p_id for update;
 if found then
  if old_property.household_id<>p_household then raise exception 'Sem permissão';end if;
  update properties set name=trim(p_name),city=trim(p_city),tenure=p_tenure,payment_status=p_status,estimated_value=p_value,debt=p_debt,pending_installments=p_installments where id=p_id;
 else
  insert into properties(id,household_id,name,city,tenure,payment_status,estimated_value,debt,pending_installments) values(p_id,p_household,trim(p_name),trim(p_city),p_tenure,p_status,p_value,p_debt,p_installments);
 end if;
end $$;

alter table public.financial_events add column edit_version bigint not null default 0,
 add column is_property_installment boolean not null default false;
create function public.validate_event_revision() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if tg_op='UPDATE' then new.edit_version:=old.edit_version+1;end if;
 if new.is_property_installment then
  if tg_op='INSERT' or not old.is_property_installment or new.property_id is distinct from old.property_id then
   if new.kind<>'expense' or not exists(select 1 from properties where id=new.property_id and household_id=new.household_id and tenure='owned' and payment_status='financed') then raise exception 'Selecione um imóvel próprio financiado para a parcela';end if;
  end if;
 end if;
 return new;
end $$;
create trigger event_revision before insert or update on public.financial_events for each row execute function public.validate_event_revision();

create table public.property_installment_payments(
 id uuid primary key default gen_random_uuid(),event_id uuid not null references financial_events,
 household_id uuid not null references households,property_id uuid not null references properties,
 financing_epoch uuid not null,counted boolean not null,reversed_at timestamptz
);
create unique index property_installment_active on public.property_installment_payments(event_id) where reversed_at is null;
alter table public.property_installment_payments enable row level security;
create policy property_installment_read on public.property_installment_payments for select to authenticated using(is_household_member(household_id));
create function public.count_property_installment() returns trigger language plpgsql security definer set search_path=public as $$
declare p properties%rowtype;receipt property_installment_payments%rowtype;
begin
 if new.status='settled' and old.status<>'settled' and new.is_property_installment and new.kind='expense' then
  select * into p from properties where id=new.property_id and household_id=new.household_id for update;
  if found and p.tenure='owned' and p.payment_status='financed' then
   insert into property_installment_payments(event_id,household_id,property_id,financing_epoch,counted)
   values(new.id,new.household_id,p.id,p.financing_epoch,p.pending_installments>0) on conflict do nothing;
   if found and p.pending_installments>0 then update properties set pending_installments=pending_installments-1 where id=p.id;end if;
  end if;
 elsif old.status='settled' and new.status<>'settled' then
  select * into receipt from property_installment_payments where event_id=new.id and reversed_at is null for update;
  if found then
   update property_installment_payments set reversed_at=now() where id=receipt.id;
   if receipt.counted then update properties set pending_installments=pending_installments+1 where id=receipt.property_id and tenure='owned' and payment_status='financed' and financing_epoch=receipt.financing_epoch;end if;
  end if;
 end if;
 return new;
end $$;
create trigger property_installment_count after update on public.financial_events for each row execute function public.count_property_installment();

-- Keep the original creation key and payload immutable for safe retries after later edits.
alter function public.schedule_events(uuid,uuid,uuid,uuid,text,numeric,date,text,text,boolean,text,integer,date,uuid) rename to schedule_events_base;
revoke all on function public.schedule_events_base(uuid,uuid,uuid,uuid,text,numeric,date,text,text,boolean,text,integer,date,uuid) from public,authenticated;
create table public.installment_series_flags(series_id uuid primary key,household_id uuid not null references households,flag boolean not null);
alter table public.installment_series_flags enable row level security;
insert into public.installment_series_flags select id,household_id,false from public.recurrence_requests;
create function public.schedule_events(p_id uuid,p_household uuid,p_owner uuid,p_account uuid,p_title text,p_amount numeric,p_due date,p_kind text,p_category text,p_variable boolean,p_unit text,p_every integer,p_end date,p_property uuid default null,p_installment boolean default false) returns void language plpgsql security definer set search_path=public as $$
declare previous installment_series_flags%rowtype;
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 if p_installment is null then raise exception 'Parcela inválida';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,8));
 select * into previous from installment_series_flags where series_id=p_id;
 if found and (previous.household_id<>p_household or previous.flag<>p_installment) then raise exception 'Chave já utilizada';end if;
 perform schedule_events_base(p_id,p_household,p_owner,p_account,p_title,p_amount,p_due,p_kind,p_category,p_variable,p_unit,p_every,p_end,p_property);
 if previous.series_id is not null then return;end if;
 insert into installment_series_flags values(p_id,p_household,p_installment);
 if p_installment then update financial_events set is_property_installment=true where series_id=p_id and household_id=p_household;end if;
end $$;

create table public.event_series_rules(series_id uuid primary key,household_id uuid not null references households,unit text not null,every integer not null,end_date date);
alter table public.event_series_rules enable row level security;
create function public.get_event_recurrence(p_event uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare e financial_events%rowtype;r event_series_rules%rowtype;params jsonb;last_date date;
begin
 select * into e from financial_events where id=p_event;
 if not found or not is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 select * into r from event_series_rules where series_id=e.series_id and household_id=e.household_id;
 if found then return jsonb_build_object('unit',r.unit,'every',r.every,'end_date',r.end_date);end if;
 select parameters into params from recurrence_requests where id=e.series_id and household_id=e.household_id;
 if found then return jsonb_build_object('unit',params->>9,'every',(params->>10)::int,'end_date',coalesce((params->>11)::date,((params->>5)::date+interval '1 year')::date));end if;
 select max(due_date) into last_date from financial_events where series_id=e.series_id and household_id=e.household_id;
 return jsonb_build_object('unit',case when e.series_id is null then 'once' else 'months' end,'every',1,'end_date',last_date);
end $$;
create table public.event_change_requests(id uuid primary key,household_id uuid not null references households,parameters jsonb not null);
alter table public.event_change_requests enable row level security;
create function public.revise_events(p_id uuid,p_event uuid,p_scope text,p_action text,p_account uuid,p_amount numeric,p_due date,p_property uuid,p_installment boolean,p_change_recurrence boolean,p_unit text,p_every integer,p_end date,p_expected_version bigint) returns void
language plpgsql security definer set search_path=public as $$
declare e financial_events%rowtype;prior event_change_requests%rowtype;params jsonb;rule jsonb;s uuid;d date;anchor date;last_date date;i integer:=0;
begin
 select * into e from financial_events where id=p_event;
 if not found or not is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if p_id is null or p_scope is null or p_scope not in ('single','future') or p_action is null or p_action not in ('edit','cancel') or p_change_recurrence is null or p_installment is null then raise exception 'Alteração inválida';end if;
 params:=jsonb_build_array(p_event,p_scope,p_action,p_account,p_amount,p_due,p_property,p_installment,p_change_recurrence,p_unit,p_every,p_end,p_expected_version);
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,16));
 select * into prior from event_change_requests where id=p_id;
 if found then if prior.household_id<>e.household_id or prior.parameters<>params then raise exception 'Chave já utilizada';end if;return;end if;
 perform pg_advisory_xact_lock(hashtextextended(coalesce(e.series_id,e.id)::text,15));
 perform id from financial_events where household_id=e.household_id and (id=e.id or (p_scope='future' and series_id=e.series_id)) order by id for update;
 select * into e from financial_events where id=p_event;
 if p_expected_version is null or e.edit_version<>p_expected_version then raise exception 'Lançamento atualizado por outra operação. Feche e abra a edição novamente';end if;
 if e.status<>'pending' or e.paid_amount<>0 or e.card_id is not null then raise exception 'Somente previsões sem pagamentos podem ser alteradas ou excluídas';end if;
 if p_action='cancel' then
  update financial_events set status='cancelled' where household_id=e.household_id and (id=e.id or (p_scope='future' and series_id=e.series_id and due_date>=e.due_date)) and status='pending' and paid_amount=0 and card_id is null;
 else
  if p_amount is null or p_amount='NaN'::numeric or p_amount<=0 or p_amount>9000000000000 or p_amount<>round(p_amount,2) or p_due is null then raise exception 'Valor ou data inválidos';end if;
  if not exists(select 1 from financial_accounts where id=p_account and household_id=e.household_id and owner_id=e.owner_id and active) then raise exception 'Selecione uma conta do responsável';end if;
  if p_property is not null and not exists(select 1 from properties where id=p_property and household_id=e.household_id) then raise exception 'Imóvel inválido';end if;
  if p_installment and (e.kind<>'expense' or not exists(select 1 from properties where id=p_property and household_id=e.household_id and tenure='owned' and payment_status='financed')) then raise exception 'Selecione um imóvel próprio financiado para a parcela';end if;
  if p_change_recurrence then
   if p_scope<>'future' or p_unit is null or p_unit not in ('once','days','months') or p_every is null or p_every not between 1 and 365 or (p_end is not null and p_end<p_due) then raise exception 'Recorrência inválida';end if;
   last_date:=coalesce(p_end,(p_due+interval '1 year')::date);
   if last_date>p_due+interval '5 years' then raise exception 'Limite de cinco anos';end if;
   s:=coalesce(e.series_id,gen_random_uuid());
   update financial_events set status='cancelled' where household_id=e.household_id and series_id=e.series_id and due_date>=e.due_date and id<>e.id and status='pending' and paid_amount=0 and card_id is null;
   update financial_events set account_id=p_account,amount=p_amount,due_date=p_due,property_id=p_property,is_property_installment=p_installment,series_id=s where id=e.id;
   insert into event_series_rules values(s,e.household_id,p_unit,p_every,p_end) on conflict(series_id) do update set unit=excluded.unit,every=excluded.every,end_date=excluded.end_date;
   i:=1;
   loop
    exit when p_unit='once';
    if p_unit='months' then
     anchor:=(date_trunc('month',p_due)+make_interval(months=>i*p_every))::date;
     d:=anchor+least(extract(day from p_due)::int,extract(day from anchor+interval '1 month - 1 day')::int)-1;
    else d:=p_due+i*p_every;end if;
    exit when d>last_date;
    if i>=2000 then raise exception 'Muitas ocorrências';end if;
    if not exists(select 1 from financial_events where household_id=e.household_id and series_id=s and due_date=d and status<>'cancelled') then
     insert into financial_events(household_id,created_by,owner_id,account_id,title,amount,due_date,kind,category,series_id,variable_amount,property_id,is_property_installment)
     values(e.household_id,auth.uid(),e.owner_id,p_account,e.title,p_amount,d,e.kind,e.category,s,e.variable_amount,p_property,p_installment);
    end if;
    i:=i+1;
   end loop;
  else
   rule:=get_event_recurrence(e.id);
   update financial_events f set account_id=p_account,amount=p_amount,property_id=p_property,is_property_installment=p_installment,
    due_date=case when p_due=e.due_date then f.due_date
     when rule->>'unit'='months' and f.id<>e.id then
      (date_trunc('month',p_due)+make_interval(months=>((extract(year from f.due_date)::int-extract(year from e.due_date)::int)*12+extract(month from f.due_date)::int-extract(month from e.due_date)::int)))::date
      +least(extract(day from p_due)::int,extract(day from date_trunc('month',p_due)+make_interval(months=>((extract(year from f.due_date)::int-extract(year from e.due_date)::int)*12+extract(month from f.due_date)::int-extract(month from e.due_date)::int))+interval '1 month - 1 day')::int)-1
     else f.due_date+(p_due-e.due_date) end
    where f.household_id=e.household_id and (f.id=e.id or (p_scope='future' and f.series_id=e.series_id and f.due_date>=e.due_date)) and f.status='pending' and f.paid_amount=0 and f.card_id is null;
  end if;
 end if;
 if p_action='edit' and e.series_id is not null and p_due<>e.due_date and exists(
  select 1 from financial_events where household_id=e.household_id and series_id=e.series_id and status<>'cancelled' group by due_date having count(*)>1
 ) then raise exception 'O novo vencimento coincide com outro lançamento da série. Escolha outra data';end if;
 insert into event_change_requests values(p_id,e.household_id,params);
end $$;
revoke all on function public.property_financing_epoch(),public.validate_event_revision(),public.count_property_installment(),public.schedule_events(uuid,uuid,uuid,uuid,text,numeric,date,text,text,boolean,text,integer,date,uuid,boolean),public.get_event_recurrence(uuid),public.revise_events(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint) from public;
grant execute on function public.schedule_events(uuid,uuid,uuid,uuid,text,numeric,date,text,text,boolean,text,integer,date,uuid,boolean),public.get_event_recurrence(uuid),public.revise_events(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint) to authenticated;
notify pgrst,'reload schema';


-- 015_credit_annotations_and_dated_transfers.sql

-- Effective transfer dates are separate from immutable ledger recording timestamps.
alter table public.financial_transfers add column effective_date date,add column request_id uuid unique;
update public.financial_transfers set effective_date=(coalesce(created_at,now()) at time zone 'America/Fortaleza')::date;
alter table public.financial_transfers alter column effective_date set not null,alter column effective_date set default ((now() at time zone 'America/Fortaleza')::date);
alter function public.transfer_funds(uuid,uuid,numeric,uuid) rename to transfer_funds_legacy;
revoke all on function public.transfer_funds_legacy(uuid,uuid,numeric,uuid) from public,authenticated;
create function public.transfer_funds(p_from uuid,p_to uuid,p_amount numeric,p_key uuid,p_date date default null) returns void language plpgsql security definer set search_path=public as $$
declare a financial_accounts%rowtype;b financial_accounts%rowtype;previous financial_transfers%rowtype;effective date:=coalesce(p_date,(now() at time zone 'America/Fortaleza')::date);
begin
 if p_key is null or p_amount is null or p_amount='NaN'::numeric or p_amount<=0 or p_amount>9000000000000 or p_amount<>round(p_amount,2) or p_from=p_to or effective>(now() at time zone 'America/Fortaleza')::date then raise exception 'Transferência inválida. Use o agendamento para datas futuras';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_key::text,1));
 perform id from financial_accounts where id in(p_from,p_to) order by id for update;
 select * into a from financial_accounts where id=p_from;select * into b from financial_accounts where id=p_to;
 if a.id is null or b.id is null or a.household_id<>b.household_id or not is_household_member(a.household_id) or not a.active or not b.active then raise exception 'Contas inválidas';end if;
 select * into previous from financial_transfers where request_id=p_key;
 if found then
  if previous.household_id<>a.household_id or previous.from_account<>p_from or previous.to_account<>p_to or previous.amount<>p_amount or previous.effective_date<>effective then raise exception 'Chave já utilizada';end if;return;
 end if;
 if exists(select 1 from account_ledger where operation_key='transfer:'||p_key) then
  if not exists(select 1 from account_ledger where operation_key='transfer:'||p_key and account_id=p_from and amount=-p_amount and (occurred_at at time zone 'America/Fortaleza')::date=effective) or not exists(select 1 from account_ledger where operation_key='transfer:'||p_key and account_id=p_to and amount=p_amount) then raise exception 'Chave já utilizada';end if;return;
 end if;
 insert into account_ledger(household_id,account_id,amount,operation_key,actor_id) values(a.household_id,p_from,-p_amount,'transfer:'||p_key,auth.uid()),(a.household_id,p_to,p_amount,'transfer:'||p_key,auth.uid());
 insert into financial_transfers(household_id,from_account,to_account,amount,created_by,effective_date,request_id) values(a.household_id,p_from,p_to,p_amount,auth.uid(),effective,p_key);
end $$;
create or replace function public.execute_transfer(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare t scheduled_transfers%rowtype;
begin
 select * into t from scheduled_transfers where id=p_id for update;
 if not found or not is_household_member(t.household_id) then raise exception 'Sem permissão';end if;
 if t.status='settled' then return;end if;
 if t.due_date>(now() at time zone 'America/Fortaleza')::date then raise exception 'Confirme somente na data prevista ou depois';end if;
 perform transfer_funds(t.from_account,t.to_account,t.amount,t.id,t.due_date);
 update scheduled_transfers set status='settled' where id=p_id;
end $$;

-- These are annotations of expenses ALREADY included in an invoice, never new card purchases.
alter table public.financial_events add column credit_state text not null default 'none' check(credit_state in ('none','planned','paid')),
 add column payment_card_id uuid,add column credit_paid_date date,
 add constraint event_payment_card_fk foreign key(payment_card_id,household_id) references public.credit_cards(id,household_id);
create function public.validate_credit_annotation() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.credit_state<>'none' then
  if new.kind<>'expense' or new.card_id is not null or new.paid_amount<>0 or new.status='settled' then raise exception 'Cartão: somente despesas sem pagamentos bancários e fora das parcelas da fatura';end if;
  if new.payment_card_id is not null and not exists(select 1 from credit_cards where id=new.payment_card_id and household_id=new.household_id and owner_id=new.owner_id) then raise exception 'Selecione um cartão do responsável';end if;
  if new.credit_state='paid' then
   if tg_op='INSERT' or old.credit_state<>'paid' then new.credit_paid_date:=(now() at time zone 'America/Fortaleza')::date;end if;
  else new.credit_paid_date:=null;end if;
 else new.payment_card_id:=null;new.credit_paid_date:=null;
 end if;return new;
end $$;
create trigger credit_annotation before insert or update on public.financial_events for each row execute function public.validate_credit_annotation();
create function public.reject_credit_bank_payment() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if exists(select 1 from financial_events where id=new.event_id and credit_state<>'none') then raise exception 'Despesa incluída no cartão. Pague a fatura para não duplicar o débito';end if;return new;
end $$;
create trigger credit_payment_guard before insert on public.event_payments for each row execute function public.reject_credit_bank_payment();

create table public.credit_annotation_requests(id uuid primary key,household_id uuid not null references households,parameters jsonb not null);
alter table public.credit_annotation_requests enable row level security;
alter function public.schedule_events(uuid,uuid,uuid,uuid,text,numeric,date,text,text,boolean,text,integer,date,uuid,boolean) rename to schedule_events_with_installments;
revoke all on function public.schedule_events_with_installments(uuid,uuid,uuid,uuid,text,numeric,date,text,text,boolean,text,integer,date,uuid,boolean) from public,authenticated;
create function public.schedule_events(p_id uuid,p_household uuid,p_owner uuid,p_account uuid,p_title text,p_amount numeric,p_due date,p_kind text,p_category text,p_variable boolean,p_unit text,p_every integer,p_end date,p_property uuid default null,p_installment boolean default false,p_credit_state text default 'none',p_payment_card uuid default null) returns void language plpgsql security definer set search_path=public as $$
declare prior credit_annotation_requests%rowtype;params jsonb:=jsonb_build_array('create',p_credit_state,p_payment_card);existing boolean;
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 if p_credit_state is null or p_credit_state not in ('none','planned','paid') or (p_credit_state='none' and p_payment_card is not null) then raise exception 'Dados do cartão inválidos';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,8));
 select * into prior from credit_annotation_requests where id=p_id;
 if found and (prior.household_id<>p_household or prior.parameters<>params) then raise exception 'Chave já utilizada';end if;
 existing:=exists(select 1 from recurrence_requests where id=p_id);
 perform schedule_events_with_installments(p_id,p_household,p_owner,p_account,p_title,p_amount,p_due,p_kind,p_category,p_variable,p_unit,p_every,p_end,p_property,p_installment);
 if prior.id is not null then return;end if;
 if existing and p_credit_state<>'none' then raise exception 'Use a edição para alterar o pagamento de lançamentos existentes';end if;
 if not existing and p_credit_state<>'none' then update financial_events set credit_state=p_credit_state,payment_card_id=p_payment_card where series_id=p_id and household_id=p_household;end if;
 insert into credit_annotation_requests values(p_id,p_household,params);
end $$;

alter function public.revise_events(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint) rename to revise_events_base;
revoke all on function public.revise_events_base(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint) from public,authenticated;
create function public.revise_events(p_id uuid,p_event uuid,p_scope text,p_action text,p_account uuid,p_amount numeric,p_due date,p_property uuid,p_installment boolean,p_change_recurrence boolean,p_unit text,p_every integer,p_end date,p_expected_version bigint,p_credit_state text default null,p_payment_card uuid default null) returns void language plpgsql security definer set search_path=public as $$
declare e financial_events%rowtype;prior credit_annotation_requests%rowtype;params jsonb:=jsonb_build_array('edit',p_credit_state,p_payment_card);targets uuid[];before_ids uuid[];s uuid;existing boolean;
begin
 select * into e from financial_events where id=p_event;
 if not found or not is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if (p_credit_state is not null and p_credit_state not in ('none','planned','paid')) or (coalesce(p_credit_state,'none')='none' and p_payment_card is not null) then raise exception 'Dados do cartão inválidos';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,16));
 select * into prior from credit_annotation_requests where id=p_id;
 if found and (prior.household_id<>e.household_id or prior.parameters<>params) then raise exception 'Chave já utilizada';end if;
 perform pg_advisory_xact_lock(hashtextextended(coalesce(e.series_id,e.id)::text,15));
 perform id from financial_events where household_id=e.household_id and (id=e.id or (p_scope='future' and series_id=e.series_id)) order by id for update;
 select * into e from financial_events where id=p_event;
 select array_agg(id) into targets from financial_events where household_id=e.household_id and (id=e.id or (p_scope='future' and series_id=e.series_id and due_date>=e.due_date)) and status='pending' and paid_amount=0 and card_id is null;
 select coalesce(array_agg(id),'{}'::uuid[]) into before_ids from financial_events where household_id=e.household_id and series_id=e.series_id;
 existing:=exists(select 1 from event_change_requests where id=p_id);
 perform revise_events_base(p_id,p_event,p_scope,p_action,p_account,p_amount,p_due,p_property,p_installment,p_change_recurrence,p_unit,p_every,p_end,p_expected_version);
 if prior.id is not null then return;end if;
 if existing and p_credit_state is not null then raise exception 'Chave já utilizada';end if;
 if p_action='edit' and not existing then
  select series_id into s from financial_events where id=e.id;
  update financial_events set credit_state=coalesce(p_credit_state,e.credit_state),payment_card_id=case when p_credit_state is null then e.payment_card_id else p_payment_card end
   where household_id=e.household_id and status='pending' and paid_amount=0 and (id=any(targets) or (p_change_recurrence and series_id=s and not(id=any(before_ids))));
 end if;
 insert into credit_annotation_requests values(p_id,e.household_id,params);
end $$;
revoke all on function public.transfer_funds(uuid,uuid,numeric,uuid,date),public.validate_credit_annotation(),public.reject_credit_bank_payment(),public.schedule_events(uuid,uuid,uuid,uuid,text,numeric,date,text,text,boolean,text,integer,date,uuid,boolean,text,uuid),public.revise_events(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint,text,uuid) from public;
grant execute on function public.transfer_funds(uuid,uuid,numeric,uuid,date),public.schedule_events(uuid,uuid,uuid,uuid,text,numeric,date,text,text,boolean,text,integer,date,uuid,boolean,text,uuid),public.revise_events(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint,text,uuid) to authenticated;
notify pgrst,'reload schema';


-- 016_effective_payments_and_undo.sql

-- User-facing confirmations settle the ACTUAL expense. Partial payments require an explicit choice.
-- Old payment/invoice endpoints keep their partial-payment contract for existing integrations.
create table public.payment_action_requests(id uuid primary key,household_id uuid not null references households,parameters jsonb not null);
alter table public.payment_action_requests enable row level security;
create function public.manage_event_payment(p_id uuid,p_event uuid,p_action text,p_account uuid,p_amount numeric,p_date date,p_expected_version bigint,p_partial boolean default false) returns void
language plpgsql security definer set search_path=public as $$
declare e financial_events%rowtype;prior payment_action_requests%rowtype;params jsonb;total numeric;new_paid numeric;entry record;
begin
 select * into e from financial_events where id=p_event;
 if not found or not is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if p_id is null or p_action is null or p_action not in ('confirm','correct','close','undo') or p_partial is null then raise exception 'Operação inválida';end if;
 params:=jsonb_build_array(p_event,p_action,p_account,p_amount,p_date,p_expected_version,p_partial);
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,19));
 select * into prior from payment_action_requests where id=p_id;
 if found then if prior.household_id<>e.household_id or prior.parameters<>params then raise exception 'Chave já utilizada';end if;return;end if;
 select * into e from financial_events where id=p_event for update;
 if p_expected_version is null or p_expected_version<>e.edit_version then raise exception 'A transação foi alterada. Feche esta janela, atualize a lista e tente novamente';end if;
 if e.status='cancelled' then raise exception 'Transação excluída';end if;
 if p_action='undo' and e.credit_state='paid' then
  update financial_events set credit_state='planned' where id=e.id;
 elsif e.credit_state<>'none' then
  raise exception 'Despesa incluída no cartão. Corrija a anotação ou pague a fatura para não duplicar o débito';
 elsif p_action='undo' then
  if e.paid_amount<=0 then raise exception 'A transação já está pendente, sem pagamentos para desfazer';end if;
  perform reverse_event(e.id);
 elsif p_action='close' then
  if e.status<>'pending' or e.paid_amount<=0 then raise exception 'Não há pagamento parcial para encerrar';end if;
  if coalesce((select sum(amount) from account_ledger where event_id=e.id),0)<>(case when e.kind='income' then e.paid_amount else -e.paid_amount end) then raise exception 'Histórico de pagamento inconsistente. Desfaça o pagamento e confirme novamente';end if;
  update financial_events set amount=paid_amount,status='settled',settled_at=now() where id=e.id;
 else
  if p_account is null or p_amount is null or p_amount='NaN'::numeric or p_amount<=0 or p_amount>9000000000000 or p_amount<>round(p_amount,2) or p_date is null or p_date>(now() at time zone 'America/Fortaleza')::date then raise exception 'Informe valor e data efetivos válidos';end if;
  if not exists(select 1 from financial_accounts where id=p_account and household_id=e.household_id and active) then raise exception 'Conta inválida';end if;
  -- Lock every affected bank account in the same order before a correction/refund.
  perform id from financial_accounts where household_id=e.household_id and (id=p_account or id in(select account_id from account_ledger where event_id=e.id)) order by id for update;
  if p_action='correct' then
   if e.paid_amount<=0 then raise exception 'Não há pagamento para corrigir';end if;
   -- Correct cash postings without reopening a settled installment: its financing
   -- may have changed since payment, and must never be counted in a new loan.
   for entry in select account_id,sum(amount) amount from account_ledger where event_id=e.id group by account_id having sum(amount)<>0 loop
    insert into account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(e.household_id,entry.account_id,-entry.amount,'correction:'||p_id,e.id,auth.uid());
   end loop;
   update event_payments set reversed_at=now() where event_id=e.id and reversed_at is null;
   new_paid:=p_amount;total:=p_amount;
  else
   if e.status<>'pending' then raise exception 'A transação já foi quitada';end if;
   new_paid:=e.paid_amount+p_amount;
   if new_paid>9000000000000 then raise exception 'Valor acima do limite';end if;
   if p_partial and new_paid>e.amount then raise exception 'Pagamento parcial superior ao valor pendente';end if;
   total:=case when p_partial then e.amount else new_paid end;
  end if;
  insert into event_payments(id,household_id,event_id,account_id,amount,paid_date,actor_id) values(p_id,e.household_id,e.id,p_account,p_amount,p_date,auth.uid());
  insert into account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(e.household_id,p_account,case when e.kind='income' then p_amount else -p_amount end,'payment:'||p_id,e.id,auth.uid());
  update financial_events set amount=total,paid_amount=new_paid,status=case when new_paid=total then 'settled' else 'pending' end,settled_at=case when new_paid=total then now() else null end where id=e.id;
  if p_action='correct' and e.status='settled' and e.variable_amount and e.series_id is not null then
   update financial_events set amount=total where household_id=e.household_id and series_id=e.series_id and due_date>e.due_date and status='pending' and paid_amount=0;
  end if;
 end if;
 insert into payment_action_requests values(p_id,e.household_id,params);
end $$;
revoke all on function public.manage_event_payment(uuid,uuid,text,uuid,numeric,date,bigint,boolean) from public;
grant execute on function public.manage_event_payment(uuid,uuid,text,uuid,numeric,date,bigint,boolean) to authenticated;
notify pgrst,'reload schema';

notify pgrst,'reload schema';

-- Migration 017
-- Category edits preserve revision, recurrence and retry protections.
create table public.event_category_requests(id uuid primary key,household_id uuid not null references households,parameters jsonb not null);
alter table public.event_category_requests enable row level security;
alter function public.revise_events(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint,text,uuid) rename to revise_events_credit;
revoke all on function public.revise_events_credit(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint,text,uuid) from public,authenticated;
create function public.revise_events(p_id uuid,p_event uuid,p_scope text,p_action text,p_account uuid,p_amount numeric,p_due date,p_property uuid,p_installment boolean,p_change_recurrence boolean,p_unit text,p_every integer,p_end date,p_expected_version bigint,p_credit_state text default null,p_payment_card uuid default null,p_category text default null) returns void language plpgsql security definer set search_path=public as $$
declare e financial_events%rowtype;prior event_category_requests%rowtype;params jsonb:=jsonb_build_array('edit',p_credit_state,p_payment_card,p_category);targets uuid[];before_ids uuid[];s uuid;existing boolean;
begin
 select * into e from financial_events where id=p_event;
 if not found or not is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if (p_credit_state is not null and p_credit_state not in ('none','planned','paid')) or (coalesce(p_credit_state,'none')='none' and p_payment_card is not null) then raise exception 'Dados do cartão inválidos';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,16));
 select * into prior from event_category_requests where id=p_id;
 if found and (prior.household_id<>e.household_id or prior.parameters<>params) then raise exception 'Chave já utilizada';end if;
 perform pg_advisory_xact_lock(hashtextextended(coalesce(e.series_id,e.id)::text,15));
 perform id from financial_events where household_id=e.household_id and (id=e.id or (p_scope='future' and series_id=e.series_id)) order by id for update;
 select * into e from financial_events where id=p_event;
 select array_agg(id) into targets from financial_events where household_id=e.household_id and (id=e.id or (p_scope='future' and series_id=e.series_id and due_date>=e.due_date)) and status='pending' and paid_amount=0 and card_id is null;
 select coalesce(array_agg(id),'{}'::uuid[]) into before_ids from financial_events where household_id=e.household_id and series_id=e.series_id;
 existing:=exists(select 1 from event_change_requests where id=p_id);
 perform revise_events_credit(p_id,p_event,p_scope,p_action,p_account,p_amount,p_due,p_property,p_installment,p_change_recurrence,p_unit,p_every,p_end,p_expected_version,p_credit_state,p_payment_card);
 if prior.id is not null then return;end if;
 if existing and (p_category is not null or p_credit_state is not null) then raise exception 'Chave já utilizada';end if;
 if p_action='edit' and not existing and p_category is not null then
  if p_category is not null and p_category is distinct from e.category and not exists(select 1 from categories where household_id=e.household_id and kind=e.kind and name=p_category and active and deleted_at is null) then raise exception 'Categoria inválida';end if;
  select series_id into s from financial_events where id=e.id;
  update financial_events set category=coalesce(p_category,e.category)
   where household_id=e.household_id and status='pending' and paid_amount=0 and (id=any(targets) or (p_change_recurrence and series_id=s and not(id=any(before_ids))));
 end if;
 insert into event_category_requests values(p_id,e.household_id,params);
end $$;
revoke all on function public.revise_events(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint,text,uuid,text) from public;
grant execute on function public.revise_events(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint,text,uuid,text) to authenticated;
notify pgrst,'reload schema';


-- Migration 018
-- Atomically revise responsible member, account, card and recurrence.
alter function public.revise_events(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint,text,uuid,text) rename to revise_events_categories;
revoke all on function public.revise_events_categories(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint,text,uuid,text) from public,authenticated;
create function public.revise_events(p_id uuid,p_event uuid,p_scope text,p_action text,p_account uuid,p_amount numeric,p_due date,p_property uuid,p_installment boolean,p_change_recurrence boolean,p_unit text,p_every integer,p_end date,p_expected_version bigint,p_credit_state text default null,p_payment_card uuid default null,p_category text default null,p_owner uuid default null) returns void
language plpgsql security definer set search_path=public as $$
declare e financial_events%rowtype;prior event_change_requests%rowtype;params jsonb;next_credit text;next_card uuid;next_category text;rule jsonb;s uuid;d date;anchor date;last_date date;i integer:=0;
begin
 if p_owner is null then
  perform revise_events_categories(p_id,p_event,p_scope,p_action,p_account,p_amount,p_due,p_property,p_installment,p_change_recurrence,p_unit,p_every,p_end,p_expected_version,p_credit_state,p_payment_card,p_category);return;
 end if;
 select * into e from financial_events where id=p_event;
 if not found or not is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if p_id is null or p_scope is null or p_scope not in ('single','future') or p_action is null or p_action not in ('edit','cancel') or p_change_recurrence is null or p_installment is null then raise exception 'Alteração inválida';end if;
 params:=jsonb_build_array(p_event,p_scope,p_action,p_account,p_amount,p_due,p_property,p_installment,p_change_recurrence,p_unit,p_every,p_end,p_expected_version,p_credit_state,p_payment_card,p_category,p_owner);
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,16));
 select * into prior from event_change_requests where id=p_id;
 if found then if prior.household_id<>e.household_id or prior.parameters<>params then raise exception 'Chave já utilizada';end if;return;end if;
 perform pg_advisory_xact_lock(hashtextextended(coalesce(e.series_id,e.id)::text,15));
 perform id from financial_events where household_id=e.household_id and (id=e.id or (p_scope='future' and series_id=e.series_id)) order by id for update;
 select * into e from financial_events where id=p_event;
 if p_expected_version is null or e.edit_version<>p_expected_version then raise exception 'Lançamento atualizado por outra operação. Feche e abra a edição novamente';end if;
 if e.status<>'pending' or e.paid_amount<>0 or e.card_id is not null then raise exception 'Somente previsões sem pagamentos podem ser alteradas ou excluídas';end if;
 if p_action='cancel' then
  update financial_events set status='cancelled' where household_id=e.household_id and (id=e.id or (p_scope='future' and series_id=e.series_id and due_date>=e.due_date)) and status='pending' and paid_amount=0 and card_id is null;
 else
  if p_amount is null or p_amount='NaN'::numeric or p_amount<=0 or p_amount>9000000000000 or p_amount<>round(p_amount,2) or p_due is null then raise exception 'Valor ou data inválidos';end if;
  if not exists(select 1 from household_members where household_id=e.household_id and user_id=p_owner) then raise exception 'Responsável inválido';end if;
  if not exists(select 1 from financial_accounts where id=p_account and household_id=e.household_id and owner_id=p_owner and active) then raise exception 'Selecione uma conta do responsável';end if;
  next_credit:=coalesce(p_credit_state,e.credit_state);
  next_card:=case when p_credit_state is not null then p_payment_card when p_owner=e.owner_id then e.payment_card_id else null end;
  next_category:=coalesce(p_category,e.category);
  if next_credit not in ('none','planned','paid') or (next_credit='none' and next_card is not null) then raise exception 'Dados do cartão inválidos';end if;
  if p_category is not null and p_category is distinct from e.category and not exists(select 1 from categories where household_id=e.household_id and kind=e.kind and name=p_category and active and deleted_at is null) then raise exception 'Categoria inválida';end if;
  if p_property is not null and not exists(select 1 from properties where id=p_property and household_id=e.household_id) then raise exception 'Imóvel inválido';end if;
  if p_installment and (e.kind<>'expense' or not exists(select 1 from properties where id=p_property and household_id=e.household_id and tenure='owned' and payment_status='financed')) then raise exception 'Selecione um imóvel próprio financiado para a parcela';end if;
  if p_change_recurrence then
   if p_scope<>'future' or p_unit is null or p_unit not in ('once','days','months') or p_every is null or p_every not between 1 and 365 or (p_end is not null and p_end<p_due) then raise exception 'Recorrência inválida';end if;
   last_date:=coalesce(p_end,(p_due+interval '1 year')::date);
   if last_date>p_due+interval '5 years' then raise exception 'Limite de cinco anos';end if;
   s:=coalesce(e.series_id,gen_random_uuid());
   update financial_events set status='cancelled' where household_id=e.household_id and series_id=e.series_id and due_date>=e.due_date and id<>e.id and status='pending' and paid_amount=0 and card_id is null;
   update financial_events set owner_id=p_owner,credit_state=next_credit,payment_card_id=next_card,category=next_category,account_id=p_account,amount=p_amount,due_date=p_due,property_id=p_property,is_property_installment=p_installment,series_id=s where id=e.id;
   insert into event_series_rules values(s,e.household_id,p_unit,p_every,p_end) on conflict(series_id) do update set unit=excluded.unit,every=excluded.every,end_date=excluded.end_date;
   i:=1;
   loop
    exit when p_unit='once';
    if p_unit='months' then
     anchor:=(date_trunc('month',p_due)+make_interval(months=>i*p_every))::date;
     d:=anchor+least(extract(day from p_due)::int,extract(day from anchor+interval '1 month - 1 day')::int)-1;
    else d:=p_due+i*p_every;end if;
    exit when d>last_date;
    if i>=2000 then raise exception 'Muitas ocorrências';end if;
    if not exists(select 1 from financial_events where household_id=e.household_id and series_id=s and due_date=d and status<>'cancelled') then
     insert into financial_events(household_id,created_by,owner_id,account_id,title,amount,due_date,kind,category,series_id,variable_amount,property_id,is_property_installment,credit_state,payment_card_id)
     values(e.household_id,auth.uid(),p_owner,p_account,e.title,p_amount,d,e.kind,next_category,s,e.variable_amount,p_property,p_installment,next_credit,next_card);
    end if;
    i:=i+1;
   end loop;
  else
   rule:=get_event_recurrence(e.id);
   update financial_events f set owner_id=p_owner,credit_state=case when p_credit_state is null then f.credit_state else next_credit end,payment_card_id=case when p_credit_state is not null then next_card when f.owner_id=p_owner then f.payment_card_id else null end,category=coalesce(p_category,f.category),account_id=p_account,amount=p_amount,property_id=p_property,is_property_installment=p_installment,
    due_date=case when p_due=e.due_date then f.due_date
     when rule->>'unit'='months' and f.id<>e.id then
      (date_trunc('month',p_due)+make_interval(months=>((extract(year from f.due_date)::int-extract(year from e.due_date)::int)*12+extract(month from f.due_date)::int-extract(month from e.due_date)::int)))::date
      +least(extract(day from p_due)::int,extract(day from date_trunc('month',p_due)+make_interval(months=>((extract(year from f.due_date)::int-extract(year from e.due_date)::int)*12+extract(month from f.due_date)::int-extract(month from e.due_date)::int))+interval '1 month - 1 day')::int)-1
     else f.due_date+(p_due-e.due_date) end
    where f.household_id=e.household_id and (f.id=e.id or (p_scope='future' and f.series_id=e.series_id and f.due_date>=e.due_date)) and f.status='pending' and f.paid_amount=0 and f.card_id is null;
  end if;
 end if;
 if p_action='edit' and e.series_id is not null and p_due<>e.due_date and exists(
  select 1 from financial_events where household_id=e.household_id and series_id=e.series_id and status<>'cancelled' group by due_date having count(*)>1
 ) then raise exception 'O novo vencimento coincide com outro lançamento da série. Escolha outra data';end if;
 insert into event_change_requests values(p_id,e.household_id,params);
end $$;
revoke all on function public.revise_events(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint,text,uuid,text,uuid) from public;
grant execute on function public.revise_events(uuid,uuid,text,text,uuid,numeric,date,uuid,boolean,boolean,text,integer,date,bigint,text,uuid,text,uuid) to authenticated;
notify pgrst,'reload schema';


-- Migration 019
-- Additive credit module. No historical rows are converted or removed.
alter table public.credit_cards
 add column issuer text not null default '', add column brand text not null default '',
 add column last_four text not null default '' check(last_four='' or last_four ~ '^[0-9]{4}$'),
 add column credit_limit numeric(16,2) not null default 0 check(credit_limit>=0 and credit_limit<>'NaN'::numeric),
 add column automatic_debit boolean not null default false,
 add column color text not null default '#765484' check(color ~ '^#[0-9a-fA-F]{6}$'),
 add column card_status text not null default 'active' check(card_status in ('active','blocked','archived')),
 add column parent_card_id uuid, add column module_version integer not null default 1,
 add column revision bigint not null default 0;
alter table public.credit_cards add constraint cc_parent_fk foreign key(parent_card_id,household_id) references public.credit_cards(id,household_id);

create table public.cc_requests(id uuid primary key,household_id uuid not null references households,actor_id uuid not null references auth.users,action text not null,parameters jsonb not null,result jsonb,created_at timestamptz not null default now());
create table public.cc_invoices(id uuid primary key default gen_random_uuid(),household_id uuid not null references households,card_id uuid not null,cycle date not null,closing_date date not null,due_date date not null,revision bigint not null default 0,unique(card_id,cycle),unique(id,household_id),foreign key(card_id,household_id) references credit_cards(id,household_id));
create table public.cc_recurrences(id uuid primary key,household_id uuid not null references households,card_id uuid not null,responsible_id uuid not null references auth.users,title text not null,category text not null,amount numeric(16,2) not null check(amount>0 and amount<>'NaN'::numeric),mode text not null check(mode in ('automatic','manual')),variable boolean not null default false,unit text not null check(unit in ('days','months')),every integer not null check(every between 1 and 365),start_date date not null,end_date date,state text not null default 'active' check(state in ('active','paused','ended')),revision bigint not null default 0,unique(id,household_id),foreign key(card_id,household_id) references credit_cards(id,household_id));
create table public.cc_obligations(id uuid primary key default gen_random_uuid(),household_id uuid not null references households,card_id uuid not null,responsible_id uuid not null references auth.users,title text not null,category text not null,amount numeric(16,2) not null check(amount>0 and amount<>'NaN'::numeric),due_date date not null,mode text not null check(mode in ('automatic','manual')),state text not null default 'pending' check(state in ('pending','posted','cancelled')),recurrence_id uuid,generation_error text not null default '',revision bigint not null default 0,unique(recurrence_id,due_date),unique(id,household_id),foreign key(card_id,household_id) references credit_cards(id,household_id),foreign key(recurrence_id,household_id) references cc_recurrences(id,household_id));
create table public.cc_purchases(id uuid primary key default gen_random_uuid(),household_id uuid not null references households,card_id uuid not null,responsible_id uuid not null references auth.users,title text not null,category text not null,amount numeric(16,2) not null,charge_date date not null,installments integer not null check(installments between 1 and 120),next_installment integer not null,obligation_id uuid unique,created_at timestamptz not null default now(),unique(id,household_id),foreign key(card_id,household_id) references credit_cards(id,household_id),foreign key(obligation_id,household_id) references cc_obligations(id,household_id));
create table public.cc_lines(id uuid primary key default gen_random_uuid(),household_id uuid not null references households,invoice_id uuid not null,card_id uuid not null,purchase_id uuid,responsible_id uuid not null references auth.users,title text not null,category text not null,amount numeric(16,2) not null check(amount<>'NaN'::numeric),paid numeric(16,2) not null default 0 check(paid>=0),line_type text not null check(line_type in ('principal','fee','refund','discount','credit')),installment integer,charge_date date not null,unique(purchase_id,installment),unique(id,household_id),foreign key(invoice_id,household_id) references cc_invoices(id,household_id),foreign key(card_id,household_id) references credit_cards(id,household_id),foreign key(purchase_id,household_id) references cc_purchases(id,household_id));
create table public.cc_payments(id uuid primary key,household_id uuid not null references households,invoice_id uuid not null,account_id uuid not null,amount numeric(16,2) not null,paid_date date not null,reversed_at timestamptz,unique(id,household_id),foreign key(invoice_id,household_id) references cc_invoices(id,household_id),foreign key(account_id,household_id) references financial_accounts(id,household_id));
create table public.cc_allocations(payment_id uuid not null,line_id uuid not null,household_id uuid not null,amount numeric(16,2) not null check(amount>0),primary key(payment_id,line_id),foreign key(payment_id,household_id) references cc_payments(id,household_id),foreign key(line_id,household_id) references cc_lines(id,household_id));
create index cc_lines_invoice on public.cc_lines(invoice_id);
create index cc_pending_obligations on public.cc_obligations(household_id,due_date) where state='pending';
create index cc_lines_card on public.cc_lines(card_id);

-- New tables are read-only to clients; all writes pass the transactional RPC.
do $$declare t text;begin
 foreach t in array array['cc_requests','cc_invoices','cc_recurrences','cc_obligations','cc_purchases','cc_lines','cc_payments','cc_allocations'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('create policy cc_read on public.%I for select to authenticated using(public.is_household_member(household_id))',t);
  execute format('grant select on public.%I to authenticated',t);
 end loop;
end $$;

-- Applies to future card writes only; invalid legacy relationships remain for diagnosis.
create function public.cc_validate_card() returns trigger language plpgsql security definer set search_path=public as $$
declare p credit_cards%rowtype;
begin
 if not exists(select 1 from household_members where household_id=new.household_id and user_id=new.owner_id) then raise exception 'Titular inválido';end if;
 if not exists(select 1 from financial_accounts where id=new.account_id and household_id=new.household_id and owner_id=new.owner_id and account_type<>'investment' and active) then raise exception 'Selecione uma conta ativa do titular';end if;
 if new.parent_card_id is not null then
  select * into p from credit_cards where id=new.parent_card_id and household_id=new.household_id;
  if not found or p.parent_card_id is not null or p.id=new.id then raise exception 'Cartão principal inválido';end if;
 end if;
 if tg_op='UPDATE' then
  new.revision:=old.revision+1;
  if new.parent_card_id is distinct from old.parent_card_id and (exists(select 1 from cc_lines where card_id=new.id) or exists(select 1 from financial_events where card_id=new.id)) then raise exception 'Cartão com histórico não pode mudar de grupo de fatura';end if;
  if new.owner_id<>old.owner_id and (exists(select 1 from cc_invoices where card_id=new.id) or exists(select 1 from cc_lines where card_id=new.id) or exists(select 1 from financial_events where card_id=new.id)) then raise exception 'Cartão com histórico deve preservar titularidade; cadastre outro cartão';end if;
 end if;
 return new;
end $$;
create trigger cc_card_validation before insert or update on public.credit_cards for each row execute function public.cc_validate_card();

create function public.cc_day(p_month date,p_day integer) returns date language sql immutable as $$select date_trunc('month',p_month)::date+least(p_day,extract(day from date_trunc('month',p_month)+interval '1 month - 1 day')::int)-1$$;
create function public.cc_cycle(p_date date,p_close integer) returns date language sql immutable as $$select (date_trunc('month',p_date)+case when p_date>=public.cc_day(p_date,p_close) then interval '1 month' else interval '0' end)::date$$;
create function public.cc_invoice(p_card uuid,p_cycle date) returns uuid language plpgsql security definer set search_path=public as $$
declare c credit_cards%rowtype;v uuid;d date;
begin
 select * into c from credit_cards where id=p_card;
 if not found or not is_household_member(c.household_id) or c.parent_card_id is not null then raise exception 'Cartão inválido';end if;
 d:=cc_day((p_cycle+case when c.due_day<=c.closing_day then interval '1 month' else interval '0' end)::date,c.due_day);
 insert into cc_invoices(household_id,card_id,cycle,closing_date,due_date) values(c.household_id,c.id,date_trunc('month',p_cycle)::date,cc_day(p_cycle,c.closing_day),d) on conflict(card_id,cycle) do nothing;
 select id into v from cc_invoices where card_id=c.id and cycle=date_trunc('month',p_cycle)::date;return v;
end $$;

create function public.cc_post_purchase(p_card uuid,p_responsible uuid,p_title text,p_category text,p_amount numeric,p_date date,p_count integer,p_next integer default 1,p_first_cycle date default null,p_obligation uuid default null) returns uuid language plpgsql security definer set search_path=public as $$
declare c credit_cards%rowtype;r credit_cards%rowtype;pid uuid;cy date;iv uuid;part numeric;v numeric;i integer;committed numeric;
begin
 select * into c from credit_cards where id=p_card;
 if not found or not is_household_member(c.household_id) or c.card_status<>'active' then raise exception 'Cartão indisponível';end if;
 select * into r from credit_cards where id=coalesce(c.parent_card_id,c.id) for update;
 if r.card_status<>'active' then raise exception 'Cartão principal indisponível';end if;
 if not exists(select 1 from household_members where household_id=c.household_id and user_id=p_responsible) then raise exception 'Responsável inválido';end if;
 if p_amount is null or p_amount='NaN'::numeric or p_amount<=0 or p_amount>9000000000000 or p_amount<>round(p_amount,2) or p_count is null or p_count not between 1 and 120 or p_next is null or p_next not between 1 and p_count or p_amount*100<p_count or p_date is null or p_date>(now() at time zone 'America/Fortaleza')::date or p_title is null or length(trim(p_title)) not between 1 and 200 or p_category is null or length(trim(p_category)) not between 1 and 100 then raise exception 'Compra inválida';end if;
 if p_next>1 and p_first_cycle is null then raise exception 'Informe a primeira fatura do parcelamento antigo';end if;
 cy:=coalesce(date_trunc('month',p_first_cycle)::date,cc_cycle(p_date,r.closing_day));
 part:=trunc(p_amount/p_count,2);committed:=p_amount-part*(p_next-1);
 -- New cards have an explicit limit; do not silently assume a limit for old cards.
 select greatest(coalesce(sum(case when l.line_type='fee' then 0 else l.amount-l.paid end),0),0) into v from cc_lines l join credit_cards k on k.id=l.card_id where coalesce(k.parent_card_id,k.id)=r.id;
 v:=v+coalesce((select sum(e.amount-e.paid_amount) from financial_events e join credit_cards k on k.id=e.card_id where coalesce(k.parent_card_id,k.id)=r.id and e.status='pending'),0);
 if v+committed>r.credit_limit then raise exception 'Limite disponível insuficiente';end if;
 insert into cc_purchases(household_id,card_id,responsible_id,title,category,amount,charge_date,installments,next_installment,obligation_id) values(c.household_id,c.id,p_responsible,trim(p_title),p_category,p_amount,p_date,p_count,p_next,p_obligation) returning id into pid;
 for i in p_next..p_count loop
  iv:=cc_invoice(r.id,(cy+make_interval(months=>i-p_next))::date);
  insert into cc_lines(household_id,invoice_id,card_id,purchase_id,responsible_id,title,category,amount,line_type,installment,charge_date) values(c.household_id,iv,c.id,pid,p_responsible,trim(p_title),p_category,case when i=p_count then p_amount-part*(p_count-1) else part end,'principal',i,p_date);
  update cc_invoices set revision=revision+1 where id=iv;
 end loop;return pid;
end $$;

create function public.cc_generate(p_household uuid,p_through date) returns void language plpgsql security definer set search_path=public as $$
declare r cc_recurrences%rowtype;o cc_obligations%rowtype;c credit_cards%rowtype;d date;i integer;cap date;cur date:=(now() at time zone 'America/Fortaleza')::date;
begin
 if not is_household_member(p_household) or p_through is null or p_through>cur+interval '2 years' then raise exception 'Horizonte inválido';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 for c in select * from credit_cards where household_id=p_household and parent_card_id is null and module_version=2 and card_status='active' loop
  d:=date_trunc('month',cur)::date;
  while d<=p_through loop perform cc_invoice(c.id,d);d:=(d+interval '1 month')::date;end loop;
 end loop;
 for r in select * from cc_recurrences where household_id=p_household and state='active' and card_id in (select id from credit_cards where card_status='active') order by id loop
  cap:=least(coalesce(r.end_date,p_through),p_through);i:=0;d:=r.start_date;
  while d<=cap loop
   if i>4000 then raise exception 'Muitas ocorrências';end if;
   insert into cc_obligations(household_id,card_id,responsible_id,title,category,amount,due_date,mode,recurrence_id) values(r.household_id,r.card_id,r.responsible_id,r.title,r.category,r.amount,d,r.mode,r.id) on conflict(recurrence_id,due_date) do nothing;
   i:=i+1;d:=case when r.unit='days' then r.start_date+i*r.every else cc_day((date_trunc('month',r.start_date)+make_interval(months=>i*r.every))::date,extract(day from r.start_date)::int) end;
  end loop;
 end loop;
 for o in select ob.* from cc_obligations ob join credit_cards plastic on plastic.id=ob.card_id left join cc_recurrences rec on rec.id=ob.recurrence_id where ob.household_id=p_household and ob.state='pending' and ob.mode='automatic' and ob.due_date<=cur and plastic.card_status='active' and (rec.id is null or rec.state='active') order by ob.due_date,ob.id for update of ob loop
  -- Over-limit or blocked automatic charges stay visible and pending; never disappear.
  begin
   perform cc_post_purchase(o.card_id,o.responsible_id,o.title,o.category,o.amount,o.due_date,1,1,null,o.id);
   update cc_obligations set state='posted',revision=revision+1 where id=o.id;
  exception when raise_exception then update cc_obligations set generation_error=sqlerrm where id=o.id and generation_error is distinct from sqlerrm;
  end;
 end loop;
end $$;

create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare req cc_requests%rowtype;c credit_cards%rowtype;r credit_cards%rowtype;iv cc_invoices%rowtype;ob cc_obligations%rowtype;rec cc_recurrences%rowtype;pay cc_payments%rowtype;ln cc_lines%rowtype;a cc_allocations%rowtype;
 v_id uuid;root_id uuid;owner uuid;acct uuid;other uuid;v numeric;due numeric;portion numeric;rest numeric;discount numeric;qty integer;cur date:=(now() at time zone 'America/Fortaleza')::date;op_date date;cy date;result jsonb:='{}';expected bigint;old_data jsonb;
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 if p_id is null or p_data is null then raise exception 'Requisição inválida';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));
 select * into req from cc_requests where id=p_id;
 if found then
  if req.household_id<>p_household or req.action<>p_action or req.parameters<>p_data then raise exception 'Chave já utilizada';end if;return req.result;
 end if;
 -- Household-wide serialization covers shared limits, adjustments and payment reversals.
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 if p_action='save_card' then
  v_id:=coalesce((p_data->>'card_id')::uuid,p_id);select * into c from credit_cards where id=v_id for update;
  if found and (c.household_id<>p_household or (p_data->>'revision')::bigint is distinct from c.revision) then raise exception 'Cartão atualizado por outra operação';end if;
  owner:=(p_data->>'owner_id')::uuid;acct:=(p_data->>'account_id')::uuid;root_id:=(p_data->>'parent_card_id')::uuid;v:=(p_data->>'credit_limit')::numeric;
  if p_data->>'name' is null or length(trim(p_data->>'name')) not between 1 and 120 or v is null or v='NaN'::numeric or v<0 or v>9000000000000 or v<>round(v,2) or (p_data->>'closing_day')::int not between 1 and 31 or (p_data->>'due_day')::int not between 1 and 31 or coalesce(p_data->>'card_status','') not in ('active','blocked','archived') then raise exception 'Dados do cartão inválidos';end if;
  if c.id is null then
   insert into credit_cards(id,household_id,owner_id,account_id,name,closing_day,due_day,issuer,brand,last_four,credit_limit,automatic_debit,color,card_status,parent_card_id,module_version) values(v_id,p_household,owner,acct,trim(p_data->>'name'),(p_data->>'closing_day')::int,(p_data->>'due_day')::int,coalesce(p_data->>'issuer',''),coalesce(p_data->>'brand',''),coalesce(p_data->>'last_four',''),v,coalesce((p_data->>'automatic_debit')::boolean,false),coalesce(p_data->>'color','#765484'),p_data->>'card_status',root_id,2);
  else
   update credit_cards set owner_id=owner,account_id=acct,name=trim(p_data->>'name'),closing_day=(p_data->>'closing_day')::int,due_day=(p_data->>'due_day')::int,issuer=coalesce(p_data->>'issuer',''),brand=coalesce(p_data->>'brand',''),last_four=coalesce(p_data->>'last_four',''),credit_limit=v,automatic_debit=coalesce((p_data->>'automatic_debit')::boolean,false),color=coalesce(p_data->>'color','#765484'),card_status=p_data->>'card_status',parent_card_id=root_id,module_version=2 where id=v_id;
  end if;result:=jsonb_build_object('card_id',v_id);
 elsif p_action in ('purchase','obligation','recurrence') then
  select * into c from credit_cards where id=(p_data->>'card_id')::uuid and household_id=p_household;
  if not found or c.card_status<>'active' then raise exception 'Cartão indisponível';end if;
  owner:=(p_data->>'responsible_id')::uuid;v:=(p_data->>'amount')::numeric;op_date:=(p_data->>'date')::date;
  if not exists(select 1 from household_members where household_id=p_household and user_id=owner) or v is null or v='NaN'::numeric or v<=0 or v>9000000000000 or v<>round(v,2) or op_date is null or length(trim(coalesce(p_data->>'title',''))) not between 1 and 200 or length(trim(coalesce(p_data->>'category',''))) not between 1 and 100 then raise exception 'Lançamento inválido';end if;
  if p_action='purchase' then
   v_id:=cc_post_purchase(c.id,owner,p_data->>'title',p_data->>'category',v,op_date,(p_data->>'installments')::int,coalesce((p_data->>'next_installment')::int,1),(p_data->>'first_cycle')::date,null);
  elsif p_action='obligation' then
   insert into cc_obligations(household_id,card_id,responsible_id,title,category,amount,due_date,mode) values(p_household,c.id,owner,p_data->>'title',p_data->>'category',v,op_date,p_data->>'mode') returning id into v_id;
   perform cc_generate(p_household,cur);
  else
   if (p_data->>'end_date')::date<op_date then raise exception 'Término inválido';end if;
   insert into cc_recurrences(id,household_id,card_id,responsible_id,title,category,amount,mode,variable,unit,every,start_date,end_date) values(p_id,p_household,c.id,owner,p_data->>'title',p_data->>'category',v,p_data->>'mode',coalesce((p_data->>'variable')::boolean,false),p_data->>'unit',(p_data->>'every')::int,op_date,(p_data->>'end_date')::date) returning id into v_id;
   perform cc_generate(p_household,least(cur+interval '1 year',coalesce((p_data->>'end_date')::date,cur+interval '1 year'))::date);
  end if;result:=jsonb_build_object('id',v_id);
 elsif p_action in ('confirm_obligation','edit_obligation','cancel_obligation') then
  select * into ob from cc_obligations where id=(p_data->>'obligation_id')::uuid and household_id=p_household for update;
  if not found or ob.state<>'pending' or (p_data->>'revision')::bigint is distinct from ob.revision then raise exception 'Obrigação alterada; atualize a tela';end if;
  if p_action='confirm_obligation' then
   if ob.mode<>'manual' then raise exception 'Cobranças automáticas são registradas pela rotina';end if;
   op_date:=(p_data->>'date')::date;v:=coalesce((p_data->>'amount')::numeric,ob.amount);
   v_id:=cc_post_purchase(ob.card_id,ob.responsible_id,ob.title,ob.category,v,op_date,1,1,null,ob.id);
   update cc_obligations set state='posted',amount=v,revision=revision+1 where id=ob.id;result:=jsonb_build_object('purchase_id',v_id);
   update cc_recurrences set amount=v,revision=revision+1 where id=ob.recurrence_id and variable;
   update cc_obligations set amount=v,revision=revision+1 where recurrence_id=ob.recurrence_id and state='pending' and due_date>ob.due_date and exists(select 1 from cc_recurrences where id=ob.recurrence_id and variable);
  elsif p_action='cancel_obligation' then update cc_obligations set state='cancelled',revision=revision+1 where id=ob.id;
  else
   v:=(p_data->>'amount')::numeric;op_date:=(p_data->>'date')::date;
   if v is null or v='NaN'::numeric or v<=0 or v>9000000000000 or v<>round(v,2) or op_date is null then raise exception 'Valor ou data inválidos';end if;
   update cc_obligations set amount=v,due_date=op_date,revision=revision+1 where id=ob.id;
  end if;
 elsif p_action='edit_recurrence' then
  select * into rec from cc_recurrences where id=(p_data->>'recurrence_id')::uuid and household_id=p_household for update;
  if not found or (p_data->>'revision')::bigint is distinct from rec.revision then raise exception 'Recorrência atualizada; recarregue';end if;
  v:=(p_data->>'amount')::numeric;
  if v is null or v='NaN'::numeric or v<=0 or v>9000000000000 or v<>round(v,2) then raise exception 'Valor inválido';end if;
  if (p_data->>'end_date')::date<rec.start_date then raise exception 'Término inválido';end if;
  if rec.state='ended' and p_data->>'state'<>'ended' then raise exception 'Recorrência encerrada: cadastre uma nova regra';end if;
  if (p_data->>'unit' is not null and p_data->>'unit'<>rec.unit) or ((p_data->>'every')::int is not null and (p_data->>'every')::int<>rec.every) or ((p_data->>'start_date')::date is not null and (p_data->>'start_date')::date<>rec.start_date) then
   if p_data->>'state'<>'active' or (p_data->>'start_date')::date<cur then raise exception 'Nova periodicidade deve iniciar hoje ou no futuro, com estado ativo';end if;
   update cc_recurrences set state='ended',revision=revision+1 where id=rec.id;
   update cc_obligations set state='cancelled',revision=revision+1 where recurrence_id=rec.id and state='pending' and due_date>=cur;
   insert into cc_recurrences(id,household_id,card_id,responsible_id,title,category,amount,mode,variable,unit,every,start_date,end_date) values(p_id,p_household,rec.card_id,rec.responsible_id,rec.title,rec.category,v,rec.mode,rec.variable,coalesce(p_data->>'unit',rec.unit),coalesce((p_data->>'every')::int,rec.every),coalesce((p_data->>'start_date')::date,cur),(p_data->>'end_date')::date);
   perform cc_generate(p_household,(cur+interval '1 year')::date);
   result:=jsonb_build_object('recurrence_id',p_id);
   insert into cc_requests(id,household_id,actor_id,action,parameters,result) values(p_id,p_household,auth.uid(),p_action,p_data,result);return result;
  end if;
  -- Existing posted history stays immutable. Pending occurrences can be explicitly cancelled.
  update cc_recurrences set amount=v,state=p_data->>'state',end_date=(p_data->>'end_date')::date,revision=revision+1 where id=rec.id;
  update cc_obligations set amount=v,revision=revision+1 where recurrence_id=rec.id and state='pending';
  if p_data->>'state'='ended' or coalesce((p_data->>'cancel_pending')::boolean,false) then update cc_obligations set state='cancelled',revision=revision+1 where recurrence_id=rec.id and state='pending' and due_date>=cur;end if;
  perform cc_generate(p_household,(cur+interval '1 year')::date);
 elsif p_action in ('pay_invoice','fee','refund','anticipate','transfer_credit') then
  select * into iv from cc_invoices where id=(p_data->>'invoice_id')::uuid and household_id=p_household for update;
  if not found or (p_data->>'revision')::bigint is distinct from iv.revision then raise exception 'Fatura atualizada; recarregue';end if;
  select * into r from credit_cards where id=iv.card_id for update;
  v:=(p_data->>'amount')::numeric;op_date:=coalesce((p_data->>'date')::date,cur);
  if v is null or v='NaN'::numeric or v<=0 or v>9000000000000 or v<>round(v,2) or op_date>cur then raise exception 'Valor ou data inválidos';end if;
  select coalesce(sum(amount-paid),0) into due from cc_lines where invoice_id=iv.id;
  if p_action='pay_invoice' then
   acct:=coalesce((p_data->>'account_id')::uuid,r.account_id);
   if not exists(select 1 from financial_accounts where id=acct and household_id=p_household and owner_id=r.owner_id and account_type<>'investment' and active) then raise exception 'Selecione uma conta ativa do titular';end if;
   if v>due then raise exception 'Valor superior ao saldo da fatura';end if;
   insert into cc_payments(id,household_id,invoice_id,account_id,amount,paid_date) values(p_id,p_household,iv.id,acct,v,op_date);
   rest:=v;
   for ln in select * from cc_lines where invoice_id=iv.id and amount>paid order by (line_type='fee') desc,charge_date,id for update loop
    exit when rest=0;portion:=least(rest,ln.amount-ln.paid);
    insert into cc_allocations values(p_id,ln.id,p_household,portion);update cc_lines set paid=paid+portion where id=ln.id;rest:=rest-portion;
   end loop;
   insert into account_ledger(household_id,account_id,amount,operation_key,actor_id) values(p_household,acct,-v,'cc-pay:'||p_id,auth.uid());
  elsif p_action='fee' then
   insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,iv.id,r.id,r.owner_id,coalesce(nullif(trim(p_data->>'title'),''),'Juros / multa informados'),'Encargos',v,'fee',op_date);
  elsif p_action='refund' then
   select * into ln from cc_lines where id=(p_data->>'line_id')::uuid and household_id=p_household and line_type='principal' for update;
   if not found or not exists(select 1 from credit_cards where id=ln.card_id and coalesce(parent_card_id,id)=r.id) then raise exception 'Compra inválida';end if;
   if v>coalesce((select sum(amount) from cc_lines where purchase_id=ln.purchase_id and line_type in ('principal','refund','discount')),0) then raise exception 'Estorno superior ao principal disponível';end if;
   insert into cc_lines(household_id,invoice_id,card_id,purchase_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,iv.id,ln.card_id,ln.purchase_id,ln.responsible_id,'Estorno · '||ln.title,ln.category,-v,'refund',op_date);
  elsif p_action='anticipate' then
   select * into ln from cc_lines where id=(p_data->>'line_id')::uuid and household_id=p_household and line_type='principal' for update;
   if not found or ln.paid<>0 or ln.invoice_id=iv.id or not exists(select 1 from cc_invoices where id=ln.invoice_id and card_id=r.id and due_date>iv.due_date) then raise exception 'Parcela futura inválida';end if;
   if v<>ln.amount then raise exception 'Valor da parcela mudou';end if;
   discount:=coalesce((p_data->>'discount')::numeric,0);
   if discount='NaN'::numeric or discount<0 or discount>v or discount<>round(discount,2) then raise exception 'Desconto inválido';end if;
   update cc_lines set invoice_id=iv.id where id=ln.id;
   if discount>0 then insert into cc_lines(household_id,invoice_id,card_id,purchase_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,iv.id,ln.card_id,ln.purchase_id,ln.responsible_id,'Desconto por antecipação',ln.category,-discount,'discount',op_date);end if;
   update cc_invoices set revision=revision+1 where id=ln.invoice_id;
  else
   select * into ln from cc_lines where invoice_id=iv.id limit 1;
   other:=(p_data->>'target_invoice_id')::uuid;
   if v> -due or not exists(select 1 from cc_invoices where id=other and card_id=r.id and id<>iv.id) then raise exception 'Crédito ou destino inválido';end if;
   insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,iv.id,r.id,r.owner_id,'Crédito transferido','Crédito',v,'credit',op_date),(p_household,other,r.id,r.owner_id,'Crédito recebido','Crédito',-v,'credit',op_date);
   update cc_invoices set revision=revision+1 where id=other;
  end if;
  update cc_invoices set revision=revision+1 where id=iv.id;
 elsif p_action='undo_payment' then
  select * into pay from cc_payments where id=(p_data->>'payment_id')::uuid and household_id=p_household for update;
  if not found or pay.reversed_at is not null then raise exception 'Pagamento já desfeito';end if;
  select * into iv from cc_invoices where id=pay.invoice_id for update;
  for a in select * from cc_allocations where payment_id=pay.id loop update cc_lines set paid=paid-a.amount where id=a.line_id;end loop;
  insert into account_ledger(household_id,account_id,amount,operation_key,actor_id) values(p_household,pay.account_id,pay.amount,'cc-undo:'||pay.id,auth.uid());
  update cc_payments set reversed_at=now() where id=pay.id;update cc_invoices set revision=revision+1 where id=pay.invoice_id;
 else raise exception 'Operação inválida';end if;
 insert into cc_requests(id,household_id,actor_id,action,parameters,result) values(p_id,p_household,auth.uid(),p_action,p_data,result);return result;
end $$;

-- Internal helpers are not public endpoints.
revoke all on function public.cc_validate_card(),public.cc_invoice(uuid,date),public.cc_post_purchase(uuid,uuid,text,text,numeric,date,integer,integer,date,uuid),public.cc_generate(uuid,date),public.cc_action(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.cc_generate(uuid,date),public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';

-- Prevent new-module cards from bypassing consolidated invoices via the legacy endpoint.
alter function public.create_card_purchase(uuid,uuid,text,numeric,date,integer) rename to create_card_purchase_legacy;
revoke all on function public.create_card_purchase_legacy(uuid,uuid,text,numeric,date,integer) from public,anon,authenticated;
create function public.create_card_purchase(p_id uuid,p_card uuid,p_title text,p_amount numeric,p_date date,p_installments integer) returns void language plpgsql security definer set search_path=public as $$
begin
 if exists(select 1 from credit_cards where id=p_card and module_version=2) then raise exception 'Use Despesa no cartão no módulo de cartões';end if;
 perform create_card_purchase_legacy(p_id,p_card,p_title,p_amount,p_date,p_installments);
end $$;
revoke all on function public.create_card_purchase(uuid,uuid,text,numeric,date,integer) from public,anon;
grant execute on function public.create_card_purchase(uuid,uuid,text,numeric,date,integer) to authenticated;
notify pgrst,'reload schema';

-- Row-level audit for edits, cancellations, allocations and compensating actions.
create table public.cc_audit(id bigint generated always as identity primary key,household_id uuid not null references households,actor_id uuid,table_name text not null,before_data jsonb,after_data jsonb,occurred_at timestamptz not null default now());
alter table public.cc_audit enable row level security;
create policy cc_audit_read on public.cc_audit for select to authenticated using(is_household_member(household_id));
grant select on public.cc_audit to authenticated;
create function public.cc_audit_row() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into cc_audit(household_id,actor_id,table_name,before_data,after_data) values(new.household_id,auth.uid(),tg_table_name,case when tg_op='UPDATE' then to_jsonb(old) else null end,to_jsonb(new));return new;
end $$;
revoke all on function public.cc_audit_row() from public,anon,authenticated;
do $$declare t text;begin
 foreach t in array array['credit_cards','cc_invoices','cc_recurrences','cc_obligations','cc_purchases','cc_lines','cc_payments','cc_allocations'] loop
  execute format('create trigger cc_audit after insert or update on public.%I for each row execute function public.cc_audit_row()',t);
 end loop;
end $$;
notify pgrst,'reload schema';


-- Additive, after 019. All imports require explicit final confirmation.
alter table cc_lines drop constraint cc_lines_line_type_check;
alter table cc_lines add constraint cc_lines_line_type_check check(line_type in ('principal','fee','refund','discount','credit','adjustment'));
alter table cc_lines add column original_description text,add column bank_transaction_id text;
create unique index cc_bank_transaction_unique on cc_lines(card_id,bank_transaction_id) where bank_transaction_id is not null;
create table cc_imports(id uuid primary key,household_id uuid not null references households,card_id uuid not null references credit_cards,invoice_id uuid not null references cc_invoices,file_hash text not null check(file_hash ~ '^[a-f0-9]{64}$'),file_name text not null,actor_id uuid not null references auth.users,summary jsonb not null,created_at timestamptz not null default now(),unique(card_id,file_hash));
create table cc_invoice_targets(invoice_id uuid primary key references cc_invoices,household_id uuid not null references households,target numeric(16,2) not null,updated_at timestamptz not null default now());
create table cc_adjustment_reversals(line_id uuid primary key references cc_lines,household_id uuid not null references households,reversal_line_id uuid not null references cc_lines);
do $$declare t text;begin foreach t in array array['cc_imports','cc_invoice_targets','cc_adjustment_reversals'] loop
 execute format('alter table %I enable row level security',t);
 execute format('create policy member_read on %I for select to authenticated using(is_household_member(household_id))',t);
 execute format('grant select on %I to authenticated',t);
 execute format('create trigger cc_audit after insert or update on %I for each row execute function cc_audit_row()',t);
end loop;end $$;
create function cc_reconcile(p_invoice uuid,p_total numeric) returns uuid language plpgsql security definer set search_path=public as $$
declare i cc_invoices%rowtype;c credit_cards%rowtype;delta numeric;lid uuid;
begin
 select * into i from cc_invoices where id=p_invoice for update;select * into c from credit_cards where id=i.card_id;
 if not is_household_member(i.household_id) or p_total is null or p_total='NaN'::numeric or abs(p_total)>9000000000000 or p_total<>round(p_total,2) then raise exception 'Total inválido';end if;
 select p_total-coalesce(sum(amount),0) into delta from cc_lines where invoice_id=i.id;
 if delta<>0 then insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date) values(i.household_id,i.id,c.id,c.owner_id,case when delta>0 then 'Complemento de Fatura' else 'Redução de Fatura' end,'Ajuste de Fatura',delta,'adjustment',i.closing_date) returning id into lid;end if;
 update cc_invoices set revision=revision+1 where id=i.id;return lid;
end $$;
alter function cc_action(uuid,uuid,text,jsonb) rename to cc_action_v19;
revoke all on function cc_action_v19(uuid,uuid,text,jsonb),cc_reconcile(uuid,numeric) from public,anon,authenticated;
create function cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare i cc_invoices%rowtype;c credit_cards%rowtype;plastic credit_cards%rowtype;prior cc_requests%rowtype;row jsonb;pid uuid;lid uuid;old_target numeric;result jsonb;v numeric;original cc_lines%rowtype;n_new int:=0;n_link int:=0;n_skip int:=0;records jsonb:='[]';
begin
 if p_action not in ('import_statement','adjust_invoice','reverse_adjustment') then return cc_action_v19(p_id,p_household,p_action,p_data);end if;
 if not is_household_member(p_household) or p_id is null then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 select * into prior from cc_requests where id=p_id;
 if found then if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;return prior.result;end if;
 select * into i from cc_invoices where id=(p_data->>'invoice_id')::uuid and household_id=p_household for update;
 if not found or i.revision is distinct from (p_data->>'revision')::bigint then raise exception 'Fatura atualizada; revise novamente';end if;
 select * into c from credit_cards where id=i.card_id;
 if p_action='adjust_invoice' then
  lid:=cc_reconcile(i.id,(p_data->>'total')::numeric);
  insert into cc_invoice_targets values(i.id,p_household,(p_data->>'total')::numeric,now()) on conflict(invoice_id) do update set target=excluded.target,updated_at=now();
 elsif p_action='reverse_adjustment' then
  select * into original from cc_lines where id=(p_data->>'line_id')::uuid and invoice_id=i.id and line_type='adjustment';
  if not found or exists(select 1 from cc_adjustment_reversals where line_id=original.id or reversal_line_id=original.id) then raise exception 'Ajuste inválido ou já revertido';end if;
  insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,i.id,c.id,c.owner_id,'Reversão · '||original.title,'Ajuste de Fatura',-original.amount,'adjustment',i.closing_date) returning id into lid;
  insert into cc_adjustment_reversals values(original.id,p_household,lid);update cc_invoices set revision=revision+1 where id=i.id;
  insert into cc_invoice_targets values(i.id,p_household,(select sum(amount) from cc_lines where invoice_id=i.id),now()) on conflict(invoice_id) do update set target=excluded.target,updated_at=now();
 else
  select * into plastic from credit_cards where id=coalesce((p_data->>'card_id')::uuid,c.id) and household_id=p_household and coalesce(parent_card_id,id)=c.id;
  if not found then raise exception 'Cartão da importação inválido';end if;
  if p_data->>'confirmed' is distinct from 'true' or jsonb_typeof(p_data->'rows')<>'array' or jsonb_array_length(p_data->'rows') not between 1 and 1000 then raise exception 'Confirme a conferência dos lançamentos';end if;
  if exists(select 1 from cc_imports where card_id=plastic.id and file_hash=p_data->>'file_hash') then raise exception 'Arquivo já importado: consulte o histórico';end if;
  select target into old_target from cc_invoice_targets where invoice_id=i.id;
  if coalesce((p_data->>'keep_target')::boolean,false) and old_target is not null then perform cc_reconcile(i.id,old_target-coalesce((select sum((value->>'amount')::numeric) from jsonb_array_elements(p_data->'rows') where value->>'decision'='new'),0));end if;
  for row in select value from jsonb_array_elements(p_data->'rows') loop
   lid:=null;
   if row->>'decision'='skip' then n_skip:=n_skip+1;
   elsif row->>'decision'='link' then
    select * into original from cc_lines where id=(row->>'match_id')::uuid and household_id=p_household and card_id=plastic.id;
    if not found then raise exception 'Correspondência inválida';end if;lid:=original.id;n_link:=n_link+1;
   elsif row->>'decision'='new' then
    if row->>'kind'='payment' then raise exception 'Pagamento anterior não é compra; descarte ou vincule ao histórico';end if;
    v:=(row->>'amount')::numeric;
    if v is null or v='NaN'::numeric or v=0 or abs(v)>9000000000000 or v<>round(v,2) or length(trim(coalesce(row->>'description',''))) not between 1 and 200 or length(trim(coalesce(row->>'category',''))) not between 1 and 100 or (row->>'date')::date is null or (row->>'date')::date>(now() at time zone 'America/Fortaleza')::date then raise exception 'Linha incompleta ou inválida';end if;
    if row->>'kind'='purchase' and v>0 then
     if (row->>'total_amount')::numeric is null then raise exception 'Confirme o valor total do parcelamento';end if;
     pid:=cc_post_purchase(plastic.id,plastic.owner_id,row->>'description',row->>'category',(row->>'total_amount')::numeric,(row->>'date')::date,(row->>'count')::int,(row->>'installment')::int,i.cycle,null);
     select id into lid from cc_lines where purchase_id=pid and installment=(row->>'installment')::int;
     if (select amount from cc_lines where id=lid)<>v then raise exception 'Parcela não corresponde ao total confirmado';end if;
    elsif row->>'kind' in ('refund','fee','credit') then
     if (row->>'kind'='fee' and v<0) or (row->>'kind' in ('refund','credit') and v>0) then raise exception 'Sinal incompatível com o tipo';end if;
     insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,i.id,plastic.id,plastic.owner_id,row->>'description',row->>'category',v,case when row->>'kind'='fee' then 'fee' else 'refund' end,(row->>'date')::date) returning id into lid;
    else raise exception 'Tipo inválido';end if;
    update cc_lines set original_description=row->>'original',bank_transaction_id=nullif(row->>'bank_id','') where id=lid;n_new:=n_new+1;
   else raise exception 'Decida explicitamente cada linha';end if;
   records:=records||jsonb_build_array(row||jsonb_build_object('line_id',lid));
  end loop;
  if coalesce((p_data->>'keep_target')::boolean,false) then
   if old_target is null then raise exception 'Não há total conciliado anterior';end if;perform cc_reconcile(i.id,old_target);
  end if;
  update cc_invoices set revision=revision+1 where id=i.id;
  insert into cc_imports values(p_id,p_household,plastic.id,i.id,p_data->>'file_hash',left(p_data->>'file_name',200),auth.uid(),jsonb_build_object('identified',jsonb_array_length(p_data->'rows'),'imported',n_new,'linked',n_link,'discarded',n_skip,'rows',records,'metadata',p_data->'metadata'),now());
 end if;
 result:=jsonb_build_object('line_id',lid,'imported',n_new,'linked',n_link,'discarded',n_skip);
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());return result;
end $$;
revoke all on function cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';

create function record_cc_import_error(p_household uuid,p_data jsonb) returns void language plpgsql security definer set search_path=public as $$
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 insert into cc_requests values(gen_random_uuid(),p_household,auth.uid(),'import_client_error',jsonb_build_object('file_name',left(p_data->>'file_name',200),'error',left(p_data->>'error',500)),'{}',now());
end $$;
revoke all on function record_cc_import_error(uuid,jsonb) from public,anon;
grant execute on function record_cc_import_error(uuid,jsonb) to authenticated;

-- No email is sent by this migration. Users opt in after external setup.
create table notification_settings(household_id uuid primary key references households,enabled boolean not null default false,morning text not null default '08:00',evening text not null default '20:00',weekdays integer[] not null default '{1,2,3,4,5}',holidays date[] not null default '{}',skip_holidays boolean not null default true,timezone text not null default 'America/Fortaleza',recipients uuid[] not null default '{}',revision bigint not null default 0);
create table notification_deliveries(id uuid primary key default gen_random_uuid(),household_id uuid not null references households,user_id uuid not null references auth.users,local_date date not null,slot text not null,status text not null default 'processing',payload jsonb not null,provider_id text,error text,claimed_at timestamptz not null default now(),unique(household_id,user_id,local_date,slot));
alter table notification_settings enable row level security;alter table notification_deliveries enable row level security;
create policy member_read on notification_settings for select to authenticated using(is_household_member(household_id));
create policy member_read on notification_deliveries for select to authenticated using(is_household_member(household_id));
grant select on notification_settings,notification_deliveries to authenticated;
create function save_notification_settings(p_household uuid,p_data jsonb) returns void language plpgsql security definer set search_path=public as $$
declare ids uuid[];days integer[];tz text;rev bigint;
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,210));
 select revision into rev from notification_settings where household_id=p_household;
 if rev is not null and rev is distinct from (p_data->>'revision')::bigint then raise exception 'Configuração atualizada; recarregue';end if;
 select coalesce(array_agg(value::uuid),'{}') into ids from jsonb_array_elements_text(p_data->'recipients');
 select coalesce(array_agg(value::integer),'{}') into days from jsonb_array_elements_text(p_data->'weekdays');
 tz:=p_data->>'timezone';
 if not exists(select 1 from pg_timezone_names where name=tz) or coalesce(p_data->>'morning','')!~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(p_data->>'evening','')!~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or not(days<@array[0,1,2,3,4,5,6]) or exists(select 1 from unnest(ids) u where not exists(select 1 from household_members where household_id=p_household and user_id=u)) then raise exception 'Horário, dias ou destinatários inválidos';end if;
 insert into notification_settings values(p_household,(p_data->>'enabled')::boolean,p_data->>'morning',p_data->>'evening',days,array(select value::date from jsonb_array_elements_text(p_data->'holidays')),(p_data->>'skip_holidays')::boolean,tz,ids,coalesce(rev,0)+1) on conflict(household_id) do update set enabled=excluded.enabled,morning=excluded.morning,evening=excluded.evening,weekdays=excluded.weekdays,holidays=excluded.holidays,skip_holidays=excluded.skip_holidays,timezone=excluded.timezone,recipients=excluded.recipients,revision=excluded.revision;
end $$;
create function notification_snapshot(p_household uuid,p_date date) returns jsonb language sql security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (
 select e.id::text id,e.title,e.owner_id,e.amount-e.paid_amount amount,e.due_date from financial_events e where e.household_id=p_household and e.kind='expense' and e.status='pending' and e.credit_state='none' and e.card_id is null and e.due_date<=p_date
 union all select 'legacy:'||e.card_id||':'||e.due_date,'Fatura anterior · '||c.name,c.owner_id,sum(e.amount-e.paid_amount),e.due_date from financial_events e join credit_cards c on c.id=e.card_id where e.household_id=p_household and e.status='pending' and e.due_date<=p_date group by e.card_id,e.due_date,c.name,c.owner_id
 union all select i.id::text,'Fatura · '||c.name,c.owner_id,sum(l.amount-l.paid),i.due_date from cc_invoices i join credit_cards c on c.id=i.card_id join cc_lines l on l.invoice_id=i.id where i.household_id=p_household and i.due_date<=p_date group by i.id,c.name,c.owner_id having sum(l.amount-l.paid)>0
 union all select o.id::text,o.title||' · lançar manualmente no cartão',o.responsible_id,o.amount,o.due_date from cc_obligations o where o.household_id=p_household and o.mode='manual' and o.state='pending' and o.due_date<=p_date
 ) x;
$$;
create function notification_claim(p_household uuid,p_user uuid,p_date date,p_slot text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare row notification_deliveries%rowtype;
begin
 if not exists(select 1 from household_members where household_id=p_household and user_id=p_user) then return null;end if;
 insert into notification_deliveries(household_id,user_id,local_date,slot,payload) values(p_household,p_user,p_date,p_slot,p_payload) on conflict do nothing;
 select * into row from notification_deliveries where household_id=p_household and user_id=p_user and local_date=p_date and slot=p_slot for update;
 if row.status in ('sent','skipped') or (row.claimed_at>now()-interval '10 minutes' and row.payload<>p_payload) then return null;end if;
 -- Serialize concurrent workers: a fresh insert is claimed using the sent-at lease token.
 if row.status='processing' and row.provider_id='leased' and row.claimed_at>now()-interval '10 minutes' then return null;end if;
 update notification_deliveries set status='processing',provider_id='leased',claimed_at=now() where id=row.id;
 return jsonb_build_object('id',row.id,'payload',row.payload);
end $$;
revoke all on function save_notification_settings(uuid,jsonb),notification_snapshot(uuid,date),notification_claim(uuid,uuid,date,text,jsonb) from public,anon,authenticated;
grant execute on function save_notification_settings(uuid,jsonb) to authenticated;
do $$begin if exists(select 1 from pg_roles where rolname='service_role') then
 grant select,insert,update on notification_settings,notification_deliveries to service_role;
 grant execute on function notification_snapshot(uuid,date),notification_claim(uuid,uuid,date,text,jsonb) to service_role;
end if;end $$;
notify pgrst,'reload schema';

create table public.card_pdf_passwords(user_id uuid not null references auth.users,card_id uuid not null references credit_cards,encrypted_password text not null,updated_at timestamptz not null default now(),primary key(user_id,card_id));
alter table public.card_pdf_passwords enable row level security;
revoke all on public.card_pdf_passwords from public,anon,authenticated;
do $$begin if exists(select 1 from pg_roles where rolname='service_role') then grant select,insert,update,delete on public.card_pdf_passwords to service_role;end if;end $$;
-- Password plaintext is encrypted exclusively in the server, never returned to clients.
alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v21;
revoke all on function public.cc_action_v21(uuid,uuid,text,jsonb) from public,anon,authenticated;
create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare c credit_cards%rowtype;i uuid;original cc_purchases%rowtype;v numeric;d date;prior cc_requests%rowtype;lid uuid;description text;
begin
 if p_action='import_statement' and is_household_member(p_household) and exists(select 1 from jsonb_array_elements(p_data->'rows') r join cc_lines l on l.card_id=coalesce((p_data->>'card_id')::uuid,(select card_id from cc_invoices where id=(p_data->>'invoice_id')::uuid)) and l.line_type='refund' and l.charge_date=(r->>'date')::date and l.amount=(r->>'amount')::numeric and lower(trim(l.title))=lower(trim(r->>'description')) where r->>'kind' in ('refund','credit') and r->>'decision'='new') then raise exception 'Estorno já existente: vincule a linha da importação ao registro';end if;
 if p_action<>'card_refund' then return cc_action_v21(p_id,p_household,p_action,p_data);end if;
 if not is_household_member(p_household) or p_id is null then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 select * into prior from cc_requests where id=p_id;
 if found then if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;return prior.result;end if;
 select * into c from credit_cards where id=(p_data->>'card_id')::uuid and household_id=p_household;
 if not found then raise exception 'Cartão inválido';end if;
 v:=(p_data->>'amount')::numeric;d:=(p_data->>'date')::date;description:=trim(p_data->>'description');
 if v is null or v='NaN'::numeric or v<=0 or v>9000000000000 or v<>round(v,2) or d is null or d>(now() at time zone 'America/Fortaleza')::date or coalesce(length(description),0) not between 1 and 200 then raise exception 'Estorno inválido';end if;
 if p_data->>'purchase_id' is not null then
  select * into original from cc_purchases where id=(p_data->>'purchase_id')::uuid and card_id=c.id for update;
  if not found then raise exception 'Compra inválida';end if;
  if v>original.amount+coalesce((select sum(amount) from cc_lines where purchase_id=original.id and line_type in ('refund','discount')),0) then raise exception 'Estornos acumulados superiores ao principal da compra';end if;
 end if;
 if exists(select 1 from cc_lines where card_id=c.id and line_type='refund' and charge_date=d and amount=-v and lower(trim(title))=lower(description) and purchase_id is not distinct from original.id) then raise exception 'Estorno já registrado; confira o histórico';end if;
 i:=cc_invoice(coalesce(c.parent_card_id,c.id),cc_cycle(d,(select closing_day from credit_cards where id=coalesce(c.parent_card_id,c.id))));
 insert into cc_lines(household_id,invoice_id,card_id,purchase_id,responsible_id,title,category,amount,line_type,charge_date,original_description) values(p_household,i,c.id,original.id,coalesce(original.responsible_id,c.owner_id),description,coalesce(original.category,'Estorno no cartão'),-v,'refund',d,description) returning id into lid;
 update cc_invoices set revision=revision+1 where id=i;
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,jsonb_build_object('line_id',lid),now());return jsonb_build_object('line_id',lid);
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';


-- 023_purchase_corrections.sql
-- Purchase corrections preserve line IDs, imports, payments, refunds and audit.
-- No existing financial data is changed merely by applying this migration.
alter table public.cc_purchases add column revision bigint not null default 0;
alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v22;
revoke all on function public.cc_action_v22(uuid,uuid,text,jsonb) from public,anon,authenticated;

create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
 prior cc_requests%rowtype; purchase cc_purchases%rowtype; card credit_cards%rowtype; root credit_cards%rowtype;
 ln cc_lines%rowtype; inv cc_invoices%rowtype; ids uuid[]; old_ids uuid[]; new_ids uuid[]:='{}';
 v numeric; part numeric; value numeric; used numeric; old_principal numeric; committed numeric;
 qty int; first_part int; n int; cy date; purchase_date date; v_invoice uuid; existing_id uuid;
 v_title text; v_category text; structural boolean; financial boolean; confirmed boolean;
 result jsonb; today date:=(now() at time zone 'America/Fortaleza')::date;
begin
 if p_action<>'edit_purchase' then return cc_action_v22(p_id,p_household,p_action,p_data);end if;
 if p_id is null or not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 select * into prior from cc_requests where id=p_id;
 if found then
  if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;
  return prior.result;
 end if;
 select * into purchase from cc_purchases where id=(p_data->>'purchase_id')::uuid and household_id=p_household for update;
 if not found or purchase.revision is distinct from (p_data->>'revision')::bigint then raise exception 'Compra atualizada; recarregue e revise';end if;
 select * into card from credit_cards where id=(p_data->>'card_id')::uuid and household_id=p_household;
 if not found then raise exception 'Cartão inválido';end if;
 select * into root from credit_cards where id=coalesce(card.parent_card_id,card.id) for update;
 v:=(p_data->>'amount')::numeric;qty:=(p_data->>'installments')::int;first_part:=(p_data->>'next_installment')::int;
 cy:=(p_data->>'first_cycle')::date;purchase_date:=(p_data->>'date')::date;
 v_title:=trim(p_data->>'title');v_category:=trim(p_data->>'category');confirmed:=coalesce((p_data->>'confirm_reconciled')::boolean,false);
 if v is null or v='NaN'::numeric or v<=0 or v>9000000000000 or v<>round(v,2)
  or qty is null or qty not between 1 and 120 or first_part is null or first_part not between 1 and qty or v*100<qty
  or purchase_date is null or purchase_date>today or cy is null or cy<>date_trunc('month',cy)::date
  or coalesce(length(v_title),0) not between 1 and 200 or coalesce(length(v_category),0) not between 1 and 100 then raise exception 'Compra inválida';end if;
 select array_agg(distinct l.invoice_id) into old_ids from cc_lines l where l.purchase_id=purchase.id;
 -- Dates explicitly refer to the first remaining installment, not an invented past history.
 select * into inv from cc_invoices where id=(select l.invoice_id from cc_lines l where l.purchase_id=purchase.id and l.line_type='principal' and l.installment is not null order by l.installment limit 1);
 structural:=purchase.card_id<>card.id or purchase.installments<>qty or purchase.next_installment<>first_part or inv.cycle is distinct from cy;
 financial:=structural or purchase.amount<>v or purchase.charge_date<>purchase_date;
 if financial and cy<cc_cycle(purchase_date,root.closing_day) then raise exception 'Fatura anterior ao ciclo da compra';end if;
 if financial and (card.card_status<>'active' or root.card_status<>'active') then raise exception 'Cartão indisponível';end if;
 if financial and exists(select 1 from cc_lines l where l.purchase_id=purchase.id and (l.paid<>0 or exists(select 1 from cc_allocations a where a.line_id=l.id))) then
  raise exception 'Compra com histórico de pagamento: alteração financeira bloqueada; descrição e categoria podem ser corrigidas';
 end if;
 -- Refund/discount links remain in their historical invoices; cross-card moves would detach the credit.
 if purchase.card_id<>card.id and exists(select 1 from cc_lines where purchase_id=purchase.id and line_type in ('refund','discount')) then
  raise exception 'Compra com estorno ou desconto deve preservar o cartão vinculado';
 end if;
 if financial then
 for n in 0..(qty-first_part) loop
  v_invoice:=cc_invoice(root.id,(cy+make_interval(months=>n))::date);
  new_ids:=array_append(new_ids,v_invoice);
 end loop;
 else new_ids:=coalesce(old_ids,'{}');end if;
 select array_agg(distinct x) into ids from unnest(coalesce(old_ids,'{}')||new_ids) x;
 perform id from cc_invoices where id=any(ids) order by id for update;
 for inv in select * from cc_invoices where id=any(ids) loop
  -- Newly created invoices have no prior revision. Existing ones require the caller's snapshot.
  if inv.revision<>0 or inv.id=any(coalesce(old_ids,'{}')) then
   if (p_data->'invoice_revisions'->>inv.id::text)::bigint is distinct from inv.revision then raise exception 'Fatura atualizada; recarregue e revise';end if;
  end if;
  if financial and exists(select 1 from cc_payments where invoice_id=inv.id) then raise exception 'Fatura com histórico de pagamento: alteração financeira bloqueada';end if;
  if (inv.closing_date<=today or exists(select 1 from cc_payments where invoice_id=inv.id) or exists(select 1 from cc_invoice_targets where invoice_id=inv.id) or exists(select 1 from cc_imports where invoice_id=inv.id)) and not confirmed then
   raise exception 'Confirme a alteração de faturas fechadas ou conciliadas';
  end if;
 end loop;
 part:=trunc(v/qty,2);committed:=v-part*(first_part-1);
 if committed+coalesce((select sum(amount) from cc_lines where purchase_id=purchase.id and line_type in ('refund','discount')),0)<0 then raise exception 'Total inferior aos estornos e descontos existentes';end if;
 if financial then
  select coalesce(sum(l.amount-l.paid) filter(where l.line_type<>'fee'),0) into used from cc_lines l join credit_cards c on c.id=l.card_id where coalesce(c.parent_card_id,c.id)=root.id;
  select coalesce(sum(l.amount-l.paid),0) into old_principal from cc_lines l join credit_cards c on c.id=l.card_id where l.purchase_id=purchase.id and l.line_type='principal' and coalesce(c.parent_card_id,c.id)=root.id;
  used:=used+coalesce((select sum(e.amount-e.paid_amount) from financial_events e join credit_cards c on c.id=e.card_id where coalesce(c.parent_card_id,c.id)=root.id and e.status='pending'),0);
  if greatest(0,used-old_principal+committed)>root.credit_limit then raise exception 'Limite disponível insuficiente';end if;
 end if;
 if financial then
  -- Keep the same physical IDs in sequence; retired principal rows become audited zero rows.
  -- Imports and allocation foreign keys never dangle, and no historical row is deleted.
  select array_agg(l.id order by l.installment,l.id) into old_ids from cc_lines l where l.purchase_id=purchase.id and l.line_type='principal' and l.installment is not null;
  update cc_lines set installment=null where purchase_id=purchase.id and line_type='principal';
  for n in 0..(qty-first_part) loop
   value:=case when first_part+n=qty then v-part*(qty-1) else part end;
   existing_id:=old_ids[n+1];
   if existing_id is null then
    insert into cc_lines(household_id,invoice_id,card_id,purchase_id,responsible_id,title,category,amount,line_type,installment,charge_date)
     values(p_household,new_ids[n+1],card.id,purchase.id,purchase.responsible_id,v_title,v_category,value,'principal',first_part+n,purchase_date);
   else
    update cc_lines set invoice_id=new_ids[n+1],card_id=card.id,title=v_title,category=v_category,amount=value,installment=first_part+n,charge_date=purchase_date where id=existing_id;
   end if;
  end loop;
  update cc_lines set amount=0 where purchase_id=purchase.id and line_type='principal' and installment is null;
 else
  update cc_lines set title=v_title,category=v_category where purchase_id=purchase.id and line_type='principal';
 end if;
 update cc_purchases set card_id=card.id,title=v_title,category=v_category,amount=v,charge_date=purchase_date,installments=qty,next_installment=first_part,revision=revision+1 where id=purchase.id;
 update cc_invoices set revision=revision+1 where id=any(ids);
 -- Explicit confirmation invalidates the previous reconciliation total, retaining the new actual total.
 update cc_invoice_targets t set target=(select coalesce(sum(l.amount),0) from cc_lines l where l.invoice_id=t.invoice_id),updated_at=now() where t.invoice_id=any(ids);
 result:=jsonb_build_object('purchase_id',purchase.id);
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());
 return result;
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
-- Audit reconciliation changes made by an explicitly confirmed correction.
create trigger cc_target_audit after insert or update on public.cc_invoice_targets for each row execute function public.cc_audit_row();
notify pgrst,'reload schema';

-- 024_import_lifecycle.sql
-- Reliable ownership for NEW imports only. Never infer ownership of legacy rows.
alter table public.cc_imports
 add column status text not null default 'active' check(status in ('active','undone')),
 add column provenance_version integer not null default 0,
 add column effects jsonb not null default '{}',
 add column undone_at timestamptz, add column undone_by uuid references auth.users;
alter table public.cc_imports drop constraint cc_imports_card_id_file_hash_key;
create unique index cc_active_import_file on public.cc_imports(card_id,file_hash) where status='active';
create table public.cc_import_items(
 import_id uuid not null references public.cc_imports,
 household_id uuid not null references public.households,
 table_name text not null check(table_name in ('cc_purchases','cc_lines')),
 entity_id uuid not null, created boolean not null, snapshot jsonb not null,
 primary key(import_id,table_name,entity_id)
);
create unique index cc_import_owner on public.cc_import_items(table_name,entity_id) where created;
alter table public.cc_import_items enable row level security;
create policy cc_import_items_read on public.cc_import_items for select to authenticated using(is_household_member(household_id));
revoke all on public.cc_import_items from public,anon,authenticated;
grant select on public.cc_import_items to authenticated;
create trigger cc_import_item_audit after insert or update on public.cc_import_items for each row execute function public.cc_audit_row();
create function public.cc_audit_deleted() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into cc_audit(household_id,actor_id,table_name,before_data,after_data) values(old.household_id,auth.uid(),tg_table_name,to_jsonb(old),null);
 return old;
end $$;
revoke all on function public.cc_audit_deleted() from public,anon,authenticated;
create trigger cc_import_delete_audit after delete on public.cc_lines for each row execute function public.cc_audit_deleted();
create trigger cc_import_delete_audit after delete on public.cc_purchases for each row execute function public.cc_audit_deleted();

-- Both the preview and the mutating operation use exactly these guards.
create function public.cc_import_impact(p_import uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare imp cc_imports%rowtype; item cc_import_items%rowtype; actual jsonb;
 reasons text[]:='{}'; invoices uuid[]; target jsonb; state record; adjustments jsonb; has_created boolean;
begin
 select * into imp from cc_imports where id=p_import;
 if not found or not is_household_member(imp.household_id) then raise exception 'Sem permissão';end if;
 if imp.status<>'active' then reasons:=array_append(reasons,'Importação já desfeita');end if;
 if imp.provenance_version<>1 then reasons:=array_append(reasons,'Importação antiga sem identificação confiável: revisão individual obrigatória; nenhuma exclusão por aproximação');end if;
 has_created:=exists(select 1 from cc_import_items where import_id=imp.id and created);
 select coalesce(array_agg(value::uuid),'{}') into invoices from jsonb_array_elements_text(coalesce(imp.effects->'invoice_ids','[]'));
 for item in select * from cc_import_items where import_id=imp.id and created loop
  if item.table_name='cc_lines' then select to_jsonb(l) into actual from cc_lines l where id=item.entity_id;
  else select to_jsonb(p) into actual from cc_purchases p where id=item.entity_id;end if;
  if actual is distinct from item.snapshot then reasons:=array_append(reasons,'Lançamento ou compra alterado após importar: '||item.entity_id);end if;
 end loop;
 if has_created and exists(select 1 from cc_payments where invoice_id=any(invoices)) then reasons:=array_append(reasons,'Fatura com histórico de pagamento, inclusive pagamentos posteriormente desfeitos');end if;
 if exists(select 1 from cc_allocations a join cc_import_items m on m.table_name='cc_lines' and m.entity_id=a.line_id and m.created where m.import_id=imp.id) then reasons:=array_append(reasons,'Parcelas com alocações de pagamento');end if;
 if exists(select 1 from cc_import_items owner join cc_import_items other on other.table_name=owner.table_name and other.entity_id=owner.entity_id and other.import_id<>owner.import_id join cc_imports later on later.id=other.import_id and later.status='active' where owner.import_id=imp.id and owner.created) then reasons:=array_append(reasons,'Lançamentos vinculados por outra importação ativa; revise/desfaça primeiro a importação dependente');end if;
 -- Legacy import links are also evidence of a dependency, never evidence of ownership.
 if exists(select 1 from cc_imports other cross join lateral jsonb_array_elements(case when jsonb_typeof(other.summary->'rows')='array' then other.summary->'rows' else '[]' end) r join cc_import_items owned on owned.import_id=imp.id and owned.created and owned.table_name='cc_lines' and owned.entity_id::text=r->>'line_id' where other.id<>imp.id and other.status='active') then reasons:=array_append(reasons,'Outra importação referencia os lançamentos deste arquivo');end if;
 if exists(select 1 from cc_lines l join cc_import_items p on p.entity_id=l.purchase_id and p.table_name='cc_purchases' and p.created and p.import_id=imp.id where not exists(select 1 from cc_import_items m where m.import_id=imp.id and m.created and m.table_name='cc_lines' and m.entity_id=l.id)) then reasons:=array_append(reasons,'Compra possui parcelas, estornos ou descontos posteriores não criados por esta importação');end if;
 if exists(select 1 from cc_adjustment_reversals r join cc_import_items m on m.import_id=imp.id and m.created and m.table_name='cc_lines' and (m.entity_id=r.line_id or m.entity_id=r.reversal_line_id)) then reasons:=array_append(reasons,'Ajuste possui reversão vinculada');end if;
 if has_created then
 select coalesce(jsonb_agg(id order by id),'[]'::jsonb) into adjustments from cc_lines where invoice_id=any(invoices) and line_type='adjustment';
 if adjustments is distinct from imp.effects->'adjustments_after' then reasons:=array_append(reasons,'Faturas com ajustes ou conciliações posteriores à importação');end if;
 for state in select key,value from jsonb_each(coalesce(imp.effects->'targets_after','{}')) loop
  select to_jsonb(t) into target from cc_invoice_targets t where invoice_id=state.key::uuid;
  if coalesce(target,'null'::jsonb) is distinct from state.value then reasons:=array_append(reasons,'Conciliação alterada após importar na fatura '||state.key);end if;
 end loop;
 end if;
 return jsonb_build_object('import_id',imp.id,'safe',cardinality(reasons)=0,'reasons',to_jsonb(reasons),
  'created_lines',(select count(*) from cc_import_items where import_id=imp.id and table_name='cc_lines' and created),
  'created_purchases',(select count(*) from cc_import_items where import_id=imp.id and table_name='cc_purchases' and created),
  'linked_lines',(select count(*) from cc_import_items where import_id=imp.id and table_name='cc_lines' and not created),
  'invoice_ids',to_jsonb(invoices),'bank_delta',0);
end $$;
revoke all on function public.cc_import_impact(uuid) from public,anon,authenticated;

alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v23;
revoke all on function public.cc_action_v23(uuid,uuid,text,jsonb) from public,anon,authenticated;
create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare prior cc_requests%rowtype; imp cc_imports%rowtype; inv cc_invoices%rowtype; card credit_cards%rowtype; line cc_lines%rowtype;
 row jsonb; records jsonb:='[]'; result jsonb; impact jsonb; before_target jsonb; after_targets jsonb:='{}'; target jsonb;
 line_ids uuid[]:='{}'; purchase_ids uuid[]:='{}'; linked_ids uuid[]:='{}'; invoice_ids uuid[]; pid uuid; lid uuid; iid uuid;
 created_count int:=0; linked_count int:=0; skipped_count int:=0; v_amount numeric; imported_total numeric:=0;
 suspicious boolean; editing cc_purchases%rowtype; source_cycle date;
begin
 if p_action not in ('import_statement','preview_undo_import','undo_import','edit_purchase') then return cc_action_v23(p_id,p_household,p_action,p_data);end if;
 if p_id is null or p_data is null or not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 select * into prior from cc_requests where id=p_id;
 if found then
  if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;return prior.result;
 end if;
 if p_action='edit_purchase' then
  select * into editing from cc_purchases where id=(p_data->>'purchase_id')::uuid and household_id=p_household;
  if not found then raise exception 'Compra indisponível';end if;
  select i.cycle into source_cycle from cc_lines l join cc_invoices i on i.id=l.invoice_id where l.purchase_id=editing.id and l.line_type='principal' and l.installment is not null order by l.installment limit 1;
  if source_cycle is distinct from (p_data->>'first_cycle')::date and not coalesce((p_data->>'confirm_reconciled')::boolean,false) then raise exception 'Confirme mover as parcelas de % para % e atualizar as faturas de origem e destino',to_char(source_cycle,'MM/YYYY'),to_char((p_data->>'first_cycle')::date,'MM/YYYY');end if;
  if exists(select 1 from cc_purchases p where p.household_id=p_household and p.id<>editing.id and p.card_id=(p_data->>'card_id')::uuid and lower(trim(p.title))=lower(trim(p_data->>'title')) and p.charge_date=(p_data->>'date')::date and p.amount=(p_data->>'amount')::numeric) and not coalesce((p_data->>'confirm_duplicates')::boolean,false) then raise exception 'Possível duplicidade: confirme a edição após revisar as compras semelhantes';end if;
  return cc_action_v23(p_id,p_household,p_action,p_data);
 end if;
 if p_action in ('preview_undo_import','undo_import') then
  select * into imp from cc_imports where id=(p_data->>'import_id')::uuid and household_id=p_household for update;
  if not found then raise exception 'Importação indisponível';end if;
  impact:=cc_import_impact(imp.id);
  if p_action='preview_undo_import' then return impact;end if;
  if not coalesce((impact->>'safe')::boolean,false) then raise exception '%',(select string_agg(value,'; ') from jsonb_array_elements_text(impact->'reasons'));end if;
  if p_data->>'confirmed' is distinct from 'true' then raise exception 'Confirme o desfazimento integral da importação';end if;
  select array_agg(value::uuid) into invoice_ids from jsonb_array_elements_text(imp.effects->'invoice_ids');
  perform id from cc_invoices where id=any(invoice_ids) order by id for update;
  -- Delete only UUIDs captured at creation; linked/preexisting/manual rows are never selected.
  delete from cc_lines l using cc_import_items m where m.import_id=imp.id and m.created and m.table_name='cc_lines' and m.entity_id=l.id;
  delete from cc_purchases p using cc_import_items m where m.import_id=imp.id and m.created and m.table_name='cc_purchases' and m.entity_id=p.id;
  -- Targets were not overwritten by import; removing its adjustment lines restores the prior sum.
  update cc_invoices set revision=revision+1 where id=any(invoice_ids);
  update cc_imports set status='undone',undone_at=now(),undone_by=auth.uid() where id=imp.id;
  result:=impact||jsonb_build_object('status','undone');
  insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());return result;
 end if;
 -- Import: every validation, generated installment and ownership snapshot is one transaction.
 select * into inv from cc_invoices where id=(p_data->>'invoice_id')::uuid and household_id=p_household for update;
 if not found or inv.revision is distinct from (p_data->>'revision')::bigint then raise exception 'Fatura atualizada; revise novamente';end if;
 select * into card from credit_cards where id=coalesce((p_data->>'card_id')::uuid,inv.card_id) and household_id=p_household and coalesce(parent_card_id,id)=inv.card_id;
 if not found then raise exception 'Cartão da importação inválido';end if;
 if p_data->>'confirmed' is distinct from 'true' or jsonb_typeof(p_data->'rows') is distinct from 'array' then raise exception 'Confirme a conferência dos lançamentos';end if;
 if jsonb_array_length(p_data->'rows') not between 1 and 1000 then raise exception 'Quantidade de lançamentos inválida';end if;
 if exists(select 1 from cc_imports where card_id=card.id and file_hash=p_data->>'file_hash' and status='active') then raise exception 'Arquivo já importado: consulte o histórico';end if;
 select to_jsonb(t) into before_target from cc_invoice_targets t where invoice_id=inv.id;
 insert into cc_imports(id,household_id,card_id,invoice_id,file_hash,file_name,actor_id,summary,provenance_version)
 values(p_id,p_household,card.id,inv.id,p_data->>'file_hash',left(p_data->>'file_name',200),auth.uid(),'{}',1);
 if coalesce((p_data->>'keep_target')::boolean,false) then
  if before_target is null then raise exception 'Não há total conciliado anterior';end if;
  lid:=cc_reconcile(inv.id,(before_target->>'target')::numeric-coalesce((select sum((r->>'amount')::numeric) from jsonb_array_elements(p_data->'rows') r where r->>'decision'='new'),0));
  if lid is not null then line_ids:=array_append(line_ids,lid);end if;
 end if;
 for row in select value from jsonb_array_elements(p_data->'rows') loop
  lid:=null;pid:=null;
  if row->>'decision'='skip' then skipped_count:=skipped_count+1;
  elsif row->>'decision'='link' then
   select * into line from cc_lines where id=(row->>'match_id')::uuid and household_id=p_household and card_id=card.id;
   if not found then raise exception 'Correspondência inválida';end if;
   lid:=line.id;linked_ids:=array_append(linked_ids,lid);linked_count:=linked_count+1;
  elsif row->>'decision'='new' then
   v_amount:=(row->>'amount')::numeric;
   if v_amount is null or v_amount='NaN'::numeric or v_amount=0 or abs(v_amount)>9000000000000 or v_amount<>round(v_amount,2) or length(trim(coalesce(row->>'description',''))) not between 1 and 200 or length(trim(coalesce(row->>'category',''))) not between 1 and 100 or (row->>'date')::date is null or (row->>'date')::date>(now() at time zone 'America/Fortaleza')::date then raise exception 'Linha incompleta ou inválida';end if;
   if nullif(row->>'bank_id','') is not null and exists(select 1 from cc_lines where card_id=card.id and bank_transaction_id=row->>'bank_id') then raise exception 'Identificador bancário já cadastrado: vincule ao lançamento existente';end if;
   suspicious:=exists(select 1 from cc_lines l where l.card_id=card.id and lower(trim(l.title))=lower(trim(row->>'description')) and l.charge_date=(row->>'date')::date and l.amount=(row->>'amount')::numeric and not(l.line_type='principal' and l.installment is null and l.amount=0));
   if suspicious and not coalesce((p_data->>'confirm_duplicates')::boolean,false) then raise exception 'Possível duplicidade: confirme os lançamentos semelhantes antes de importar';end if;
   if row->>'kind'='purchase' and v_amount>0 then
    if (row->>'total_amount')::numeric is null then raise exception 'Confirme o valor total original do parcelamento';end if;
    if inv.cycle<cc_cycle((row->>'date')::date,(select closing_day from credit_cards where id=inv.card_id)) then raise exception 'Fatura anterior ao ciclo da compra; revise a data e o período';end if;
    pid:=cc_post_purchase(card.id,card.owner_id,row->>'description',row->>'category',(row->>'total_amount')::numeric,(row->>'date')::date,(row->>'count')::int,(row->>'installment')::int,inv.cycle,null);
    select id into lid from cc_lines where purchase_id=pid and installment=(row->>'installment')::int;
    if (select l.amount from cc_lines l where id=lid)<>v_amount then raise exception 'Parcela não corresponde ao total confirmado';end if;
    purchase_ids:=array_append(purchase_ids,pid);
    line_ids:=line_ids||array(select id from cc_lines where purchase_id=pid);
   elsif row->>'kind' in ('refund','fee','credit') then
    if (row->>'kind'='fee' and v_amount<0) or (row->>'kind' in ('refund','credit') and v_amount>0) then raise exception 'Sinal incompatível com o tipo';end if;
    if row->>'kind' in ('refund','credit') and suspicious then raise exception 'Estorno já existente: vincule ao registro';end if;
    insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,inv.id,card.id,card.owner_id,row->>'description',row->>'category',v_amount,case when row->>'kind'='fee' then 'fee' else 'refund' end,(row->>'date')::date) returning id into lid;
    line_ids:=array_append(line_ids,lid);
   else raise exception 'Tipo inválido: pagamento anterior não é compra';end if;
   update cc_lines set original_description=row->>'original',bank_transaction_id=nullif(row->>'bank_id','') where id=lid;
   imported_total:=imported_total+v_amount;created_count:=created_count+1;
  else raise exception 'Decida explicitamente cada linha';end if;
  records:=records||jsonb_build_array(row||jsonb_build_object('line_id',lid,'purchase_id',pid));
 end loop;
 if coalesce((p_data->>'keep_target')::boolean,false) then
  lid:=cc_reconcile(inv.id,(before_target->>'target')::numeric);
  if lid is not null then line_ids:=array_append(line_ids,lid);end if;
 end if;
 select array_agg(distinct x) into invoice_ids from (select invoice_id x from cc_lines where id=any(line_ids) union select inv.id) affected;
 update cc_invoices set revision=revision+1 where id=any(invoice_ids);
 insert into cc_import_items select p_id,p_household,'cc_lines',l.id,true,to_jsonb(l) from cc_lines l where l.id=any(line_ids);
 insert into cc_import_items select p_id,p_household,'cc_purchases',p.id,true,to_jsonb(p) from cc_purchases p where p.id=any(purchase_ids);
 insert into cc_import_items select p_id,p_household,'cc_lines',l.id,false,to_jsonb(l) from cc_lines l where l.id=any(linked_ids) and not(l.id=any(line_ids));
 foreach iid in array invoice_ids loop
  select to_jsonb(t) into target from cc_invoice_targets t where invoice_id=iid;
  after_targets:=after_targets||jsonb_build_object(iid::text,target);
 end loop;
 update cc_imports set summary=jsonb_build_object('identified',jsonb_array_length(p_data->'rows'),'imported',created_count,'linked',linked_count,'discarded',skipped_count,'total',imported_total,'rows',records,'metadata',p_data->'metadata'),effects=jsonb_build_object('invoice_ids',to_jsonb(invoice_ids),'target_before',before_target,'targets_after',after_targets,'adjustments_after',(select coalesce(jsonb_agg(id order by id),'[]'::jsonb) from cc_lines where invoice_id=any(invoice_ids) and line_type='adjustment')) where id=p_id;
 result:=jsonb_build_object('import_id',p_id,'imported',created_count,'linked',linked_count,'discarded',skipped_count);
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());return result;
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';


-- 025_import_reference_cycle.sql

-- 025 · Importação com mês de referência explícito, total do PDF e ajuste desfazível.
-- ADITIVA: só acrescenta colunas e funções. Não altera nem apaga registros existentes.
-- Pré-requisito: 023 e 024 aplicadas (nesta ordem).
-- Pedidos antigos (sem o campo "cycle") continuam no caminho anterior (cc_action_v24).

alter table public.cc_imports
  add column if not exists reference_cycle date,
  add column if not exists bank text,
  add column if not exists statement_due date,
  add column if not exists statement_closing date,
  add column if not exists statement_total numeric(16,2),
  add column if not exists adjustment_line uuid;

-- Igual a cc_post_purchase, mas sem bloquear por limite: a fatura importada registra compras
-- que já aconteceram, e o limite cadastrado no app pode estar desatualizado.
-- Cartão arquivado continua bloqueado.
create function public.cc_post_imported_purchase(p_card uuid,p_responsible uuid,p_title text,p_category text,p_amount numeric,p_date date,p_count integer,p_next integer,p_first_cycle date)
returns uuid language plpgsql security definer set search_path=public as $$
declare c credit_cards%rowtype;r credit_cards%rowtype;pid uuid;cy date;iv uuid;part numeric;i integer;
begin
 select * into c from credit_cards where id=p_card;
 if not found or not is_household_member(c.household_id) or c.card_status='archived' then raise exception 'Cartão indisponível';end if;
 select * into r from credit_cards where id=coalesce(c.parent_card_id,c.id) for update;
 if r.card_status='archived' then raise exception 'Cartão principal indisponível';end if;
 if not exists(select 1 from household_members where household_id=c.household_id and user_id=p_responsible) then raise exception 'Responsável inválido';end if;
 if p_amount is null or p_amount='NaN'::numeric or p_amount<=0 or p_amount>9000000000000 or p_amount<>round(p_amount,2) or p_count is null or p_count not between 1 and 120 or p_next is null or p_next not between 1 and p_count or p_amount*100<p_count or p_date is null or p_date>(now() at time zone 'America/Fortaleza')::date or p_title is null or length(trim(p_title)) not between 1 and 200 or p_category is null or length(trim(p_category)) not between 1 and 100 or p_first_cycle is null then raise exception 'Compra inválida';end if;
 cy:=date_trunc('month',p_first_cycle)::date;
 part:=trunc(p_amount/p_count,2);
 insert into cc_purchases(household_id,card_id,responsible_id,title,category,amount,charge_date,installments,next_installment)
 values(c.household_id,c.id,p_responsible,trim(p_title),p_category,p_amount,p_date,p_count,p_next) returning id into pid;
 for i in p_next..p_count loop
  iv:=cc_invoice(r.id,(cy+make_interval(months=>i-p_next))::date);
  insert into cc_lines(household_id,invoice_id,card_id,purchase_id,responsible_id,title,category,amount,line_type,installment,charge_date)
  values(c.household_id,iv,c.id,pid,p_responsible,trim(p_title),p_category,case when i=p_count then p_amount-part*(p_count-1) else part end,'principal',i,p_date);
  update cc_invoices set revision=revision+1 where id=iv;
 end loop;
 return pid;
end $$;
revoke all on function public.cc_post_imported_purchase(uuid,uuid,text,text,numeric,date,integer,integer,date) from public,anon,authenticated;

alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v24;
revoke all on function public.cc_action_v24(uuid,uuid,text,jsonb) from public,anon,authenticated;

create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare prior cc_requests%rowtype; inv cc_invoices%rowtype; card credit_cards%rowtype; root credit_cards%rowtype; line cc_lines%rowtype;
 row jsonb; records jsonb:='[]'; result jsonb; target jsonb; after_targets jsonb:='{}';
 line_ids uuid[]:='{}'; purchase_ids uuid[]:='{}'; linked_ids uuid[]:='{}'; invoice_ids uuid[]; pid uuid; lid uuid; iid uuid; adj uuid;
 created_count int:=0; linked_count int:=0; skipped_count int:=0; v_amount numeric; imported_total numeric:=0;
 suspicious boolean; v_cycle date; v_due date; v_closing date; v_total numeric; v_limit date;
begin
 if p_action<>'import_statement' or p_data is null or nullif(p_data->>'cycle','') is null then
  return cc_action_v24(p_id,p_household,p_action,p_data);
 end if;
 if p_id is null or not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 select * into prior from cc_requests where id=p_id;
 if found then
  if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;
  return prior.result;
 end if;

 select * into card from credit_cards where id=(p_data->>'card_id')::uuid and household_id=p_household;
 if not found then raise exception 'Cartão da importação inválido';end if;
 select * into root from credit_cards where id=coalesce(card.parent_card_id,card.id);
 v_cycle:=date_trunc('month',(p_data->>'cycle')::date)::date;
 if v_cycle is null or v_cycle<date '2000-01-01' or v_cycle>(now() at time zone 'America/Fortaleza')::date+interval '1 year' then raise exception 'Mês de referência inválido';end if;
 v_due:=nullif(p_data->'statement'->>'due','')::date;
 v_closing:=nullif(p_data->'statement'->>'closing','')::date;
 v_total:=nullif(p_data->'statement'->>'total','')::numeric;
 if v_total is not null and (v_total='NaN'::numeric or abs(v_total)>9000000000000 or v_total<>round(v_total,2)) then raise exception 'Total do PDF inválido';end if;

 -- A fatura do mês escolhido: a mesma que a pessoa viu na revisão (revisão conferida) ou criada agora.
 if nullif(p_data->>'invoice_id','') is not null then
  select * into inv from cc_invoices where id=(p_data->>'invoice_id')::uuid and household_id=p_household and card_id=root.id for update;
  if not found or inv.cycle<>v_cycle then raise exception 'Fatura de referência não corresponde ao mês escolhido';end if;
  if inv.revision is distinct from (p_data->>'revision')::bigint then raise exception 'Fatura atualizada; revise novamente';end if;
 else
  iid:=cc_invoice(root.id,v_cycle);
  select * into inv from cc_invoices where id=iid for update;
 end if;

 if p_data->>'confirmed' is distinct from 'true' or jsonb_typeof(p_data->'rows') is distinct from 'array' then raise exception 'Confirme a conferência dos lançamentos';end if;
 if jsonb_array_length(p_data->'rows') not between 1 and 1000 then raise exception 'Quantidade de lançamentos inválida';end if;
 if exists(select 1 from cc_imports where card_id=card.id and file_hash=p_data->>'file_hash' and status='active') then raise exception 'Arquivo já importado: consulte o histórico';end if;

 insert into cc_imports(id,household_id,card_id,invoice_id,file_hash,file_name,actor_id,summary,provenance_version,reference_cycle,bank,statement_due,statement_closing,statement_total)
 values(p_id,p_household,card.id,inv.id,p_data->>'file_hash',left(p_data->>'file_name',200),auth.uid(),'{}',1,v_cycle,left(p_data->'statement'->>'bank',40),v_due,v_closing,v_total);

 -- Compras posteriores ao fechamento não pertencem a esta fatura. Vale o fechamento do PDF, quando houver.
 v_limit:=greatest(inv.closing_date,coalesce(v_closing,inv.closing_date));

 for row in select value from jsonb_array_elements(p_data->'rows') loop
  lid:=null;pid:=null;
  if row->>'decision'='skip' then skipped_count:=skipped_count+1;
  elsif row->>'decision'='link' then
   select * into line from cc_lines where id=(row->>'match_id')::uuid and household_id=p_household and card_id=card.id;
   if not found then raise exception 'Correspondência inválida';end if;
   lid:=line.id;linked_ids:=array_append(linked_ids,lid);linked_count:=linked_count+1;
  elsif row->>'decision'='new' then
   v_amount:=(row->>'amount')::numeric;
   if v_amount is null or v_amount='NaN'::numeric or v_amount=0 or abs(v_amount)>9000000000000 or v_amount<>round(v_amount,2) or length(trim(coalesce(row->>'description',''))) not between 1 and 200 or length(trim(coalesce(row->>'category',''))) not between 1 and 100 or (row->>'date')::date is null or (row->>'date')::date>(now() at time zone 'America/Fortaleza')::date then raise exception 'Linha incompleta ou inválida: %',left(row->>'description',60);end if;
   if nullif(row->>'bank_id','') is not null and exists(select 1 from cc_lines where card_id=card.id and bank_transaction_id=row->>'bank_id') then raise exception 'Identificador bancário já cadastrado: vincule ao lançamento existente';end if;
   suspicious:=exists(select 1 from cc_lines l where l.card_id=card.id and lower(trim(l.title))=lower(trim(row->>'description')) and l.charge_date=(row->>'date')::date and l.amount=v_amount and not(l.line_type='principal' and l.installment is null and l.amount=0));
   if suspicious and not coalesce((p_data->>'confirm_duplicates')::boolean,false) then raise exception 'Possível duplicidade: confirme os lançamentos semelhantes antes de importar';end if;
   if row->>'kind'='purchase' and v_amount>0 then
    if (row->>'total_amount')::numeric is null then raise exception 'Confirme o valor total original do parcelamento';end if;
    if coalesce((row->>'installment')::int,1)=1 and (row->>'date')::date>v_limit then raise exception 'Compra de % é posterior ao fechamento (%) da fatura escolhida',to_char((row->>'date')::date,'DD/MM/YYYY'),to_char(v_limit,'DD/MM/YYYY');end if;
    pid:=cc_post_imported_purchase(card.id,card.owner_id,row->>'description',row->>'category',(row->>'total_amount')::numeric,(row->>'date')::date,(row->>'count')::int,(row->>'installment')::int,inv.cycle);
    select id into lid from cc_lines where purchase_id=pid and installment=(row->>'installment')::int;
    if (select l.amount from cc_lines l where id=lid)<>v_amount then raise exception 'Parcela não corresponde ao total confirmado: %',left(row->>'description',60);end if;
    purchase_ids:=array_append(purchase_ids,pid);
    line_ids:=line_ids||array(select id from cc_lines where purchase_id=pid);
   elsif row->>'kind' in ('refund','fee','credit') or (row->>'kind'='purchase' and v_amount<0) then
    if (row->>'kind'='fee' and v_amount<0) or (row->>'kind' in ('refund','credit') and v_amount>0) then raise exception 'Sinal incompatível com o tipo';end if;
    insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date)
    values(p_household,inv.id,card.id,card.owner_id,row->>'description',row->>'category',v_amount,case when row->>'kind'='fee' then 'fee' else 'refund' end,(row->>'date')::date) returning id into lid;
    line_ids:=array_append(line_ids,lid);
   else raise exception 'Tipo inválido: pagamento anterior não é compra';end if;
   update cc_lines set original_description=row->>'original',bank_transaction_id=nullif(row->>'bank_id','') where id=lid;
   imported_total:=imported_total+v_amount;created_count:=created_count+1;
  else raise exception 'Decida explicitamente cada linha';end if;
  records:=records||jsonb_build_array(row||jsonb_build_object('line_id',lid,'purchase_id',pid));
 end loop;

 -- Ajuste opcional para o total impresso no PDF. Fica registrado como criado por esta
 -- importação e é removido junto ao desfazer.
 if coalesce((p_data->>'adjust_to_statement')::boolean,false) then
  if v_total is null then raise exception 'O PDF não informou o total da fatura';end if;
  adj:=cc_reconcile(inv.id,v_total);
  if adj is not null then line_ids:=array_append(line_ids,adj);end if;
 end if;

 select array_agg(distinct x) into invoice_ids from (select invoice_id x from cc_lines where id=any(line_ids) union select inv.id) affected;
 update cc_invoices set revision=revision+1 where id=any(invoice_ids);
 insert into cc_import_items select p_id,p_household,'cc_lines',l.id,true,to_jsonb(l) from cc_lines l where l.id=any(line_ids);
 insert into cc_import_items select p_id,p_household,'cc_purchases',p.id,true,to_jsonb(p) from cc_purchases p where p.id=any(purchase_ids);
 insert into cc_import_items select p_id,p_household,'cc_lines',l.id,false,to_jsonb(l) from cc_lines l where l.id=any(linked_ids) and not(l.id=any(line_ids));
 foreach iid in array invoice_ids loop
  select to_jsonb(t) into target from cc_invoice_targets t where invoice_id=iid;
  after_targets:=after_targets||jsonb_build_object(iid::text,target);
 end loop;
 update cc_imports set adjustment_line=adj,
  summary=jsonb_build_object('identified',jsonb_array_length(p_data->'rows'),'imported',created_count,'linked',linked_count,'discarded',skipped_count,'total',imported_total,'rows',records,'metadata',p_data->'metadata','statement_total',v_total,'adjustment',(select amount from cc_lines where id=adj)),
  effects=jsonb_build_object('invoice_ids',to_jsonb(invoice_ids),'target_before',null,'targets_after',after_targets,'adjustments_after',(select coalesce(jsonb_agg(id order by id),'[]'::jsonb) from cc_lines where invoice_id=any(invoice_ids) and line_type='adjustment'))
 where id=p_id;
 result:=jsonb_build_object('import_id',p_id,'invoice_id',inv.id,'cycle',inv.cycle,'imported',created_count,'linked',linked_count,'discarded',skipped_count,'adjustment',(select amount from cc_lines where id=adj));
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());
 return result;
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';


-- 026_import_undo_repair.sql

-- 026 · Desfazer importação de verdade.
-- ADITIVA: só funções (substitui a regra de impacto e acrescenta ações). Não altera nem apaga dados ao ser aplicada.
-- Pré-requisito: 023, 024 e 025.
-- O que muda:
--  * Desfazer localiza tudo pelo ID da importação (cc_import_items), nunca pela descrição.
--  * Renomear descrição/categoria depois de importar não bloqueia mais; só mudanças de valor, parcela, fatura ou cartão bloqueiam.
--  * Lançamentos apagados à mão são ignorados (não travam o desfazer do que sobrou).
--  * Fatura com pagamento: deixa desfazer com confirmação explícita. O pagamento continua registrado
--    (o dinheiro saiu da conta) e a fatura passa a mostrar crédito.
--  * Importação antiga (antes da 024): "adopt_legacy_import" usa os IDs gravados no resumo da própria importação.
--  * Arquivo já importado: se a importação anterior não tiver mais nenhum lançamento, ela é liberada automaticamente.
--  * "force_clear_import": tira do histórico ativo uma importação sem lançamentos (nada financeiro é apagado).

create or replace function public.cc_import_remaining(p_import uuid) returns integer language sql stable security definer set search_path=public as $$
 select (select count(*) from cc_import_items m where m.import_id=p_import and m.created
          and ((m.table_name='cc_lines' and exists(select 1 from cc_lines l where l.id=m.entity_id))
            or (m.table_name='cc_purchases' and exists(select 1 from cc_purchases p where p.id=m.entity_id))))::int
      + (select count(*) from cc_imports i cross join lateral jsonb_array_elements(case when jsonb_typeof(i.summary->'rows')='array' then i.summary->'rows' else '[]' end) r
          join cc_lines l on l.id=nullif(r->>'line_id','')::uuid
          where i.id=p_import and i.provenance_version<>1 and r->>'decision'='new')::int
$$;
revoke all on function public.cc_import_remaining(uuid) from public,anon,authenticated;

create or replace function public.cc_import_impact(p_import uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare imp cc_imports%rowtype; item cc_import_items%rowtype; actual jsonb; keys text[];
 reasons text[]:='{}'; warnings text[]:='{}'; invoices uuid[]; paid numeric; remaining int; adjustments jsonb;
begin
 select * into imp from cc_imports where id=p_import;
 if not found or not is_household_member(imp.household_id) then raise exception 'Sem permissão';end if;
 remaining:=cc_import_remaining(imp.id);
 if imp.status<>'active' then reasons:=array_append(reasons,'Importação já desfeita');end if;
 if imp.provenance_version<>1 then reasons:=array_append(reasons,'Importação antiga sem identificação dos lançamentos: toque em "Identificar lançamentos" para vinculá-los pelo registro da própria importação');end if;
 select coalesce(array_agg(value::uuid),'{}') into invoices from jsonb_array_elements_text(coalesce(imp.effects->'invoice_ids','[]'));
 for item in select * from cc_import_items where import_id=imp.id and created loop
  if item.table_name='cc_lines' then select to_jsonb(l) into actual from cc_lines l where id=item.entity_id;keys:=array['invoice_id','card_id','purchase_id','amount','line_type','installment'];
  else select to_jsonb(p) into actual from cc_purchases p where id=item.entity_id;keys:=array['card_id','amount','installments','next_installment'];end if;
  continue when actual is null; -- apagado à mão: não há o que desfazer
  if (select jsonb_object_agg(k,actual->k) from unnest(keys) k) is distinct from (select jsonb_object_agg(k,item.snapshot->k) from unnest(keys) k) then
   reasons:=array_append(reasons,'Valor, parcela, cartão ou fatura alterados depois de importar: '||coalesce(actual->>'title','(sem título)')||'. Desfaça essa alteração ou corrija o item individualmente.');
  end if;
 end loop;
 select coalesce(sum(a.amount),0) into paid from cc_allocations a join cc_payments p on p.id=a.payment_id and p.reversed_at is null
  join cc_import_items m on m.table_name='cc_lines' and m.entity_id=a.line_id and m.created and m.import_id=imp.id;
 if paid>0 then warnings:=array_append(warnings,'Há '||to_char(paid,'FM999G999G990D00')||' de pagamento aplicado a estes lançamentos. O pagamento continua registrado e a fatura ficará com crédito.');end if;
 if exists(select 1 from cc_import_items owner join cc_import_items other on other.table_name=owner.table_name and other.entity_id=owner.entity_id and other.import_id<>owner.import_id join cc_imports later on later.id=other.import_id and later.status='active' where owner.import_id=imp.id and owner.created) then reasons:=array_append(reasons,'Outra importação ativa usa lançamentos desta (parcela do mês seguinte). Desfaça primeiro a importação mais recente.');end if;
 if exists(select 1 from cc_imports other cross join lateral jsonb_array_elements(case when jsonb_typeof(other.summary->'rows')='array' then other.summary->'rows' else '[]' end) r join cc_import_items owned on owned.import_id=imp.id and owned.created and owned.table_name='cc_lines' and owned.entity_id::text=r->>'line_id' where other.id<>imp.id and other.status='active' and r->>'decision'='link') then reasons:=array_append(reasons,'Outra importação ativa vinculou lançamentos desta. Desfaça primeiro a importação mais recente.');end if;
 if exists(select 1 from cc_lines l join cc_import_items p on p.entity_id=l.purchase_id and p.table_name='cc_purchases' and p.created and p.import_id=imp.id where l.line_type<>'principal' and not exists(select 1 from cc_import_items m where m.import_id=imp.id and m.created and m.table_name='cc_lines' and m.entity_id=l.id)) then reasons:=array_append(reasons,'Compra importada recebeu estorno ou desconto depois. Desfaça o estorno primeiro.');end if;
 if exists(select 1 from cc_adjustment_reversals r join cc_import_items m on m.import_id=imp.id and m.created and m.table_name='cc_lines' and (m.entity_id=r.line_id or m.entity_id=r.reversal_line_id)) then reasons:=array_append(reasons,'O ajuste desta importação foi revertido manualmente. Desfaça a reversão primeiro.');end if;
 select coalesce(jsonb_agg(id order by id),'[]'::jsonb) into adjustments from cc_lines where invoice_id=any(invoices) and line_type='adjustment' and id not in (select entity_id from cc_import_items where import_id=imp.id and created)
  and not (to_jsonb(id::text) <@ coalesce(imp.effects->'adjustments_after','[]'::jsonb));
 if jsonb_array_length(adjustments)>0 then warnings:=array_append(warnings,'A fatura recebeu ajustes ou conciliação manual depois desta importação; eles não serão removidos. Confira o total depois.');end if;
 return jsonb_build_object('import_id',imp.id,'safe',cardinality(reasons)=0,'reasons',to_jsonb(reasons),'warnings',to_jsonb(warnings),
  'needs_confirmation',cardinality(warnings)>0,'remaining',remaining,'orphan',remaining=0 and imp.status='active','legacy',imp.provenance_version<>1,
  'created_lines',(select count(*) from cc_import_items m join cc_lines l on l.id=m.entity_id where m.import_id=imp.id and m.table_name='cc_lines' and m.created),
  'created_purchases',(select count(*) from cc_import_items m join cc_purchases p on p.id=m.entity_id where m.import_id=imp.id and m.table_name='cc_purchases' and m.created),
  'linked_lines',(select count(*) from cc_import_items where import_id=imp.id and table_name='cc_lines' and not created),
  'invoice_ids',to_jsonb(invoices),'paid',paid,'bank_delta',0);
end $$;
revoke all on function public.cc_import_impact(uuid) from public,anon,authenticated;

alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v25;
revoke all on function public.cc_action_v25(uuid,uuid,text,jsonb) from public,anon,authenticated;

create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare prior cc_requests%rowtype; imp cc_imports%rowtype; impact jsonb; result jsonb; invoice_ids uuid[]; r jsonb; lid uuid; pid uuid; released int:=0;
begin
 if p_action not in ('import_statement','preview_undo_import','undo_import','force_clear_import','adopt_legacy_import') then return cc_action_v25(p_id,p_household,p_action,p_data);end if;
 if p_id is null or p_data is null or not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 select * into prior from cc_requests where id=p_id;
 if found then
  if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;
  return prior.result;
 end if;

 if p_action='import_statement' then
  -- Mesmo arquivo de novo: libera importações anteriores que não têm mais nenhum lançamento.
  for imp in select * from cc_imports where household_id=p_household and card_id=(p_data->>'card_id')::uuid and file_hash=p_data->>'file_hash' and status='active' for update loop
   if cc_import_remaining(imp.id)=0 then
    update cc_imports set status='undone',undone_at=now(),undone_by=auth.uid(),effects=effects||jsonb_build_object('released_orphan',now()) where id=imp.id;
    released:=released+1;
   end if;
  end loop;
  result:=cc_action_v25(p_id,p_household,p_action,p_data);
  if released>0 then result:=result||jsonb_build_object('released_orphans',released);end if;
  return result;
 end if;

 select * into imp from cc_imports where id=(p_data->>'import_id')::uuid and household_id=p_household for update;
 if not found then raise exception 'Importação indisponível';end if;

 if p_action='preview_undo_import' then return cc_import_impact(imp.id);end if;

 if p_action='adopt_legacy_import' then
  -- Usa só os IDs que a própria importação gravou no seu resumo (line_id). Nada é inferido por descrição.
  if imp.status<>'active' or imp.provenance_version=1 then raise exception 'Importação já identificada ou desfeita';end if;
  for r in select value from jsonb_array_elements(case when jsonb_typeof(imp.summary->'rows')='array' then imp.summary->'rows' else '[]' end) loop
   lid:=nullif(r->>'line_id','')::uuid; continue when lid is null;
   if r->>'decision'='new' then
    select purchase_id into pid from cc_lines where id=lid;
    if found then
     insert into cc_import_items select imp.id,p_household,'cc_lines',l.id,true,to_jsonb(l) from cc_lines l where l.id=lid or (pid is not null and l.purchase_id=pid and l.line_type='principal') on conflict do nothing;
     if pid is not null then insert into cc_import_items select imp.id,p_household,'cc_purchases',p.id,true,to_jsonb(p) from cc_purchases p where p.id=pid on conflict do nothing;end if;
    end if;
   elsif r->>'decision'='link' then
    insert into cc_import_items select imp.id,p_household,'cc_lines',l.id,false,to_jsonb(l) from cc_lines l where l.id=lid on conflict do nothing;
   end if;
  end loop;
  select array_agg(distinct x) into invoice_ids from (select l.invoice_id x from cc_import_items m join cc_lines l on l.id=m.entity_id where m.import_id=imp.id and m.table_name='cc_lines' union select imp.invoice_id) s;
  update cc_imports set provenance_version=1,effects=effects||jsonb_build_object('invoice_ids',to_jsonb(invoice_ids),'adopted_legacy',now()) where id=imp.id;
  result:=cc_import_impact(imp.id);
  insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());return result;
 end if;

 if p_action='force_clear_import' then
  if imp.status<>'active' then raise exception 'Importação já desfeita';end if;
  if cc_import_remaining(imp.id)>0 then raise exception 'Esta importação ainda tem lançamentos no app. Use Desfazer importação.';end if;
  if p_data->>'confirmed' is distinct from 'true' then raise exception 'Confirme a limpeza do histórico';end if;
  update cc_imports set status='undone',undone_at=now(),undone_by=auth.uid(),effects=effects||jsonb_build_object('force_cleared',now()) where id=imp.id;
  result:=jsonb_build_object('import_id',imp.id,'status','undone','cleared',true);
  insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());return result;
 end if;

 -- undo_import
 impact:=cc_import_impact(imp.id);
 if not coalesce((impact->>'safe')::boolean,false) then raise exception '%',(select string_agg(value,' ') from jsonb_array_elements_text(impact->'reasons'));end if;
 if p_data->>'confirmed' is distinct from 'true' then raise exception 'Confirme o desfazimento integral da importação';end if;
 if coalesce((impact->>'needs_confirmation')::boolean,false) and p_data->>'confirm_warnings' is distinct from 'true' then raise exception 'Confirme: %',(select string_agg(value,' ') from jsonb_array_elements_text(impact->'warnings'));end if;
 select array_agg(distinct x) into invoice_ids from (select value::uuid x from jsonb_array_elements_text(coalesce(imp.effects->'invoice_ids','[]')) union select l.invoice_id from cc_import_items m join cc_lines l on l.id=m.entity_id where m.import_id=imp.id and m.created and m.table_name='cc_lines') s;
 perform id from cc_invoices where id=any(invoice_ids) order by id for update;
 -- Alocações de pagamento dos lançamentos removidos: guardadas na auditoria antes de sair.
 insert into cc_audit(household_id,actor_id,table_name,before_data,after_data)
  select p_household,auth.uid(),'cc_allocations',to_jsonb(a),jsonb_build_object('removed_by_undo_import',imp.id)
  from cc_allocations a join cc_import_items m on m.table_name='cc_lines' and m.entity_id=a.line_id and m.created and m.import_id=imp.id;
 delete from cc_allocations a using cc_import_items m where m.table_name='cc_lines' and m.entity_id=a.line_id and m.created and m.import_id=imp.id;
 delete from cc_lines l using cc_import_items m where m.import_id=imp.id and m.created and m.table_name='cc_lines' and m.entity_id=l.id;
 delete from cc_purchases p using cc_import_items m where m.import_id=imp.id and m.created and m.table_name='cc_purchases' and m.entity_id=p.id;
 update cc_invoices set revision=revision+1 where id=any(invoice_ids);
 update cc_imports set status='undone',undone_at=now(),undone_by=auth.uid() where id=imp.id;
 result:=impact||jsonb_build_object('status','undone');
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());return result;
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';


-- 027_import_installment_amounts.sql

-- 027 · Parcelas com os valores exatos do PDF.
-- ADITIVA: só funções. Não altera dados ao ser aplicada. Pré-requisito: 023 a 026.
-- O banco (Itaú/Azul) costuma pôr o centavo de diferença na 1ª parcela (ex.: 91,39 + 3 × 91,37).
-- A importação passa a aceitar "amounts" por linha: o valor de cada parcela, desta até a última,
-- lido em "Compras parceladas - próximas faturas". Assim a parcela do mês seguinte bate no centavo
-- e é reconhecida como já lançada, sem duplicar.

create or replace function public.cc_import_normalize(p_data jsonb) returns jsonb language sql immutable as $$
 -- Para linhas com "amounts", o caminho anterior recebe total = parcela × quantidade (para validar a parcela atual)
 -- e o total real fica em "real_total". A transformação é determinística: repetir o pedido gera o mesmo conteúdo.
 select case when jsonb_typeof(p_data->'rows') is distinct from 'array' then p_data else
  jsonb_set(p_data,'{rows}',(select coalesce(jsonb_agg(case when jsonb_typeof(r->'amounts')='array' and r->>'decision'='new' and r->>'kind'='purchase'
     then r||jsonb_build_object('real_total',r->'total_amount','total_amount',round((r->>'amount')::numeric*(r->>'count')::int,2))
     else r end order by n),'[]'::jsonb) from jsonb_array_elements(p_data->'rows') with ordinality t(r,n))) end
$$;
revoke all on function public.cc_import_normalize(jsonb) from public,anon,authenticated;

alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v26;
revoke all on function public.cc_action_v26(uuid,uuid,text,jsonb) from public,anon,authenticated;

create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_data jsonb; result jsonb; imp cc_imports%rowtype; r jsonb; rec jsonb; n int; pid uuid; amounts jsonb; i int; v numeric; first_inst int; cnt int; real_total numeric; invoice_ids uuid[];
begin
 if p_action<>'import_statement' or p_data is null or nullif(p_data->>'cycle','') is null
    or not exists(select 1 from jsonb_array_elements(case when jsonb_typeof(p_data->'rows')='array' then p_data->'rows' else '[]' end) x where jsonb_typeof(x->'amounts')='array') then
  return cc_action_v26(p_id,p_household,p_action,p_data);
 end if;
 v_data:=cc_import_normalize(p_data);
 if exists(select 1 from cc_requests where id=p_id) then return cc_action_v26(p_id,p_household,p_action,v_data);end if; -- repetição idempotente
 result:=cc_action_v26(p_id,p_household,p_action,v_data);
 select * into imp from cc_imports where id=(result->>'import_id')::uuid;
 for r,n in select value,ordinality from jsonb_array_elements(v_data->'rows') with ordinality loop
  continue when jsonb_typeof(r->'amounts') is distinct from 'array' or r->>'decision' is distinct from 'new' or r->>'kind' is distinct from 'purchase';
  rec:=imp.summary->'rows'->(n-1)::int; pid:=nullif(rec->>'purchase_id','')::uuid; continue when pid is null;
  amounts:=r->'amounts'; first_inst:=(r->>'installment')::int; cnt:=(r->>'count')::int; real_total:=nullif(r->>'real_total','')::numeric;
  if jsonb_array_length(amounts)<>cnt-first_inst+1 then raise exception 'Valores das parcelas incompletos: %',left(r->>'description',60);end if;
  if (amounts->>0)::numeric<>(r->>'amount')::numeric then raise exception 'A primeira parcela informada não confere: %',left(r->>'description',60);end if;
  for i in first_inst..cnt loop
   v:=(amounts->>(i-first_inst))::numeric;
   if v is null or v<=0 or v<>round(v,2) or v>9000000000000 then raise exception 'Valor de parcela inválido: %',left(r->>'description',60);end if;
   update cc_lines set amount=v where purchase_id=pid and installment=i and line_type='principal';
  end loop;
  if real_total is null or real_total<(select sum(amount) from cc_lines where purchase_id=pid and line_type='principal') then
   real_total:=(select sum(amount) from cc_lines where purchase_id=pid and line_type='principal')+(r->>'amount')::numeric*(first_inst-1);
  end if;
  update cc_purchases set amount=real_total where id=pid;
  -- O manifesto do desfazer passa a conter os valores finais.
  update cc_import_items m set snapshot=to_jsonb(l) from cc_lines l where m.import_id=imp.id and m.table_name='cc_lines' and m.entity_id=l.id and l.purchase_id=pid;
  update cc_import_items m set snapshot=to_jsonb(p) from cc_purchases p where m.import_id=imp.id and m.table_name='cc_purchases' and m.entity_id=p.id and p.id=pid;
  select array_agg(distinct invoice_id) into invoice_ids from cc_lines where purchase_id=pid;
  update cc_invoices set revision=revision+1 where id=any(invoice_ids);
 end loop;
 return result;
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';


-- 028_card_line_category.sql

-- 028 · Alterar a categoria de lançamentos do cartão.
-- ADITIVA: só função. Não altera dados ao ser aplicada. Pré-requisito: 019 a 027.
-- Muda apenas a categoria (sem valor, data, fatura ou pagamento). Não interfere em importação,
-- desfazer (que ignora categoria) nem em saldos.

alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v27;
revoke all on function public.cc_action_v27(uuid,uuid,text,jsonb) from public,anon,authenticated;

create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare prior cc_requests%rowtype; ln cc_lines%rowtype; v_category text; n int; result jsonb;
begin
 if p_action<>'set_category' then return cc_action_v27(p_id,p_household,p_action,p_data);end if;
 if p_id is null or p_data is null or not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));
 select * into prior from cc_requests where id=p_id;
 if found then
  if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;
  return prior.result;
 end if;
 select * into ln from cc_lines where id=(p_data->>'line_id')::uuid and household_id=p_household for update;
 if not found then raise exception 'Lançamento indisponível';end if;
 v_category:=trim(coalesce(p_data->>'category',''));
 if length(v_category) not between 1 and 100 then raise exception 'Escolha uma categoria';end if;
 if coalesce(p_data->>'scope','purchase')='purchase' and ln.purchase_id is not null then
  update cc_lines set category=v_category where purchase_id=ln.purchase_id and line_type='principal';
  get diagnostics n=row_count;
  update cc_purchases set category=v_category where id=ln.purchase_id;
 else
  update cc_lines set category=v_category where id=ln.id;n:=1;
 end if;
 update cc_invoices set revision=revision+1 where id in (select invoice_id from cc_lines where id=ln.id or (ln.purchase_id is not null and purchase_id=ln.purchase_id));
 result:=jsonb_build_object('updated',n,'category',v_category);
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());
 return result;
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';

commit;
