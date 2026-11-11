-- IMPORTAÇÕES ÓRFÃS — SOMENTE LEITURA (não altera nada)
-- Funciona com ou sem as migrations 024/025 aplicadas.
-- Rode no SQL Editor e exporte o CSV. Colunas: secao | importacao | detalhe | ids
--
-- Como o app sabe que um arquivo "já foi importado": tabela cc_imports, chave cartão + hash SHA-256 do arquivo.
-- Sem a 024: qualquer registro bloqueia. Com a 024/025: só registros com status 'active' bloqueiam.
-- Ligação importação → lançamentos: cc_imports.summary->'rows'[i]->>'line_id' (desde a 020)
-- e, a partir da 024, também a tabela cc_import_items (compras, todas as parcelas e ajustes criados).

with
versao as (
  select '0. versão do banco' as secao, '' as importacao,
    'cc_import_items: '||coalesce(to_regclass('public.cc_import_items')::text,'NÃO EXISTE (024 não aplicada)')
    ||' | cc_action_v24: '||case when to_regprocedure('public.cc_action_v24(uuid,uuid,text,jsonb)') is null then 'não (025 não aplicada)' else 'sim (025 aplicada)' end as detalhe,
    '' as ids
),
imp as (
  select m.*, to_jsonb(m) as j, k.name as cartao, i.cycle, i.due_date
  from cc_imports m join credit_cards k on k.id=m.card_id join cc_invoices i on i.id=m.invoice_id
),
linhas_registro as ( -- lançamentos/compras gravados no resumo de cada importação
  select imp.id as import_id, r->>'decision' as decision, nullif(r->>'line_id','')::uuid as line_id, nullif(r->>'purchase_id','')::uuid as purchase_id
  from imp cross join lateral jsonb_array_elements(case when jsonb_typeof(imp.summary->'rows')='array' then imp.summary->'rows' else '[]' end) r
),
itens as ( -- manifesto da 024 (se existir), lido sem depender da tabela existir
  select imp.id as import_id,
    case when to_regclass('public.cc_import_items') is null then null else
      (xpath('/row/c/text()', query_to_xml(format(
        'select count(*) as c from cc_import_items m where m.import_id=%L and m.created and ((m.table_name=''cc_lines'' and exists(select 1 from cc_lines l where l.id=m.entity_id)) or (m.table_name=''cc_purchases'' and exists(select 1 from cc_purchases p where p.id=m.entity_id)))', imp.id), false, true, '')))[1]::text::int end as restantes_manifesto,
    case when to_regclass('public.cc_import_items') is null then null else
      (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from cc_import_items m where m.import_id=%L', imp.id), false, true, '')))[1]::text::int end as itens_manifesto
  from imp
),
resumo as (
  select imp.id, imp.cartao, imp.cycle, imp.due_date, imp.created_at, imp.file_name,
    coalesce(imp.j->>'status','(sem status: 024 não aplicada)') as status,
    coalesce(imp.j->>'provenance_version','0') as proveniencia,
    (select count(*) from linhas_registro r where r.import_id=imp.id and r.decision='new') as criados_no_resumo,
    (select count(*) from linhas_registro r join cc_lines l on l.id=r.line_id where r.import_id=imp.id and r.decision='new') as criados_que_restam,
    (select count(*) from cc_lines l where l.purchase_id in (select r.purchase_id from linhas_registro r where r.import_id=imp.id and r.purchase_id is not null)) as parcelas_restantes_por_compra,
    it.restantes_manifesto, it.itens_manifesto
  from imp join itens it on it.import_id=imp.id
),
a as (
  select '1. importações' as secao, r.id::text,
    r.cartao||' · fatura '||to_char(r.cycle,'MM/YYYY')||' (vence '||to_char(r.due_date,'DD/MM/YYYY')||') · importada '||to_char(r.created_at at time zone 'America/Fortaleza','DD/MM/YYYY HH24:MI')||' · '||r.file_name
    ||' · status '||r.status||' · proveniência '||r.proveniencia
    ||' · criados '||r.criados_no_resumo||' · restam '||greatest(r.criados_que_restam,r.parcelas_restantes_por_compra,coalesce(r.restantes_manifesto,0))
    ||case when greatest(r.criados_que_restam,r.parcelas_restantes_por_compra,coalesce(r.restantes_manifesto,0))=0 and r.status<>'undone' then '  >>> ÓRFÃ (bloqueia reimportar)' else '' end,
    ''
  from resumo r
),
-- 2. Parcelas futuras que sobraram: compra cuja parcela inicial (next_installment) foi apagada à mão.
b as (
  select '2. parcelas que sobraram (compra sem a parcela inicial)' as secao, '' ,
    k.name||' · '||p.title||' · '||p.installments||'x · compra '||to_char(p.charge_date,'DD/MM/YYYY')||' · restam '||count(l.id)||' parcela(s) somando '||coalesce(sum(l.amount),0)
    ||' em '||coalesce(string_agg(distinct to_char(i.cycle,'MM/YYYY'),', '),'-'),
    'compra '||p.id||' · linhas '||coalesce(string_agg(l.id::text,', '),'')
  from cc_purchases p join credit_cards k on k.id=p.card_id
  left join cc_lines l on l.purchase_id=p.id left join cc_invoices i on i.id=l.invoice_id
  group by k.name,p.id
  having not bool_or(l.installment=p.next_installment) or count(l.id)=0
),
-- 3. Ajustes de fatura e totais conciliados nas faturas das importações órfãs
c as (
  select '3. ajustes/totais nas faturas das órfãs' as secao, r.id::text,
    'fatura '||to_char(i.cycle,'MM/YYYY')||' · ajuste "'||l.title||'" '||l.amount, l.id::text
  from resumo r join cc_imports m on m.id=r.id join cc_invoices i on i.id=m.invoice_id join cc_lines l on l.invoice_id=i.id and l.line_type='adjustment'
  where greatest(r.criados_que_restam,r.parcelas_restantes_por_compra,coalesce(r.restantes_manifesto,0))=0
  union all
  select '3. ajustes/totais nas faturas das órfãs', r.id::text, 'fatura '||to_char(i.cycle,'MM/YYYY')||' · total conciliado gravado '||t.target, t.invoice_id::text
  from resumo r join cc_imports m on m.id=r.id join cc_invoices i on i.id=m.invoice_id join cc_invoice_targets t on t.invoice_id=i.id
  where greatest(r.criados_que_restam,r.parcelas_restantes_por_compra,coalesce(r.restantes_manifesto,0))=0
),
-- 4. Situação atual das faturas dessas importações (o total é sempre a soma das linhas existentes)
d as (
  select '4. fatura hoje' as secao, r.id::text,
    'fatura '||to_char(i.cycle,'MM/YYYY')||' · linhas '||count(l.id)||' · total '||coalesce(sum(l.amount),0)||' · pago '||coalesce(sum(l.paid),0)
    ||' · pagamentos ativos '||(select count(*) from cc_payments p where p.invoice_id=i.id and p.reversed_at is null), i.id::text
  from resumo r join cc_imports m on m.id=r.id join cc_invoices i on i.id=m.invoice_id left join cc_lines l on l.invoice_id=i.id
  group by r.id,i.id,i.cycle
)
select * from versao
union all select * from a
union all select * from b
union all select * from c
union all select * from d
order by 1,2,3;
