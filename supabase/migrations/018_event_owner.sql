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
