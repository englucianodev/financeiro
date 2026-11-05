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
