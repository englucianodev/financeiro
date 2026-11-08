-- Reliable ownership for NEW imports only. Never infer ownership of legacy rows.
alter table public.cc_imports
 add column status text not null default 'active' check(status in ('active','undone')),
 add column provenance_version integer not null default 0,
 add column effects jsonb not null default '{}',
 add column undone_at timestamptz, add column undone_by uuid references auth.users;
alter table public.cc_imports drop constraint cc_imports_card_id_file_hash_key;
create unique index cc_active_import_file on public.cc_imports(card_id,file_hash) where status='active';
create table public.cc_import_items(
 import_id uuid not null references public.cc_imports,
 household_id uuid not null references public.households,
 table_name text not null check(table_name in ('cc_purchases','cc_lines')),
 entity_id uuid not null, created boolean not null, snapshot jsonb not null,
 primary key(import_id,table_name,entity_id)
);
create unique index cc_import_owner on public.cc_import_items(table_name,entity_id) where created;
alter table public.cc_import_items enable row level security;
create policy cc_import_items_read on public.cc_import_items for select to authenticated using(is_household_member(household_id));
revoke all on public.cc_import_items from public,anon,authenticated;
grant select on public.cc_import_items to authenticated;
create trigger cc_import_item_audit after insert or update on public.cc_import_items for each row execute function public.cc_audit_row();
create function public.cc_audit_deleted() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into cc_audit(household_id,actor_id,table_name,before_data,after_data) values(old.household_id,auth.uid(),tg_table_name,to_jsonb(old),null);
 return old;
end $$;
revoke all on function public.cc_audit_deleted() from public,anon,authenticated;
create trigger cc_import_delete_audit after delete on public.cc_lines for each row execute function public.cc_audit_deleted();
create trigger cc_import_delete_audit after delete on public.cc_purchases for each row execute function public.cc_audit_deleted();

