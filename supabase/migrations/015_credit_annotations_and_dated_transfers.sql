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
