-- 029 · Excluir do histórico uma importação já desfeita.
-- ADITIVA: só função. Não altera dados ao ser aplicada. Pré-requisito: 019 a 028.
-- Só apaga o registro da importação (cc_imports) e o seu manifesto (cc_import_items) quando:
--   · a importação está com situação "desfeita" (status = 'undone');
--   · nenhum lançamento ou compra listado no manifesto existe mais;
--   · o pedido vem com confirmed = true.
-- Lançamentos, compras, faturas e saldos não são tocados. Um resumo do registro apagado
-- fica guardado em cc_requests (auditoria).

alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v28;
revoke all on function public.cc_action_v28(uuid,uuid,text,jsonb) from public,anon,authenticated;

create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare prior cc_requests%rowtype; imp cc_imports%rowtype; live int; items int; result jsonb;
begin
 if p_action<>'delete_import_history' then return cc_action_v28(p_id,p_household,p_action,p_data);end if;
 if p_id is null or p_data is null or not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));
 select * into prior from cc_requests where id=p_id;
 if found then
  if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;
  return prior.result;
 end if;
 if coalesce((p_data->>'confirmed')::boolean,false) is not true then raise exception 'Confirme a exclusão do histórico';end if;
 select * into imp from cc_imports where id=(p_data->>'import_id')::uuid and household_id=p_household for update;
 if not found then raise exception 'Importação indisponível';end if;
 if imp.status is distinct from 'undone' then raise exception 'Só importações desfeitas podem ser excluídas do histórico';end if;
 select count(*) into live from cc_import_items x where x.import_id=imp.id and (
  (x.table_name='cc_lines' and exists(select 1 from cc_lines l where l.id=x.entity_id)) or
  (x.table_name='cc_purchases' and exists(select 1 from cc_purchases p where p.id=x.entity_id)));
 if live>0 then raise exception 'Esta importação ainda tem lançamentos no app; desfaça-a antes de excluir';end if;
 delete from cc_import_items where import_id=imp.id;
 get diagnostics items=row_count;
 delete from cc_imports where id=imp.id;
 result:=jsonb_build_object('deleted',imp.id,'file_name',imp.file_name,'card_id',imp.card_id,'invoice_id',imp.invoice_id,
  'created_at',imp.created_at,'summary',imp.summary,'manifest_items',items);
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());
 return result;
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';