-- Both the preview and the mutating operation use exactly these guards.
create function public.cc_import_impact(p_import uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare imp cc_imports%rowtype; item cc_import_items%rowtype; actual jsonb;
 reasons text[]:='{}'; invoices uuid[]; target jsonb; state record; adjustments jsonb; has_created boolean;
begin
 select * into imp from cc_imports where id=p_import;
 if not found or not is_household_member(imp.household_id) then raise exception 'Sem permissão';end if;
 if imp.status<>'active' then reasons:=array_append(reasons,'Importação já desfeita');end if;
 if imp.provenance_version<>1 then reasons:=array_append(reasons,'Importação antiga sem identificação confiável: revisão individual obrigatória; nenhuma exclusão por aproximação');end if;
 has_created:=exists(select 1 from cc_import_items where import_id=imp.id and created);
 select coalesce(array_agg(value::uuid),'{}') into invoices from jsonb_array_elements_text(coalesce(imp.effects->'invoice_ids','[]'));
 for item in select * from cc_import_items where import_id=imp.id and created loop
  if item.table_name='cc_lines' then select to_jsonb(l) into actual from cc_lines l where id=item.entity_id;
  else select to_jsonb(p) into actual from cc_purchases p where id=item.entity_id;end if;
  if actual is distinct from item.snapshot then reasons:=array_append(reasons,'Lançamento ou compra alterado após importar: '||item.entity_id);end if;
 end loop;
 if has_created and exists(select 1 from cc_payments where invoice_id=any(invoices)) then reasons:=array_append(reasons,'Fatura com histórico de pagamento, inclusive pagamentos posteriormente desfeitos');end if;
 if exists(select 1 from cc_allocations a join cc_import_items m on m.table_name='cc_lines' and m.entity_id=a.line_id and m.created where m.import_id=imp.id) then reasons:=array_append(reasons,'Parcelas com alocações de pagamento');end if;
 if exists(select 1 from cc_import_items owner join cc_import_items other on other.table_name=owner.table_name and other.entity_id=owner.entity_id and other.import_id<>owner.import_id join cc_imports later on later.id=other.import_id and later.status='active' where owner.import_id=imp.id and owner.created) then reasons:=array_append(reasons,'Lançamentos vinculados por outra importação ativa; revise/desfaça primeiro a importação dependente');end if;
 -- Legacy import links are also evidence of a dependency, never evidence of ownership.
 if exists(select 1 from cc_imports other cross join lateral jsonb_array_elements(case when jsonb_typeof(other.summary->'rows')='array' then other.summary->'rows' else '[]' end) r join cc_import_items owned on owned.import_id=imp.id and owned.created and owned.table_name='cc_lines' and owned.entity_id::text=r->>'line_id' where other.id<>imp.id and other.status='active') then reasons:=array_append(reasons,'Outra importação referencia os lançamentos deste arquivo');end if;
 if exists(select 1 from cc_lines l join cc_import_items p on p.entity_id=l.purchase_id and p.table_name='cc_purchases' and p.created and p.import_id=imp.id where not exists(select 1 from cc_import_items m where m.import_id=imp.id and m.created and m.table_name='cc_lines' and m.entity_id=l.id)) then reasons:=array_append(reasons,'Compra possui parcelas, estornos ou descontos posteriores não criados por esta importação');end if;
 if exists(select 1 from cc_adjustment_reversals r join cc_import_items m on m.import_id=imp.id and m.created and m.table_name='cc_lines' and (m.entity_id=r.line_id or m.entity_id=r.reversal_line_id)) then reasons:=array_append(reasons,'Ajuste possui reversão vinculada');end if;
 if has_created then
 select coalesce(jsonb_agg(id order by id),'[]'::jsonb) into adjustments from cc_lines where invoice_id=any(invoices) and line_type='adjustment';
 if adjustments is distinct from imp.effects->'adjustments_after' then reasons:=array_append(reasons,'Faturas com ajustes ou conciliações posteriores à importação');end if;
 for state in select key,value from jsonb_each(coalesce(imp.effects->'targets_after','{}')) loop
  select to_jsonb(t) into target from cc_invoice_targets t where invoice_id=state.key::uuid;
  if coalesce(target,'null'::jsonb) is distinct from state.value then reasons:=array_append(reasons,'Conciliação alterada após importar na fatura '||state.key);end if;
 end loop;
 end if;
 return jsonb_build_object('import_id',imp.id,'safe',cardinality(reasons)=0,'reasons',to_jsonb(reasons),
  'created_lines',(select count(*) from cc_import_items where import_id=imp.id and table_name='cc_lines' and created),
  'created_purchases',(select count(*) from cc_import_items where import_id=imp.id and table_name='cc_purchases' and created),
  'linked_lines',(select count(*) from cc_import_items where import_id=imp.id and table_name='cc_lines' and not created),
  'invoice_ids',to_jsonb(invoices),'bank_delta',0);
end $$;
revoke all on function public.cc_import_impact(uuid) from public,anon,authenticated;

alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v23;
revoke all on function public.cc_action_v23(uuid,uuid,text,jsonb) from public,anon,authenticated;
create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare prior cc_requests%rowtype; imp cc_imports%rowtype; inv cc_invoices%rowtype; card credit_cards%rowtype; line cc_lines%rowtype;
 row jsonb; records jsonb:='[]'; result jsonb; impact jsonb; before_target jsonb; after_targets jsonb:='{}'; target jsonb;
 line_ids uuid[]:='{}'; purchase_ids uuid[]:='{}'; linked_ids uuid[]:='{}'; invoice_ids uuid[]; pid uuid; lid uuid; iid uuid;
 created_count int:=0; linked_count int:=0; skipped_count int:=0; v_amount numeric; imported_total numeric:=0;
 suspicious boolean; editing cc_purchases%rowtype; source_cycle date;
begin
 if p_action not in ('import_statement','preview_undo_import','undo_import','edit_purchase') then return cc_action_v23(p_id,p_household,p_action,p_data);end if;
 if p_id is null or p_data is null or not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 select * into prior from cc_requests where id=p_id;
 if found then
  if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;return prior.result;
 end if;
 if p_action='edit_purchase' then
  select * into editing from cc_purchases where id=(p_data->>'purchase_id')::uuid and household_id=p_household;
  if not found then raise exception 'Compra indisponível';end if;
  select i.cycle into source_cycle from cc_lines l join cc_invoices i on i.id=l.invoice_id where l.purchase_id=editing.id and l.line_type='principal' and l.installment is not null order by l.installment limit 1;
  if source_cycle is distinct from (p_data->>'first_cycle')::date and not coalesce((p_data->>'confirm_reconciled')::boolean,false) then raise exception 'Confirme mover as parcelas de % para % e atualizar as faturas de origem e destino',to_char(source_cycle,'MM/YYYY'),to_char((p_data->>'first_cycle')::date,'MM/YYYY');end if;
  if exists(select 1 from cc_purchases p where p.household_id=p_household and p.id<>editing.id and p.card_id=(p_data->>'card_id')::uuid and lower(trim(p.title))=lower(trim(p_data->>'title')) and p.charge_date=(p_data->>'date')::date and p.amount=(p_data->>'amount')::numeric) and not coalesce((p_data->>'confirm_duplicates')::boolean,false) then raise exception 'Possível duplicidade: confirme a edição após revisar as compras semelhantes';end if;
  return cc_action_v23(p_id,p_household,p_action,p_data);
 end if;
 if p_action in ('preview_undo_import','undo_import') then
  select * into imp from cc_imports where id=(p_data->>'import_id')::uuid and household_id=p_household for update;
  if not found then raise exception 'Importação indisponível';end if;
  impact:=cc_import_impact(imp.id);
  if p_action='preview_undo_import' then return impact;end if;
  if not coalesce((impact->>'safe')::boolean,false) then raise exception '%',(select string_agg(value,'; ') from jsonb_array_elements_text(impact->'reasons'));end if;
  if p_data->>'confirmed' is distinct from 'true' then raise exception 'Confirme o desfazimento integral da importação';end if;
  select array_agg(value::uuid) into invoice_ids from jsonb_array_elements_text(imp.effects->'invoice_ids');
  perform id from cc_invoices where id=any(invoice_ids) order by id for update;
  -- Delete only UUIDs captured at creation; linked/preexisting/manual rows are never selected.
  delete from cc_lines l using cc_import_items m where m.import_id=imp.id and m.created and m.table_name='cc_lines' and m.entity_id=l.id;
  delete from cc_purchases p using cc_import_items m where m.import_id=imp.id and m.created and m.table_name='cc_purchases' and m.entity_id=p.id;
  -- Targets were not overwritten by import; removing its adjustment lines restores the prior sum.
  update cc_invoices set revision=revision+1 where id=any(invoice_ids);
  update cc_imports set status='undone',undone_at=now(),undone_by=auth.uid() where id=imp.id;
  result:=impact||jsonb_build_object('status','undone');
  insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());return result;
 end if;
 -- Import: every validation, generated installment and ownership snapshot is one transaction.
 select * into inv from cc_invoices where id=(p_data->>'invoice_id')::uuid and household_id=p_household for update;
 if not found or inv.revision is distinct from (p_data->>'revision')::bigint then raise exception 'Fatura atualizada; revise novamente';end if;
 select * into card from credit_cards where id=coalesce((p_data->>'card_id')::uuid,inv.card_id) and household_id=p_household and coalesce(parent_card_id,id)=inv.card_id;
 if not found then raise exception 'Cartão da importação inválido';end if;
 if p_data->>'confirmed' is distinct from 'true' or jsonb_typeof(p_data->'rows') is distinct from 'array' then raise exception 'Confirme a conferência dos lançamentos';end if;
 if jsonb_array_length(p_data->'rows') not between 1 and 1000 then raise exception 'Quantidade de lançamentos inválida';end if;
 if exists(select 1 from cc_imports where card_id=card.id and file_hash=p_data->>'file_hash' and status='active') then raise exception 'Arquivo já importado: consulte o histórico';end if;
 select to_jsonb(t) into before_target from cc_invoice_targets t where invoice_id=inv.id;
 insert into cc_imports(id,household_id,card_id,invoice_id,file_hash,file_name,actor_id,summary,provenance_version)
 values(p_id,p_household,card.id,inv.id,p_data->>'file_hash',left(p_data->>'file_name',200),auth.uid(),'{}',1);
 if coalesce((p_data->>'keep_target')::boolean,false) then
  if before_target is null then raise exception 'Não há total conciliado anterior';end if;
  lid:=cc_reconcile(inv.id,(before_target->>'target')::numeric-coalesce((select sum((r->>'amount')::numeric) from jsonb_array_elements(p_data->'rows') r where r->>'decision'='new'),0));
  if lid is not null then line_ids:=array_append(line_ids,lid);end if;
 end if;
 for row in select value from jsonb_array_elements(p_data->'rows') loop
  lid:=null;pid:=null;
  if row->>'decision'='skip' then skipped_count:=skipped_count+1;
  elsif row->>'decision'='link' then
   select * into line from cc_lines where id=(row->>'match_id')::uuid and household_id=p_household and card_id=card.id;
   if not found then raise exception 'Correspondência inválida';end if;
   lid:=line.id;linked_ids:=array_append(linked_ids,lid);linked_count:=linked_count+1;
  elsif row->>'decision'='new' then
   v_amount:=(row->>'amount')::numeric;
   if v_amount is null or v_amount='NaN'::numeric or v_amount=0 or abs(v_amount)>9000000000000 or v_amount<>round(v_amount,2) or length(trim(coalesce(row->>'description',''))) not between 1 and 200 or length(trim(coalesce(row->>'category',''))) not between 1 and 100 or (row->>'date')::date is null or (row->>'date')::date>(now() at time zone 'America/Fortaleza')::date then raise exception 'Linha incompleta ou inválida';end if;
   if nullif(row->>'bank_id','') is not null and exists(select 1 from cc_lines where card_id=card.id and bank_transaction_id=row->>'bank_id') then raise exception 'Identificador bancário já cadastrado: vincule ao lançamento existente';end if;
   suspicious:=exists(select 1 from cc_lines l where l.card_id=card.id and lower(trim(l.title))=lower(trim(row->>'description')) and l.charge_date=(row->>'date')::date and l.amount=(row->>'amount')::numeric and not(l.line_type='principal' and l.installment is null and l.amount=0));
   if suspicious and not coalesce((p_data->>'confirm_duplicates')::boolean,false) then raise exception 'Possível duplicidade: confirme os lançamentos semelhantes antes de importar';end if;
   if row->>'kind'='purchase' and v_amount>0 then
    if (row->>'total_amount')::numeric is null then raise exception 'Confirme o valor total original do parcelamento';end if;
    if inv.cycle<cc_cycle((row->>'date')::date,(select closing_day from credit_cards where id=inv.card_id)) then raise exception 'Fatura anterior ao ciclo da compra; revise a data e o período';end if;
    pid:=cc_post_purchase(card.id,card.owner_id,row->>'description',row->>'category',(row->>'total_amount')::numeric,(row->>'date')::date,(row->>'count')::int,(row->>'installment')::int,inv.cycle,null);
    select id into lid from cc_lines where purchase_id=pid and installment=(row->>'installment')::int;
    if (select l.amount from cc_lines l where id=lid)<>v_amount then raise exception 'Parcela não corresponde ao total confirmado';end if;
    purchase_ids:=array_append(purchase_ids,pid);
    line_ids:=line_ids||array(select id from cc_lines where purchase_id=pid);
   elsif row->>'kind' in ('refund','fee','credit') then
    if (row->>'kind'='fee' and v_amount<0) or (row->>'kind' in ('refund','credit') and v_amount>0) then raise exception 'Sinal incompatível com o tipo';end if;
    if row->>'kind' in ('refund','credit') and suspicious then raise exception 'Estorno já existente: vincule ao registro';end if;
    insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,inv.id,card.id,card.owner_id,row->>'description',row->>'category',v_amount,case when row->>'kind'='fee' then 'fee' else 'refund' end,(row->>'date')::date) returning id into lid;
    line_ids:=array_append(line_ids,lid);
   else raise exception 'Tipo inválido: pagamento anterior não é compra';end if;
   update cc_lines set original_description=row->>'original',bank_transaction_id=nullif(row->>'bank_id','') where id=lid;
   imported_total:=imported_total+v_amount;created_count:=created_count+1;
  else raise exception 'Decida explicitamente cada linha';end if;
  records:=records||jsonb_build_array(row||jsonb_build_object('line_id',lid,'purchase_id',pid));
 end loop;
 if coalesce((p_data->>'keep_target')::boolean,false) then
  lid:=cc_reconcile(inv.id,(before_target->>'target')::numeric);
  if lid is not null then line_ids:=array_append(line_ids,lid);end if;
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
 update cc_imports set summary=jsonb_build_object('identified',jsonb_array_length(p_data->'rows'),'imported',created_count,'linked',linked_count,'discarded',skipped_count,'total',imported_total,'rows',records,'metadata',p_data->'metadata'),effects=jsonb_build_object('invoice_ids',to_jsonb(invoice_ids),'target_before',before_target,'targets_after',after_targets,'adjustments_after',(select coalesce(jsonb_agg(id order by id),'[]'::jsonb) from cc_lines where invoice_id=any(invoice_ids) and line_type='adjustment')) where id=p_id;
 result:=jsonb_build_object('import_id',p_id,'imported',created_count,'linked',linked_count,'discarded',skipped_count);
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());return result;
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';
