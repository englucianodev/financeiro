-- User-facing confirmations settle the ACTUAL expense. Partial payments require an explicit choice.
-- Old payment/invoice endpoints keep their partial-payment contract for existing integrations.
create table public.payment_action_requests(id uuid primary key,household_id uuid not null references households,parameters jsonb not null);
alter table public.payment_action_requests enable row level security;
create function public.manage_event_payment(p_id uuid,p_event uuid,p_action text,p_account uuid,p_amount numeric,p_date date,p_expected_version bigint,p_partial boolean default false) returns void
language plpgsql security definer set search_path=public as $$
declare e financial_events%rowtype;prior payment_action_requests%rowtype;params jsonb;total numeric;new_paid numeric;entry record;
begin
 select * into e from financial_events where id=p_event;
 if not found or not is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if p_id is null or p_action is null or p_action not in ('confirm','correct','close','undo') or p_partial is null then raise exception 'Operação inválida';end if;
 params:=jsonb_build_array(p_event,p_action,p_account,p_amount,p_date,p_expected_version,p_partial);
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,19));
 select * into prior from payment_action_requests where id=p_id;
 if found then if prior.household_id<>e.household_id or prior.parameters<>params then raise exception 'Chave já utilizada';end if;return;end if;
 select * into e from financial_events where id=p_event for update;
 if p_expected_version is null or p_expected_version<>e.edit_version then raise exception 'A transação foi alterada. Feche esta janela, atualize a lista e tente novamente';end if;
 if e.status='cancelled' then raise exception 'Transação excluída';end if;
 if p_action='undo' and e.credit_state='paid' then
  update financial_events set credit_state='planned' where id=e.id;
 elsif e.credit_state<>'none' then
  raise exception 'Despesa incluída no cartão. Corrija a anotação ou pague a fatura para não duplicar o débito';
 elsif p_action='undo' then
  if e.paid_amount<=0 then raise exception 'A transação já está pendente, sem pagamentos para desfazer';end if;
  perform reverse_event(e.id);
 elsif p_action='close' then
  if e.status<>'pending' or e.paid_amount<=0 then raise exception 'Não há pagamento parcial para encerrar';end if;
  if coalesce((select sum(amount) from account_ledger where event_id=e.id),0)<>(case when e.kind='income' then e.paid_amount else -e.paid_amount end) then raise exception 'Histórico de pagamento inconsistente. Desfaça o pagamento e confirme novamente';end if;
  update financial_events set amount=paid_amount,status='settled',settled_at=now() where id=e.id;
 else
  if p_account is null or p_amount is null or p_amount='NaN'::numeric or p_amount<=0 or p_amount>9000000000000 or p_amount<>round(p_amount,2) or p_date is null or p_date>(now() at time zone 'America/Fortaleza')::date then raise exception 'Informe valor e data efetivos válidos';end if;
  if not exists(select 1 from financial_accounts where id=p_account and household_id=e.household_id and active) then raise exception 'Conta inválida';end if;
  -- Lock every affected bank account in the same order before a correction/refund.
  perform id from financial_accounts where household_id=e.household_id and (id=p_account or id in(select account_id from account_ledger where event_id=e.id)) order by id for update;
  if p_action='correct' then
   if e.paid_amount<=0 then raise exception 'Não há pagamento para corrigir';end if;
   -- Correct cash postings without reopening a settled installment: its financing
   -- may have changed since payment, and must never be counted in a new loan.
   for entry in select account_id,sum(amount) amount from account_ledger where event_id=e.id group by account_id having sum(amount)<>0 loop
    insert into account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(e.household_id,entry.account_id,-entry.amount,'correction:'||p_id,e.id,auth.uid());
   end loop;
   update event_payments set reversed_at=now() where event_id=e.id and reversed_at is null;
   new_paid:=p_amount;total:=p_amount;
  else
   if e.status<>'pending' then raise exception 'A transação já foi quitada';end if;
   new_paid:=e.paid_amount+p_amount;
   if new_paid>9000000000000 then raise exception 'Valor acima do limite';end if;
   if p_partial and new_paid>e.amount then raise exception 'Pagamento parcial superior ao valor pendente';end if;
   total:=case when p_partial then e.amount else new_paid end;
  end if;
  insert into event_payments(id,household_id,event_id,account_id,amount,paid_date,actor_id) values(p_id,e.household_id,e.id,p_account,p_amount,p_date,auth.uid());
  insert into account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(e.household_id,p_account,case when e.kind='income' then p_amount else -p_amount end,'payment:'||p_id,e.id,auth.uid());
  update financial_events set amount=total,paid_amount=new_paid,status=case when new_paid=total then 'settled' else 'pending' end,settled_at=case when new_paid=total then now() else null end where id=e.id;
  if p_action='correct' and e.status='settled' and e.variable_amount and e.series_id is not null then
   update financial_events set amount=total where household_id=e.household_id and series_id=e.series_id and due_date>e.due_date and status='pending' and paid_amount=0;
  end if;
 end if;
 insert into payment_action_requests values(p_id,e.household_id,params);
end $$;
revoke all on function public.manage_event_payment(uuid,uuid,text,uuid,numeric,date,bigint,boolean) from public;
grant execute on function public.manage_event_payment(uuid,uuid,text,uuid,numeric,date,bigint,boolean) to authenticated;
notify pgrst,'reload schema';
