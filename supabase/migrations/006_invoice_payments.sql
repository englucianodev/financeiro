create table public.invoice_payments(id uuid primary key,household_id uuid not null references public.households,card_id uuid not null references public.credit_cards,due_date date not null,account_id uuid not null references public.financial_accounts,amount numeric(16,2) not null,paid_date date not null);
alter table public.invoice_payments enable row level security;
create policy invoice_payments_read on public.invoice_payments for select to authenticated using(public.is_household_member(household_id));
create function public.pay_invoice(p_id uuid,p_card uuid,p_due date,p_account uuid,p_amount numeric,p_date date) returns void language plpgsql security definer set search_path=public as $$
declare c public.credit_cards%rowtype;previous public.invoice_payments%rowtype;e public.financial_events%rowtype;remaining numeric;portion numeric;
begin
 select * into c from public.credit_cards where id=p_card;
 if not found or not public.is_household_member(c.household_id) then raise exception 'Sem permissão';end if;
 if p_id is null or p_due is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) then raise exception 'Pagamento inválido';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,5));
 select * into previous from public.invoice_payments where id=p_id;
 if found then
 if previous.card_id<>p_card or previous.due_date<>p_due or previous.account_id<>p_account or previous.amount<>p_amount or previous.paid_date<>p_date then raise exception 'Chave já utilizada';end if;return;end if;
 perform id from public.financial_events where card_id=p_card and due_date=p_due order by id for update;
 if p_amount>coalesce((select sum(amount-paid_amount) from public.financial_events where card_id=p_card and due_date=p_due and status='pending'),0) then raise exception 'Valor superior ao saldo da fatura';end if;
 insert into public.invoice_payments values(p_id,c.household_id,p_card,p_due,p_account,p_amount,p_date);
 remaining:=p_amount;
 for e in select * from public.financial_events where card_id=p_card and due_date=p_due and status='pending' order by id loop
 exit when remaining=0;portion:=least(remaining,e.amount-e.paid_amount);
 perform public.pay_event(gen_random_uuid(),e.id,p_account,portion,p_date,e.paid_amount);
 remaining:=remaining-portion;
 end loop;
end $$;
revoke all on function public.pay_invoice(uuid,uuid,date,uuid,numeric,date) from public;
grant execute on function public.pay_invoice(uuid,uuid,date,uuid,numeric,date) to authenticated;
