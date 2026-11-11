-- 026 · Desfazer importação de verdade.
-- ADITIVA: só funções (substitui a regra de impacto e acrescenta ações). Não altera nem apaga dados ao ser aplicada.
-- Pré-requisito: 023, 024 e 025.
-- O que muda:
--  * Desfazer localiza tudo pelo ID da importação (cc_import_items), nunca pela descrição.
--  * Renomear descrição/categoria depois de importar não bloqueia mais; só mudanças de valor, parcela, fatura ou cartão bloqueiam.
--  * Lançamentos apagados à mão são ignorados (não travam o desfazer do que sobrou).
--  * Fatura com pagamento: deixa desfazer com confirmação explícita. O pagamento continua registrado
--    (o dinheiro saiu da conta) e a fatura passa a mostrar crédito.
--  * Importação antiga (antes da 024): "adopt_legacy_import" usa os IDs gravados no resumo da própria importação.
--  * Arquivo já importado: se a importação anterior não tiver mais nenhum lançamento, ela é liberada automaticamente.
--  * "force_clear_import": tira do histórico ativo uma importação sem lançamentos (nada financeiro é apagado).

create or replace function public.cc_import_remaining(p_import uuid) returns integer language sql stable security definer set search_path=public as $$
 select (select count(*) from cc_import_items m where m.import_id=p_import and m.created
          and ((m.table_name='cc_lines' and exists(select 1 from cc_lines l where l.id=m.entity_id))
            or (m.table_name='cc_purchases' and exists(select 1 from cc_purchases p where p.id=m.entity_id))))::int
      + (select count(*) from cc_imports i cross join lateral jsonb_array_elements(case when jsonb_typeof(i.summary->'rows')='array' then i.summary->'rows' else '[]' end) r
          join cc_lines l on l.id=nullif(r->>'line_id','')::uuid
          where i.id=p_import and i.provenance_version<>1 and r->>'decision'='new')::int
$$;
revoke all on function public.cc_import_remaining(uuid) from public,anon,authenticated;

create or replace function public.cc_import_impact(p_import uuid) returns jsonb language plpgsql security definer set search_path=public as $$
declare imp cc_imports%rowtype; item cc_import_items%rowtype; actual jsonb; keys text[];
 reasons text[]:='{}'; warnings text[]:='{}'; invoices uuid[]; paid numeric; remaining int; adjustments jsonb;
