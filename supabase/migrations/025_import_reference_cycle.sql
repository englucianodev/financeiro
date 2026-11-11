-- 025 · Importação com mês de referência explícito, total do PDF e ajuste desfazível.
-- ADITIVA: só acrescenta colunas e funções. Não altera nem apaga registros existentes.
-- Pré-requisito: 023 e 024 aplicadas (nesta ordem).
-- Pedidos antigos (sem o campo "cycle") continuam no caminho anterior (cc_action_v24).

alter table public.cc_imports
  add column if not exists reference_cycle date,
  add column if not exists bank text,
  add column if not exists statement_due date,
  add column if not exists statement_closing date,
  add column if not exists statement_total numeric(16,2),
  add column if not exists adjustment_line uuid;

-- Igual a cc_post_purchase, mas sem bloquear por limite: a fatura importada registra compras
-- que já aconteceram, e o limite cadastrado no app pode estar desatualizado.
-- Cartão arquivado continua bloqueado.
create function public.cc_post_imported_purchase(p_card uuid,p_responsible uuid,p_title text,p_category text,p_amount numeric,p_date date,p_count integer,p_next integer,p_first_cycle date)
returns uuid language plpgsql security definer set search_path=public as $$
declare c credit_cards%rowtype;r credit_cards%rowtype;pid uuid;cy date;iv uuid;part numeric;i integer;
begin
 select * into c from credit_cards where id=p_card;
 if not found or not is_household_member(c.household_id) or c.card_status='archived' then raise exception 'Cartão indisponível';end if;
 select * into r from credit_cards where id=coalesce(c.parent_card_id,c.id) for update;
 if r.card_status='archived' then raise exception 'Cartão principal indisponível';end if;
 if not exists(select 1 from household_members where household_id=c.household_id and user_id=p_responsible) then raise exception 'Responsável inválido';end if;
 if p_amount is null or p_amount='NaN'::numeric or p_amount<=0 or p_amount>9000000000000 or p_amount<>round(p_amount,2) or p_count is null or p_count not between 1 and 120 or p_next is null or p_next not between 1 and p_count or p_amount*100<p_count or p_date is null or p_date>(now() at time zone 'America/Fortaleza')::date or p_title is null or length(trim(p_title)) not between 1 and 200 or p_category is null or length(trim(p_category)) not between 1 and 100 or p_first_cycle is null then raise exception 'Compra inválida';end if;
 cy:=date_trunc('month',p_first_cycle)::date;
 part:=trunc(p_amount/p_count,2);
 insert into cc_purchases(household_id,card_id,responsible_id,title,category,amount,charge_date,installments,next_installment)
 values(c.household_id,c.id,p_responsible,trim(p_title),p_category,p_amount,p_date,p_count,p_next) returning id into pid;
 for i in p_next..p_count loop
  iv:=cc_invoice(r.id,(cy+make_interval(months=>i-p_next))::date);
  insert into cc_lines(household_id,invoice_id,card_id,purchase_id,responsible_id,title,category,amount,line_type,installment,charge_date)
  values(c.household_id,iv,c.id,pid,p_responsible,trim(p_title),p_category,case when i=p_count then p_amount-part*(p_count-1) else part end,'principal',i,p_date);
  update cc_invoices set revision=revision+1 where id=iv;
 end loop;
 return pid;
end $$;
revoke all on function public.cc_post_imported_purchase(uuid,uuid,text,text,numeric,date,integer,integer,date) from public,anon,authenticated;

alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v24;
revoke all on function public.cc_action_v24(uuid,uuid,text,jsonb) from public,anon,authenticated;

create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare prior cc_requests%rowtype; inv cc_invoices%rowtype; card credit_cards%rowtype; root credit_cards%rowtype; line cc_lines%rowtype;
 row jsonb; records jsonb:='[]'; result jsonb; target jsonb; after_targets jsonb:='{}';
 line_ids uuid[]:='{}'; purchase_ids uuid[]:='{}'; linked_ids uuid[]:='{}'; invoice_ids uuid[]; pid uuid; lid uuid; iid uuid; adj uuid;
 created_count int:=0; linked_count int:=0; skipped_count int:=0; v_amount numeric; imported_total numeric:=0;
 suspicious boolean; v_cycle date; v_due date; v_closing date; v_total numeric; v_limit date;
