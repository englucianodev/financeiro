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