begin
 select * into imp from cc_imports where id=p_import;
 if not found or not is_household_member(imp.household_id) then raise exception 'Sem permissão';end if;
 remaining:=cc_import_remaining(imp.id);
 if imp.status<>'active' then reasons:=array_append(reasons,'Importação já desfeita');end if;
 if imp.provenance_version<>1 then reasons:=array_append(reasons,'Importação antiga sem identificação dos lançamentos: toque em "Identificar lançamentos" para vinculá-los pelo registro da própria importação');end if;
 select coalesce(array_agg(value::uuid),'{}') into invoices from jsonb_array_elements_text(coalesce(imp.effects->'invoice_ids','[]'));
 for item in select * from cc_import_items where import_id=imp.id and created loop
  if item.table_name='cc_lines' then select to_jsonb(l) into actual from cc_lines l where id=item.entity_id;keys:=array['invoice_id','card_id','purchase_id','amount','line_type','installment'];
  else select to_jsonb(p) into actual from cc_purchases p where id=item.entity_id;keys:=array['card_id','amount','installments','next_installment'];end if;
  continue when actual is null; -- apagado à mão: não há o que desfazer
  if (select jsonb_object_agg(k,actual->k) from unnest(keys) k) is distinct from (select jsonb_object_agg(k,item.snapshot->k) from unnest(keys) k) then
   reasons:=array_append(reasons,'Valor, parcela, cartão ou fatura alterados depois de importar: '||coalesce(actual->>'title','(sem título)')||'. Desfaça essa alteração ou corrija o item individualmente.');
  end if;
 end loop;
 select coalesce(sum(a.amount),0) into paid from cc_allocations a join cc_payments p on p.id=a.payment_id and p.reversed_at is null
  join cc_import_items m on m.table_name='cc_lines' and m.entity_id=a.line_id and m.created and m.import_id=imp.id;
 if paid>0 then warnings:=array_append(warnings,'Há '||to_char(paid,'FM999G999G990D00')||' de pagamento aplicado a estes lançamentos. O pagamento continua registrado e a fatura ficará com crédito.');end if;
 if exists(select 1 from cc_import_items owner join cc_import_items other on other.table_name=owner.table_name and other.entity_id=owner.entity_id and other.import_id<>owner.import_id join cc_imports later on later.id=other.import_id and later.status='active' where owner.import_id=imp.id and owner.created) then reasons:=array_append(reasons,'Outra importação ativa usa lançamentos desta (parcela do mês seguinte). Desfaça primeiro a importação mais recente.');end if;
 if exists(select 1 from cc_imports other cross join lateral jsonb_array_elements(case when jsonb_typeof(other.summary->'rows')='array' then other.summary->'rows' else '[]' end) r join cc_import_items owned on owned.import_id=imp.id and owned.created and owned.table_name='cc_lines' and owned.entity_id::text=r->>'line_id' where other.id<>imp.id and other.status='active' and r->>'decision'='link') then reasons:=array_append(reasons,'Outra importação ativa vinculou lançamentos desta. Desfaça primeiro a importação mais recente.');end if;
 if exists(select 1 from cc_lines l join cc_import_items p on p.entity_id=l.purchase_id and p.table_name='cc_purchases' and p.created and p.import_id=imp.id where l.line_type<>'principal' and not exists(select 1 from cc_import_items m where m.import_id=imp.id and m.created and m.table_name='cc_lines' and m.entity_id=l.id)) then reasons:=array_append(reasons,'Compra importada recebeu estorno ou desconto depois. Desfaça o estorno primeiro.');end if;
 if exists(select 1 from cc_adjustment_reversals r join cc_import_items m on m.import_id=imp.id and m.created and m.table_name='cc_lines' and (m.entity_id=r.line_id or m.entity_id=r.reversal_line_id)) then reasons:=array_append(reasons,'O ajuste desta importação foi revertido manualmente. Desfaça a reversão primeiro.');end if;
 select coalesce(jsonb_agg(id order by id),'[]'::jsonb) into adjustments from cc_lines where invoice_id=any(invoices) and line_type='adjustment' and id not in (select entity_id from cc_import_items where import_id=imp.id and created)
  and not (to_jsonb(id::text) <@ coalesce(imp.effects->'adjustments_after','[]'::jsonb));
 if jsonb_array_length(adjustments)>0 then warnings:=array_append(warnings,'A fatura recebeu ajustes ou conciliação manual depois desta importação; eles não serão removidos. Confira o total depois.');end if;
 return jsonb_build_object('import_id',imp.id,'safe',cardinality(reasons)=0,'reasons',to_jsonb(reasons),'warnings',to_jsonb(warnings),
  'needs_confirmation',cardinality(warnings)>0,'remaining',remaining,'orphan',remaining=0 and imp.status='active','legacy',imp.provenance_version<>1,
  'created_lines',(select count(*) from cc_import_items m join cc_lines l on l.id=m.entity_id where m.import_id=imp.id and m.table_name='cc_lines' and m.created),
  'created_purchases',(select count(*) from cc_import_items m join cc_purchases p on p.id=m.entity_id where m.import_id=imp.id and m.table_name='cc_purchases' and m.created),
  'linked_lines',(select count(*) from cc_import_items where import_id=imp.id and table_name='cc_lines' and not created),
  'invoice_ids',to_jsonb(invoices),'paid',paid,'bank_delta',0);
end $$;
revoke all on function public.cc_import_impact(uuid) from public,anon,authenticated;

alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v25;
revoke all on function public.cc_action_v25(uuid,uuid,text,jsonb) from public,anon,authenticated;