begin
 if p_action<>'import_statement' or p_data is null or nullif(p_data->>'cycle','') is null then
  return cc_action_v24(p_id,p_household,p_action,p_data);
 end if;
 if p_id is null or not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 select * into prior from cc_requests where id=p_id;
 if found then
  if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;
  return prior.result;
 end if;

 select * into card from credit_cards where id=(p_data->>'card_id')::uuid and household_id=p_household;
 if not found then raise exception 'Cartão da importação inválido';end if;
 select * into root from credit_cards where id=coalesce(card.parent_card_id,card.id);
 v_cycle:=date_trunc('month',(p_data->>'cycle')::date)::date;
 if v_cycle is null or v_cycle<date '2000-01-01' or v_cycle>(now() at time zone 'America/Fortaleza')::date+interval '1 year' then raise exception 'Mês de referência inválido';end if;
 v_due:=nullif(p_data->'statement'->>'due','')::date;
 v_closing:=nullif(p_data->'statement'->>'closing','')::date;
 v_total:=nullif(p_data->'statement'->>'total','')::numeric;
 if v_total is not null and (v_total='NaN'::numeric or abs(v_total)>9000000000000 or v_total<>round(v_total,2)) then raise exception 'Total do PDF inválido';end if;

 -- A fatura do mês escolhido: a mesma que a pessoa viu na revisão (revisão conferida) ou criada agora.
 if nullif(p_data->>'invoice_id','') is not null then
  select * into inv from cc_invoices where id=(p_data->>'invoice_id')::uuid and household_id=p_household and card_id=root.id for update;
  if not found or inv.cycle<>v_cycle then raise exception 'Fatura de referência não corresponde ao mês escolhido';end if;
  if inv.revision is distinct from (p_data->>'revision')::bigint then raise exception 'Fatura atualizada; revise novamente';end if;
 else
  iid:=cc_invoice(root.id,v_cycle);
  select * into inv from cc_invoices where id=iid for update;
 end if;

 if p_data->>'confirmed' is distinct from 'true' or jsonb_typeof(p_data->'rows') is distinct from 'array' then raise exception 'Confirme a conferência dos lançamentos';end if;
 if jsonb_array_length(p_data->'rows') not between 1 and 1000 then raise exception 'Quantidade de lançamentos inválida';end if;
 if exists(select 1 from cc_imports where card_id=card.id and file_hash=p_data->>'file_hash' and status='active') then raise exception 'Arquivo já importado: consulte o histórico';end if;

 insert into cc_imports(id,household_id,card_id,invoice_id,file_hash,file_name,actor_id,summary,provenance_version,reference_cycle,bank,statement_due,statement_closing,statement_total)
 values(p_id,p_household,card.id,inv.id,p_data->>'file_hash',left(p_data->>'file_name',200),auth.uid(),'{}',1,v_cycle,left(p_data->'statement'->>'bank',40),v_due,v_closing,v_total);

 -- Compras posteriores ao fechamento não pertencem a esta fatura. Vale o fechamento do PDF, quando houver.
 v_limit:=greatest(inv.closing_date,coalesce(v_closing,inv.closing_date));

 for row in select value from jsonb_array_elements(p_data->'rows') loop
  lid:=null;pid:=null;
  if row->>'decision'='skip' then skipped_count:=skipped_count+1;
  elsif row->>'decision'='link' then
   select * into line from cc_lines where id=(row->>'match_id')::uuid and household_id=p_household and card_id=card.id;
   if not found then raise exception 'Correspondência inválida';end if;
   lid:=line.id;linked_ids:=array_append(linked_ids,lid);linked_count:=linked_count+1;
  elsif row->>'decision'='new' then
   v_amount:=(row->>'amount')::numeric;
   if v_amount is null or v_amount='NaN'::numeric or v_amount=0 or abs(v_amount)>9000000000000 or v_amount<>round(v_amount,2) or length(trim(coalesce(row->>'description',''))) not between 1 and 200 or length(trim(coalesce(row->>'category',''))) not between 1 and 100 or (row->>'date')::date is null or (row->>'date')::date>(now() at time zone 'America/Fortaleza')::date then raise exception 'Linha incompleta ou inválida: %',left(row->>'description',60);end if;
   if nullif(row->>'bank_id','') is not null and exists(select 1 from cc_lines where card_id=card.id and bank_transaction_id=row->>'bank_id') then raise exception 'Identificador bancário já cadastrado: vincule ao lançamento existente';end if;
   suspicious:=exists(select 1 from cc_lines l where l.card_id=card.id and lower(trim(l.title))=lower(trim(row->>'description')) and l.charge_date=(row->>'date')::date and l.amount=v_amount and not(l.line_type='principal' and l.installment is null and l.amount=0));
   if suspicious and not coalesce((p_data->>'confirm_duplicates')::boolean,false) then raise exception 'Possível duplicidade: confirme os lançamentos semelhantes antes de importar';end if;
   if row->>'kind'='purchase' and v_amount>0 then
    if (row->>'total_amount')::numeric is null then raise exception 'Confirme o valor total original do parcelamento';end if;
    if coalesce((row->>'installment')::int,1)=1 and (row->>'date')::date>v_limit then raise exception 'Compra de % é posterior ao fechamento (%) da fatura escolhida',to_char((row->>'date')::date,'DD/MM/YYYY'),to_char(v_limit,'DD/MM/YYYY');end if;
    pid:=cc_post_imported_purchase(card.id,card.owner_id,row->>'description',row->>'category',(row->>'total_amount')::numeric,(row->>'date')::date,(row->>'count')::int,(row->>'installment')::int,inv.cycle);
    select id into lid from cc_lines where purchase_id=pid and installment=(row->>'installment')::int;
    if (select l.amount from cc_lines l where id=lid)<>v_amount then raise exception 'Parcela não corresponde ao total confirmado: %',left(row->>'description',60);end if;
    purchase_ids:=array_append(purchase_ids,pid);
    line_ids:=line_ids||array(select id from cc_lines where purchase_id=pid);
   elsif row->>'kind' in ('refund','fee','credit') or (row->>'kind'='purchase' and v_amount<0) then
    if (row->>'kind'='fee' and v_amount<0) or (row->>'kind' in ('refund','credit') and v_amount>0) then raise exception 'Sinal incompatível com o tipo';end if;
    insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date)
    values(p_household,inv.id,card.id,card.owner_id,row->>'description',row->>'category',v_amount,case when row->>'kind'='fee' then 'fee' else 'refund' end,(row->>'date')::date) returning id into lid;
    line_ids:=array_append(line_ids,lid);
   else raise exception 'Tipo inválido: pagamento anterior não é compra';end if;
   update cc_lines set original_description=row->>'original',bank_transaction_id=nullif(row->>'bank_id','') where id=lid;
   imported_total:=imported_total+v_amount;created_count:=created_count+1;
  else raise exception 'Decida explicitamente cada linha';end if;
  records:=records||jsonb_build_array(row||jsonb_build_object('line_id',lid,'purchase_id',pid));
 end loop;

 -- Ajuste opcional para o total impresso no PDF. Fica registrado como criado por esta
 -- importação e é removido junto ao desfazer.
 if coalesce((p_data->>'adjust_to_statement')::boolean,false) then
  if v_total is null then raise exception 'O PDF não informou o total da fatura';end if;
  adj:=cc_reconcile(inv.id,v_total);
  if adj is not null then line_ids:=array_append(line_ids,adj);end if;
 end if;

 select array_agg(distinct x) into invoice_ids from (select invoice_id x from cc_lines where id=any(line_ids) union select inv.id) affected;
 update cc_invoices set revision=revision+1 where id=any(invoice_ids);
 insert into cc_import_items select p_id,p_household,'cc_lines',l.id,true,to_jsonb(l) from cc_lines l where l.id=any(line_ids);
 insert into cc_import_items select p_id,p_household,'cc_purchases',p.id,true,to_jsonb(p) from cc_purchases p where p.id=any(purchase_ids);
 insert into cc_import_items select p_id,p_household,'cc_lines',l.id,false,to_jsonb(l) from cc_lines l where l.id=any(linked_ids) and not(l.id=any(line_ids));
 foreach iid in array invoice_ids loop
  select to_jsonb(t) into target from cc_invoice_targets t where invoice_id=iid;
  after_targets:=after_targets||jsonb_build_object(iid::text,target);
 end loop;
 update cc_imports set adjustment_line=adj,
  summary=jsonb_build_object('identified',jsonb_array_length(p_data->'rows'),'imported',created_count,'linked',linked_count,'discarded',skipped_count,'total',imported_total,'rows',records,'metadata',p_data->'metadata','statement_total',v_total,'adjustment',(select amount from cc_lines where id=adj)),
  effects=jsonb_build_object('invoice_ids',to_jsonb(invoice_ids),'target_before',null,'targets_after',after_targets,'adjustments_after',(select coalesce(jsonb_agg(id order by id),'[]'::jsonb) from cc_lines where invoice_id=any(invoice_ids) and line_type='adjustment'))
 where id=p_id;
 result:=jsonb_build_object('import_id',p_id,'invoice_id',inv.id,'cycle',inv.cycle,'imported',created_count,'linked',linked_count,'discarded',skipped_count,'adjustment',(select amount from cc_lines where id=adj));
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());
 return result;
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';
