-- READ ONLY. Run after migrations 001–018, before 019 or reconciliation.
-- Run each SELECT separately in SQL Editor. No UPDATE/DELETE/INSERT is performed.

-- 1. Accounts whose cached balance differs from their ledger.
select a.id,a.household_id,a.name,a.balance,coalesce(sum(l.amount),0) ledger_balance
from public.financial_accounts a left join public.account_ledger l on l.account_id=a.id
group by a.id having a.balance<>coalesce(sum(l.amount),0);

-- 2. Legacy card/account relationships requiring an explicit choice before new payments.
select c.id,c.name,c.owner_id,c.account_id,a.owner_id account_owner,a.active
from public.credit_cards c left join public.financial_accounts a on a.id=c.account_id
where a.id is null or a.household_id<>c.household_id or a.owner_id<>c.owner_id or not a.active;

-- 3. Legacy annotation inventory. These are NOT automatically converted to purchases.
select e.id,e.household_id,e.title,e.owner_id,e.account_id,e.amount,e.paid_amount,
 e.due_date,e.status,e.credit_state,e.payment_card_id,c.name card_name
from public.financial_events e left join public.credit_cards c on c.id=e.payment_card_id
where e.credit_state<>'none' order by e.household_id,e.due_date,e.id;

-- 4. Legacy installments remain in the original financial_events flow.
select c.id,c.name,c.owner_id,count(e.id) installments,
 coalesce(sum(e.amount) filter(where e.status<>'cancelled'),0) total,
 coalesce(sum(e.amount-e.paid_amount) filter(where e.status='pending'),0) remaining
from public.credit_cards c left join public.financial_events e on e.card_id=c.id
group by c.id,c.name,c.owner_id order by c.name;

-- 5. Possible annotation/invoice overlap: diagnostic candidates, never proof of duplication.
select note.id annotation_id,note.title,note.amount,note.due_date,note.payment_card_id,
 bill.id possible_existing_invoice_id,bill.title possible_existing_invoice_title
from public.financial_events note join public.financial_events bill
 on bill.household_id=note.household_id and bill.kind='expense' and bill.status<>'cancelled'
 and bill.id<>note.id and bill.due_date>=date_trunc('month',note.due_date)::date
 and bill.due_date<(date_trunc('month',note.due_date)+interval '2 months')::date
 and (bill.card_id=note.payment_card_id or bill.title ilike '%fatura%')
where note.credit_state<>'none';

-- 6. Baseline to retain/export before migration. A managed Supabase backup is also recommended.
select 'financial_events' relation,count(*) rows,coalesce(sum(amount),0) monetary_total from public.financial_events
union all select 'financial_accounts',count(*),coalesce(sum(balance),0) from public.financial_accounts
union all select 'account_ledger',count(*),coalesce(sum(amount),0) from public.account_ledger
union all select 'card_purchases',count(*),coalesce(sum(amount),0) from public.card_purchases;