create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare prior cc_requests%rowtype; imp cc_imports%rowtype; impact jsonb; result jsonb; invoice_ids uuid[]; r jsonb; lid uuid; pid uuid; released int:=0;
begin
 if p_action not in ('import_statement','preview_undo_import','undo_import','force_clear_import','adopt_legacy_import') then return cc_action_v25(p_id,p_household,p_action,p_data);end if;
 if p_id is null or p_data is null or not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 select * into prior from cc_requests where id=p_id;
 if found then
  if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;
  return prior.result;
 end if;

 if p_action='import_statement' then
  -- Mesmo arquivo de novo: libera importações anteriores que não têm mais nenhum lançamento.
  for imp in select * from cc_imports where household_id=p_household and card_id=(p_data->>'card_id')::uuid and file_hash=p_data->>'file_hash' and status='active' for update loop
   if cc_import_remaining(imp.id)=0 then
    update cc_imports set status='undone',undone_at=now(),undone_by=auth.uid(),effects=effects||jsonb_build_object('released_orphan',now()) where id=imp.id;
    released:=released+1;
   end if;
  end loop;
  result:=cc_action_v25(p_id,p_household,p_action,p_data);
  if released>0 then result:=result||jsonb_build_object('released_orphans',released);end if;
  return result;
 end if;

 select * into imp from cc_imports where id=(p_data->>'import_id')::uuid and household_id=p_household for update;
 if not found then raise exception 'Importação indisponível';end if;

 if p_action='preview_undo_import' then return cc_import_impact(imp.id);end if;

 if p_action='adopt_legacy_import' then
  -- Usa só os IDs que a própria importação gravou no seu resumo (line_id). Nada é inferido por descrição.
  if imp.status<>'active' or imp.provenance_version=1 then raise exception 'Importação já identificada ou desfeita';end if;
  for r in select value from jsonb_array_elements(case when jsonb_typeof(imp.summary->'rows')='array' then imp.summary->'rows' else '[]' end) loop
   lid:=nullif(r->>'line_id','')::uuid; continue when lid is null;
   if r->>'decision'='new' then
    select purchase_id into pid from cc_lines where id=lid;
    if found then
     insert into cc_import_items select imp.id,p_household,'cc_lines',l.id,true,to_jsonb(l) from cc_lines l where l.id=lid or (pid is not null and l.purchase_id=pid and l.line_type='principal') on conflict do nothing;
     if pid is not null then insert into cc_import_items select imp.id,p_household,'cc_purchases',p.id,true,to_jsonb(p) from cc_purchases p where p.id=pid on conflict do nothing;end if;
    end if;
   elsif r->>'decision'='link' then
    insert into cc_import_items select imp.id,p_household,'cc_lines',l.id,false,to_jsonb(l) from cc_lines l where l.id=lid on conflict do nothing;
   end if;
  end loop;
  select array_agg(distinct x) into invoice_ids from (select l.invoice_id x from cc_import_items m join cc_lines l on l.id=m.entity_id where m.import_id=imp.id and m.table_name='cc_lines' union select imp.invoice_id) s;
  update cc_imports set provenance_version=1,effects=effects||jsonb_build_object('invoice_ids',to_jsonb(invoice_ids),'adopted_legacy',now()) where id=imp.id;
  result:=cc_import_impact(imp.id);
  insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());return result;
 end if;

 if p_action='force_clear_import' then
  if imp.status<>'active' then raise exception 'Importação já desfeita';end if;
  if cc_import_remaining(imp.id)>0 then raise exception 'Esta importação ainda tem lançamentos no app. Use Desfazer importação.';end if;
  if p_data->>'confirmed' is distinct from 'true' then raise exception 'Confirme a limpeza do histórico';end if;
  update cc_imports set status='undone',undone_at=now(),undone_by=auth.uid(),effects=effects||jsonb_build_object('force_cleared',now()) where id=imp.id;
  result:=jsonb_build_object('import_id',imp.id,'status','undone','cleared',true);
  insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());return result;
 end if;

 -- undo_import
 impact:=cc_import_impact(imp.id);
 if not coalesce((impact->>'safe')::boolean,false) then raise exception '%',(select string_agg(value,' ') from jsonb_array_elements_text(impact->'reasons'));end if;
 if p_data->>'confirmed' is distinct from 'true' then raise exception 'Confirme o desfazimento integral da importação';end if;
 if coalesce((impact->>'needs_confirmation')::boolean,false) and p_data->>'confirm_warnings' is distinct from 'true' then raise exception 'Confirme: %',(select string_agg(value,' ') from jsonb_array_elements_text(impact->'warnings'));end if;
 select array_agg(distinct x) into invoice_ids from (select value::uuid x from jsonb_array_elements_text(coalesce(imp.effects->'invoice_ids','[]')) union select l.invoice_id from cc_import_items m join cc_lines l on l.id=m.entity_id where m.import_id=imp.id and m.created and m.table_name='cc_lines') s;
 perform id from cc_invoices where id=any(invoice_ids) order by id for update;
 -- Alocações de pagamento dos lançamentos removidos: guardadas na auditoria antes de sair.
 insert into cc_audit(household_id,actor_id,table_name,before_data,after_data)
  select p_household,auth.uid(),'cc_allocations',to_jsonb(a),jsonb_build_object('removed_by_undo_import',imp.id)
  from cc_allocations a join cc_import_items m on m.table_name='cc_lines' and m.entity_id=a.line_id and m.created and m.import_id=imp.id;
 delete from cc_allocations a using cc_import_items m where m.table_name='cc_lines' and m.entity_id=a.line_id and m.created and m.import_id=imp.id;
 delete from cc_lines l using cc_import_items m where m.import_id=imp.id and m.created and m.table_name='cc_lines' and m.entity_id=l.id;
 delete from cc_purchases p using cc_import_items m where m.import_id=imp.id and m.created and m.table_name='cc_purchases' and m.entity_id=p.id;
 update cc_invoices set revision=revision+1 where id=any(invoice_ids);
 update cc_imports set status='undone',undone_at=now(),undone_by=auth.uid() where id=imp.id;
 result:=impact||jsonb_build_object('status','undone');
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());return result;
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';
