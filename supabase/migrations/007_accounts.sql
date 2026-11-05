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
