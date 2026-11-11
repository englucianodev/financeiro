-- 028 · Alterar a categoria de lançamentos do cartão.
-- ADITIVA: só função. Não altera dados ao ser aplicada. Pré-requisito: 019 a 027.
-- Muda apenas a categoria (sem valor, data, fatura ou pagamento). Não interfere em importação,
-- desfazer (que ignora categoria) nem em saldos.

alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v27;
revoke all on function public.cc_action_v27(uuid,uuid,text,jsonb) from public,anon,authenticated;

create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare prior cc_requests%rowtype; ln cc_lines%rowtype; v_category text; n int; result jsonb;
begin
 if p_action<>'set_category' then return cc_action_v27(p_id,p_household,p_action,p_data);end if;
 if p_id is null or p_data is null or not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));
 select * into prior from cc_requests where id=p_id;
 if found then
  if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;
  return prior.result;
 end if;
 select * into ln from cc_lines where id=(p_data->>'line_id')::uuid and household_id=p_household for update;
 if not found then raise exception 'Lançamento indisponível';end if;
 v_category:=trim(coalesce(p_data->>'category',''));
 if length(v_category) not between 1 and 100 then raise exception 'Escolha uma categoria';end if;
 if coalesce(p_data->>'scope','purchase')='purchase' and ln.purchase_id is not null then
  update cc_lines set category=v_category where purchase_id=ln.purchase_id and line_type='principal';
  get diagnostics n=row_count;
  update cc_purchases set category=v_category where id=ln.purchase_id;
 else
  update cc_lines set category=v_category where id=ln.id;n:=1;
 end if;
 update cc_invoices set revision=revision+1 where id in (select invoice_id from cc_lines where id=ln.id or (ln.purchase_id is not null and purchase_id=ln.purchase_id));
 result:=jsonb_build_object('updated',n,'category',v_category);
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());
 return result;
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';
