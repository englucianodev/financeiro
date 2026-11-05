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
