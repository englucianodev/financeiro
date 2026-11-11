-- Execute no SQL Editor administrativo, com backup e o aplicativo fechado.
-- Consulta para encontrar o ID: select id, name from public.households;
begin;
set local lock_timeout = '10s';
set local statement_timeout = '120s';
do $$
declare
  v_house uuid := 'COLE_O_ID_DA_FAMILIA_AQUI';
  -- false: conserva os saldos bancários atuais.
  -- true: também compensa os débitos/créditos dos pagamentos dos cartões.
  v_repor_saldos boolean := false;
  v_batch uuid := gen_random_uuid();
  v_events uuid[];
  v_table text;
begin
  if not exists(select 1 from pg_roles where rolname=current_user and (rolsuper or rolbypassrls)) then
    raise exception 'Execute com a função administrativa do SQL Editor';
  end if;
  if not exists(select 1 from public.households where id=v_house) then
    raise exception 'Família não encontrada';
  end if;
  if to_regclass('public.cc_audit') is null then
    raise exception 'Este script exige o módulo de cartões da migration 019 ou posterior';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(v_house::text,190));
  foreach v_table in array array[
    'financial_accounts','financial_events','account_ledger','event_payments',
    'credit_cards','cc_recurrences','cc_obligations','cc_purchases','cc_lines',
    'cc_invoices','cc_payments','cc_allocations','cc_imports','cc_import_items',
    'cc_invoice_targets','cc_adjustment_reversals','card_purchases','invoice_payments'
  ] loop
    if to_regclass('public.'||v_table) is not null then
      execute format('lock table public.%I in share row exclusive mode',v_table);
    end if;
  end loop;

  select coalesce(array_agg(id),'{}'::uuid[]) into v_events
  from public.financial_events
  where household_id=v_house and (card_id is not null or credit_state<>'none');

  if exists(select 1 from public.property_installment_payments where event_id=any(v_events)) then
    raise exception 'Há lançamentos de cartão vinculados a parcelas de imóvel. Revise esses vínculos antes da limpeza';
  end if;
  if exists(
    select 1 from public.financial_accounts a
    where a.household_id=v_house and a.balance<>
      (select coalesce(sum(l.amount),0) from public.account_ledger l where l.account_id=a.id)
  ) then
    raise exception 'Há divergência entre saldo e ledger. Nenhum dado foi apagado';
  end if;

  insert into public.cc_audit(household_id,actor_id,table_name,before_data,after_data)
  values(v_house,auth.uid(),'credit_reset',null,
    jsonb_build_object('batch_id',v_batch,'repor_saldos',v_repor_saldos,'legacy_events',cardinality(v_events)));

  if v_repor_saldos then
    insert into public.account_ledger(household_id,account_id,amount,operation_key,actor_id)
    select v_house,l.account_id,-sum(l.amount),'credit-reset:'||v_batch||':'||l.account_id,auth.uid()
    from public.account_ledger l
    where l.household_id=v_house and (
      l.event_id=any(v_events) or exists(
        select 1 from public.cc_payments p
        where p.household_id=v_house and p.account_id=l.account_id
          and l.operation_key in ('cc-pay:'||p.id,'cc-undo:'||p.id)
      )
    )
    group by l.account_id having sum(l.amount)<>0;
  end if;

  -- Preserva o ledger e documenta a referência antiga antes de remover os eventos.
  insert into public.cc_audit(household_id,actor_id,table_name,before_data,after_data)
  select v_house,auth.uid(),'account_ledger',to_jsonb(l),
    to_jsonb(l)||jsonb_build_object('event_id',null,'cleanup_batch',v_batch)
  from public.account_ledger l where l.event_id=any(v_events);
  update public.account_ledger set event_id=null where event_id=any(v_events);

  insert into public.cc_audit(household_id,actor_id,table_name,before_data,after_data)
  select v_house,auth.uid(),'event_payments',to_jsonb(p),null
  from public.event_payments p where p.event_id=any(v_events);
  delete from public.event_payments where event_id=any(v_events);

  insert into public.cc_audit(household_id,actor_id,table_name,before_data,after_data)
  select v_house,auth.uid(),'financial_events',to_jsonb(e),null
  from public.financial_events e where e.id=any(v_events);
  delete from public.financial_events where id=any(v_events);

  -- Ordem das dependências. Tabelas opcionais são ignoradas quando não existem.
  foreach v_table in array array[
    'cc_import_items','cc_adjustment_reversals','cc_invoice_targets','cc_imports',
    'cc_allocations','cc_payments','cc_lines','cc_purchases','cc_obligations',
    'cc_recurrences','cc_invoices','invoice_payments','card_purchases'
  ] loop
    if to_regclass('public.'||v_table) is not null then
      execute format(
        'insert into public.cc_audit(household_id,actor_id,table_name,before_data,after_data)
         select $1,auth.uid(),$2,to_jsonb(t),null from public.%I t where household_id=$1',v_table
      ) using v_house,v_table;
      execute format('delete from public.%I where household_id=$1',v_table) using v_house;
    end if;
  end loop;

  if exists(
    select 1 from public.financial_accounts a
    where a.household_id=v_house and a.balance<>
      (select coalesce(sum(l.amount),0) from public.account_ledger l where l.account_id=a.id)
  ) then
    raise exception 'Validação final falhou; a transação será revertida integralmente';
  end if;
  raise notice 'Limpeza concluída. Família: %. Auditoria: %. Reposição de saldos: %',v_house,v_batch,v_repor_saldos;
end $$;
commit;
