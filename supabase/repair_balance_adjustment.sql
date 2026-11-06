-- Reparo do ajuste rápido de saldo (migration 012).
-- Execute no SQL Editor do mesmo Supabase conectado ao site na Vercel.
-- Pode ser executado novamente. Não altera contas, saldos ou lançamentos.
-- Se faltar a base da migration 010, interrompe antes de qualquer alteração.
begin;
do $$
begin
 if to_regprocedure('public.save_account(uuid,uuid,text,uuid,text,boolean,text,numeric,numeric)') is null
 or to_regprocedure('public.is_household_member(uuid)') is null
 or to_regclass('public.account_edits') is null
 or to_regclass('public.financial_accounts') is null
 or to_regclass('public.households') is null then
  raise exception 'Faltam migrations anteriores ao ajuste rápido de saldo. Aplique as migrations pendentes em ordem, incluindo a 010, antes de executar este reparo.';
 end if;
end $$;
create or replace function public.adjust_account_balance(p_id uuid,p_account uuid,p_balance numeric,p_expected_balance numeric) returns void
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

commit;
