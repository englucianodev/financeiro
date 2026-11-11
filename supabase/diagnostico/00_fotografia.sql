-- FOTOGRAFIA DOS DADOS — SOMENTE LEITURA (não altera nada)
-- Rode no SQL Editor do Supabase ANTES e DEPOIS de cada etapa (e depois de aplicar migrations).
-- Exporte o resultado (botão "Download CSV") e guarde com a data no nome.
-- Se nada foi alterado, todas as linhas devem sair idênticas entre as duas execuções.

with tabelas as (
  select c.relname as tabela
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='r'
),
contagens as (
  select '1. registros' as secao, tabela as item,
    (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', tabela), false, true, '')))[1]::text as valor
  from tabelas
),
saldos as (
  select '2. saldo das contas' as secao,
    a.name||' ('||a.id||')' as item,
    'saldo='||a.balance||' | soma_ledger='||coalesce((select sum(l.amount) from public.account_ledger l where l.account_id=a.id),0) as valor
  from public.financial_accounts a
),
faturas as (
  select '3. faturas de cartão' as secao,
    c.name||' · '||to_char(i.cycle,'MM/YYYY')||' · vence '||to_char(i.due_date,'DD/MM/YYYY') as item,
    'linhas='||count(l.id)||' | total='||coalesce(sum(l.amount),0)||' | pago='||coalesce(sum(l.paid),0) as valor
  from public.cc_invoices i join public.credit_cards c on c.id=i.card_id
  left join public.cc_lines l on l.invoice_id=i.id
  group by c.name,i.cycle,i.due_date,i.id
  having count(l.id)>0
),
eventos as (
  select '4. lançamentos (financial_events)' as secao, status||' / '||kind as item,
    'qtd='||count(*)||' | valor='||sum(amount)||' | pago='||sum(paid_amount) as valor
  from public.financial_events group by status,kind
),
assinaturas as (
  select '5. assinatura (muda se qualquer registro mudar)' as secao, 'financial_events' as item,
    md5(coalesce(string_agg(id::text||amount||paid_amount||status||due_date||account_id, ',' order by id),'')) as valor
  from public.financial_events
  union all
  select '5. assinatura (muda se qualquer registro mudar)','account_ledger',
    md5(coalesce(string_agg(id::text||amount||account_id, ',' order by id),'')) from public.account_ledger
  union all
  select '5. assinatura (muda se qualquer registro mudar)','cc_lines',
    md5(coalesce(string_agg(id::text||amount||paid||invoice_id||coalesce(installment,0), ',' order by id),'')) from public.cc_lines
  union all
  select '5. assinatura (muda se qualquer registro mudar)','cc_purchases',
    md5(coalesce(string_agg(id::text||amount||installments||card_id, ',' order by id),'')) from public.cc_purchases
)
select * from contagens
union all select * from saldos
union all select * from faturas
union all select * from eventos
union all select * from assinaturas
order by 1,2;
