-- CHECK-UP DOS DADOS — SOMENTE LEITURA (não altera, não apaga nada)
-- Rode no SQL Editor do Supabase e exporte o resultado em CSV para análise.
-- Cada linha é um ACHADO para revisão. Nada aqui é prova de erro: são candidatos.
-- Colunas: verificacao | gravidade | detalhe | ids (para localizar os registros)

with
-- A. Saldo da conta diferente da soma do histórico (ledger)
a as (
  select 'A. Saldo ≠ histórico da conta' v,'alta' g,
    a.name||': saldo '||a.balance||' / histórico '||coalesce(s.total,0) d, a.id::text ids
  from financial_accounts a
  left join (select account_id,sum(amount) total from account_ledger group by account_id) s on s.account_id=a.id
  where a.balance<>coalesce(s.total,0)
),
-- B. Valor pago de lançamento diferente da soma dos pagamentos ativos
b as (
  select 'B. Pago do lançamento ≠ pagamentos registrados' v,'alta' g,
    e.title||' ('||to_char(e.due_date,'DD/MM/YYYY')||'): pago '||e.paid_amount||' / pagamentos '||coalesce(p.total,0) d, e.id::text
  from financial_events e
  left join (select event_id,sum(amount) total from event_payments where reversed_at is null group by event_id) p on p.event_id=e.id
  where e.paid_amount<>coalesce(p.total,0) and e.credit_state='none'
),
-- C. Situação incoerente com valores pagos
c as (
  select 'C. Situação incoerente' v,'média' g,
    e.title||' ('||to_char(e.due_date,'DD/MM/YYYY')||'): '||e.status||', valor '||e.amount||', pago '||e.paid_amount d, e.id::text
  from financial_events e
  where (e.status='settled' and e.paid_amount<e.amount and e.credit_state='none')
     or (e.status='pending' and e.paid_amount>=e.amount)
),
-- D. Lançamentos bancários possivelmente duplicados (mesmo título, valor, vencimento, conta)
d as (
  select 'D. Lançamento possivelmente duplicado' v,'média' g,
    min(e.title)||' · '||to_char(e.due_date,'DD/MM/YYYY')||' · '||e.amount||' · '||count(*)||' vezes' d,
    string_agg(e.id::text,', ' order by e.id)
  from financial_events e where e.status<>'cancelled'
  group by e.household_id,lower(trim(e.title)),e.amount,e.due_date,e.account_id,e.kind
  having count(*)>1
),
-- E. Linhas de cartão possivelmente duplicadas (mesmo cartão, descrição, data, valor, parcela)
e as (
  select 'E. Lançamento de cartão possivelmente duplicado' v,'alta' g,
    min(l.title)||' · compra '||to_char(l.charge_date,'DD/MM/YYYY')||' · '||l.amount||coalesce(' · parcela '||l.installment,'')||' · '||count(*)||' vezes' d,
    string_agg(l.id::text,', ' order by l.id)
  from cc_lines l join credit_cards k on k.id=l.card_id
  where l.line_type in ('principal','refund','fee') and not (l.line_type='principal' and l.installment is null and l.amount=0)
  group by coalesce(k.parent_card_id,k.id),regexp_replace(lower(l.title),'[^a-z0-9]','','g'),l.charge_date,l.amount,l.installment
  having count(*)>1
),
-- F. Parcelamentos sobrepostos: duas compras com mesma descrição/qtd de parcelas/valor de parcela no mesmo cartão
--    (sintoma típico de reimportar a parcela seguinte como compra nova)
f as (
  select 'F. Parcelamento repetido (compras diferentes com mesmas parcelas)' v,'alta' g,
    min(p.title)||' · '||p.installments||'x · '||count(*)||' compras' d,
    string_agg(p.id::text,', ' order by p.id)
  from cc_purchases p join credit_cards k on k.id=p.card_id
  where p.installments>1
  group by coalesce(k.parent_card_id,k.id),regexp_replace(lower(p.title),'[^a-z0-9]','','g'),p.installments,trunc(p.amount/p.installments,0)
  having count(*)>1
),
-- G. Pago na linha do cartão ≠ alocações de pagamentos ativos
g as (
  select 'G. Pago da linha do cartão ≠ pagamentos da fatura' v,'alta' g,
    l.title||': pago '||l.paid||' / alocado '||coalesce(s.total,0) d, l.id::text
  from cc_lines l
  left join (select a.line_id,sum(a.amount) total from cc_allocations a join cc_payments p on p.id=a.payment_id where p.reversed_at is null group by a.line_id) s on s.line_id=l.id
  where l.paid<>coalesce(s.total,0)
),
-- H. Compra (à vista ou 1ª parcela) feita DEPOIS do fechamento da fatura em que está
h as (
  select 'H. Compra depois do fechamento da fatura' v,'média' g,
    k.name||' · '||l.title||' · compra '||to_char(l.charge_date,'DD/MM/YYYY')||' na fatura '||to_char(i.cycle,'MM/YYYY')||' (fecha '||to_char(i.closing_date,'DD/MM/YYYY')||')' d, l.id::text
  from cc_lines l join cc_invoices i on i.id=l.invoice_id join credit_cards k on k.id=i.card_id
  left join cc_purchases p on p.id=l.purchase_id
  where l.line_type='principal' and coalesce(l.installment,1)=coalesce(p.next_installment,1) and l.charge_date>i.closing_date
),
-- I. Importações: fatura escolhida x vencimento lido no PDF (caso Azul)
i as (
  select 'I. Importação em fatura diferente do vencimento do PDF' v,'alta' g,
    k.name||' · '||m.file_name||' · importada em '||to_char(m.created_at at time zone 'America/Fortaleza','DD/MM/YYYY')||
    ' · fatura '||to_char(iv.cycle,'MM/YYYY')||' vence '||to_char(iv.due_date,'DD/MM/YYYY')||' · PDF vence '||coalesce(m.summary->'metadata'->>'due','?') d,
    m.id::text
  from cc_imports m join cc_invoices iv on iv.id=m.invoice_id join credit_cards k on k.id=m.card_id
  where coalesce(m.summary->'metadata'->>'due','')<>'' and to_char(iv.due_date,'DD/MM/YYYY')<>m.summary->'metadata'->>'due'
),
-- J. Linha de cartão em fatura de outro cartão
j as (
  select 'J. Linha em fatura de outro cartão' v,'alta' g, l.title d, l.id::text
  from cc_lines l join cc_invoices i on i.id=l.invoice_id join credit_cards k on k.id=l.card_id
  where coalesce(k.parent_card_id,k.id)<>i.card_id
),
-- K. Mesma despesa registrada nos dois modelos (anotação antiga no lançamento + compra no módulo de cartões)
k as (
  select 'K. Despesa anotada no modelo antigo e também no módulo de cartões' v,'média' g,
    e.title||' · '||to_char(e.due_date,'MM/YYYY')||' · '||e.amount||' (anotação: '||e.credit_state||')' d, e.id::text||' / '||l.id::text
  from financial_events e
  join cc_lines l on l.household_id=e.household_id and l.amount=e.amount
   and regexp_replace(lower(l.title),'[^a-z0-9]','','g')=regexp_replace(lower(e.title),'[^a-z0-9]','','g')
   and abs(l.charge_date-e.due_date)<=40
  where e.status<>'cancelled' and (e.credit_state<>'none' or e.card_id is not null)
),
-- L. Parcelas do modelo antigo (card_purchases) ainda pendentes
l as (
  select 'L. Parcelas do modelo antigo de cartão ainda pendentes' v,'baixa' g,
    count(*)||' parcelas · '||sum(e.amount-e.paid_amount)||' em aberto' d, string_agg(e.id::text,', ')
  from financial_events e where e.card_id is not null and e.status='pending'
  having count(*)>0
),
-- M. Obrigações de cartão vencidas e não lançadas
m as (
  select 'M. Obrigação de cartão vencida e não lançada' v,'média' g,
    o.title||' · '||to_char(o.due_date,'DD/MM/YYYY')||' · '||o.amount||case when o.generation_error<>'' then ' · erro: '||o.generation_error else '' end d, o.id::text
  from cc_obligations o where o.state='pending' and o.due_date<(now() at time zone 'America/Fortaleza')::date
),
-- N. Transferências agendadas vencidas e não confirmadas
n as (
  select 'N. Transferência agendada vencida e não confirmada' v,'baixa' g,
    to_char(t.due_date,'DD/MM/YYYY')||' · '||t.amount d, t.id::text
  from scheduled_transfers t where t.status='pending' and t.due_date<(now() at time zone 'America/Fortaleza')::date
),
-- O. Cartões no modelo antigo (fora do módulo novo)
o as (
  select 'O. Cartão no modelo antigo (module_version<>2)' v,'baixa' g, c.name d, c.id::text
  from credit_cards c where c.module_version<>2
)
select * from a union all select * from b union all select * from c union all select * from d
union all select * from e union all select * from f union all select * from g union all select * from h
union all select * from i union all select * from j union all select * from k union all select * from l
union all select * from m union all select * from n union all select * from o
order by 1,3;
