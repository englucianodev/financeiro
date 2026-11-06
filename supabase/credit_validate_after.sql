-- READ ONLY. Run AFTER 019. Empty anomaly results are expected.

-- Cached bank balances must continue matching the ledger.
select a.id,a.balance,coalesce(sum(l.amount),0) ledger_balance
from public.financial_accounts a left join public.account_ledger l on l.account_id=a.id
group by a.id having a.balance<>coalesce(sum(l.amount),0);

-- Only revised/new cards must have an active payment account of their holder.
select c.id,c.name,c.account_id from public.credit_cards c
left join public.financial_accounts a on a.id=c.account_id
where c.module_version=2 and c.card_status='active'
and (a.id is null or not a.active or a.owner_id<>c.owner_id or a.household_id<>c.household_id or a.account_type='investment');

-- Unconfirmed obligations must have no actual charge. Posted ones must have exactly one purchase.
select o.id,o.state,count(p.id) purchases from public.cc_obligations o
left join public.cc_purchases p on p.obligation_id=o.id group by o.id
having (o.state='posted' and count(p.id)<>1) or (o.state<>'posted' and count(p.id)<>0);

-- Imported past installments must not exist in the new module.
select p.id,p.next_installment,l.installment from public.cc_purchases p
join public.cc_lines l on l.purchase_id=p.id
where l.line_type='principal' and l.installment<p.next_installment;

-- Active allocation sums must match each line's paid principal/fees.
select l.id,l.paid,coalesce(sum(a.amount) filter(where p.reversed_at is null),0) allocated
from public.cc_lines l left join public.cc_allocations a on a.line_id=l.id
left join public.cc_payments p on p.id=a.payment_id group by l.id
having l.paid<>coalesce(sum(a.amount) filter(where p.reversed_at is null),0);

-- Every active payment must have exactly one bank debit, and reversed ones one compensation.
select p.id,p.amount,p.reversed_at,
 (select count(*) from public.account_ledger l where l.operation_key='cc-pay:'||p.id and l.account_id=p.account_id and l.amount=-p.amount) debits,
 (select count(*) from public.account_ledger l where l.operation_key='cc-undo:'||p.id and l.account_id=p.account_id and l.amount=p.amount) reversals
from public.cc_payments p where
 (select count(*) from public.account_ledger l where l.operation_key='cc-pay:'||p.id and l.account_id=p.account_id and l.amount=-p.amount)<>1
 or (p.reversed_at is not null and (select count(*) from public.account_ledger l where l.operation_key='cc-undo:'||p.id and l.account_id=p.account_id and l.amount=p.amount)<>1);

-- Operational invoice summary (this result is informational, not an anomaly query).
select c.name,c.owner_id,i.cycle,i.closing_date,i.due_date,
 coalesce(sum(l.amount),0) total,coalesce(sum(l.paid),0) paid,
 coalesce(sum(l.amount-l.paid),0) remaining
from public.cc_invoices i join public.credit_cards c on c.id=i.card_id
left join public.cc_lines l on l.invoice_id=i.id group by i.id,c.name,c.owner_id order by c.name,i.cycle;

-- An automatic charge unable to post stays pending and visible.
select id,title,due_date,generation_error from public.cc_obligations
where state='pending' and mode='automatic' and due_date<=(now() at time zone 'America/Fortaleza')::date;
