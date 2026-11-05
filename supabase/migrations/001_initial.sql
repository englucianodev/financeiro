
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
