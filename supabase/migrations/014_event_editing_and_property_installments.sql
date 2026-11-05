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
