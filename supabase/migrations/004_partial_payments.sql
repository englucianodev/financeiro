alter table public.financial_events add column paid_amount numeric(16,2) not null default 0 check(paid_amount>=0 and paid_amount<=amount);
update public.financial_events set paid_amount=amount where status='settled';
create table public.event_payments(id uuid primary key,household_id uuid not null references public.households,event_id uuid not null references public.financial_events,account_id uuid not null references public.financial_accounts,amount numeric(16,2) not null,paid_date date not null,actor_id uuid not null references auth.users,reversed_at timestamptz);
alter table public.event_payments enable row level security;
create policy payments_read on public.event_payments for select to authenticated using(public.is_household_member(household_id));
create function public.pay_event(p_id uuid,p_event uuid,p_account uuid,p_amount numeric,p_date date,p_expected_paid numeric) returns void language plpgsql security definer set search_path=public as $$
declare e public.financial_events%rowtype;existing public.event_payments%rowtype;
begin
 select * into e from public.financial_events where id=p_event for update;
 if not found or not public.is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if p_id is null then raise exception 'Chave obrigatória';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,4));
 select * into existing from public.event_payments where id=p_id;
 if found then
 if existing.event_id<>p_event or existing.account_id<>p_account or existing.amount<>p_amount or existing.paid_date<>p_date then raise exception 'Chave já utilizada';end if;return;end if;
 if p_expected_paid is null or e.paid_amount<>p_expected_paid then raise exception 'Lançamento alterado. Atualize a página';end if;
 if e.status<>'pending' or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount>e.amount-e.paid_amount or p_date is null or p_date>(now() at time zone 'America/Fortaleza')::date then raise exception 'Pagamento inválido';end if;
 perform 1 from public.financial_accounts where id=p_account and household_id=e.household_id and active for update;
 if not found then raise exception 'Conta inválida';end if;
 insert into public.event_payments values(p_id,e.household_id,e.id,p_account,p_amount,p_date,auth.uid(),null);
 insert into public.account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(e.household_id,p_account,case when e.kind='income' then p_amount else -p_amount end,'payment:'||p_id,e.id,auth.uid());
 update public.financial_events set paid_amount=paid_amount+p_amount,status=case when paid_amount+p_amount=amount then 'settled' else 'pending' end,settled_at=case when paid_amount+p_amount=amount then now() else null end where id=e.id;
end $$;
-- Legacy endpoint is no longer exposed: all confirmations require retry and concurrency keys.
revoke execute on function public.settle_event(uuid,uuid) from authenticated;
create or replace function public.reverse_event(p_event_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare e public.financial_events%rowtype;entry record;operation uuid:=gen_random_uuid();
begin
 select * into e from public.financial_events where id=p_event_id for update;
 if not found or not public.is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if e.paid_amount=0 then return;end if;
 perform id from public.financial_accounts where id in(select account_id from public.account_ledger where event_id=e.id) order by id for update;
 for entry in select account_id,sum(amount) amount from public.account_ledger where event_id=e.id group by account_id having sum(amount)<>0 loop
 insert into public.account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(e.household_id,entry.account_id,-entry.amount,'reversal:'||operation,e.id,auth.uid());
 end loop;
 update public.event_payments set reversed_at=now() where event_id=e.id and reversed_at is null;
 update public.financial_events set status='pending',paid_amount=0,settled_at=null where id=e.id;
end $$;
-- A partially paid event cannot be reduced below its confirmed amount or cancelled.
create or replace function public.edit_occurrence(p_event uuid,p_amount numeric,p_due date,p_cancel boolean) returns void language plpgsql security definer set search_path=public as $$
declare e public.financial_events%rowtype;
begin
 select * into e from public.financial_events where id=p_event for update;
 if not found or not public.is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if e.status<>'pending' or e.card_id is not null or e.paid_amount>0 then raise exception 'Estorne os pagamentos antes de editar';end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_due is null then raise exception 'Valor ou data inválidos';end if;
 update public.financial_events set amount=p_amount,due_date=p_due,status=case when p_cancel then 'cancelled' else 'pending' end where id=p_event;
end $$;
-- Supabase grants table privileges by default; RLS restricts every read, mutations use RPC only.
revoke all on function public.pay_event(uuid,uuid,uuid,numeric,date,numeric) from public;
grant execute on function public.pay_event(uuid,uuid,uuid,numeric,date,numeric) to authenticated;
drop policy events_insert on public.financial_events;
create policy events_insert on public.financial_events for insert to authenticated with check(public.is_household_member(household_id) and created_by=auth.uid() and status='pending' and settled_at is null and paid_amount=0 and card_id is null and purchase_id is null and series_id is null and exists(select 1 from public.household_members m where m.household_id=financial_events.household_id and m.user_id=owner_id) and exists(select 1 from public.financial_accounts a where a.id=account_id and a.household_id=financial_events.household_id and a.active));
