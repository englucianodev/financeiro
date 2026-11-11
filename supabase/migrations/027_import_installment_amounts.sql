-- 027 · Parcelas com os valores exatos do PDF.
-- ADITIVA: só funções. Não altera dados ao ser aplicada. Pré-requisito: 023 a 026.
-- O banco (Itaú/Azul) costuma pôr o centavo de diferença na 1ª parcela (ex.: 91,39 + 3 × 91,37).
-- A importação passa a aceitar "amounts" por linha: o valor de cada parcela, desta até a última,
-- lido em "Compras parceladas - próximas faturas". Assim a parcela do mês seguinte bate no centavo
-- e é reconhecida como já lançada, sem duplicar.

create or replace function public.cc_import_normalize(p_data jsonb) returns jsonb language sql immutable as $$
 -- Para linhas com "amounts", o caminho anterior recebe total = parcela × quantidade (para validar a parcela atual)
 -- e o total real fica em "real_total". A transformação é determinística: repetir o pedido gera o mesmo conteúdo.
 select case when jsonb_typeof(p_data->'rows') is distinct from 'array' then p_data else
  jsonb_set(p_data,'{rows}',(select coalesce(jsonb_agg(case when jsonb_typeof(r->'amounts')='array' and r->>'decision'='new' and r->>'kind'='purchase'
     then r||jsonb_build_object('real_total',r->'total_amount','total_amount',round((r->>'amount')::numeric*(r->>'count')::int,2))
     else r end order by n),'[]'::jsonb) from jsonb_array_elements(p_data->'rows') with ordinality t(r,n))) end
$$;
revoke all on function public.cc_import_normalize(jsonb) from public,anon,authenticated;

alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v26;
revoke all on function public.cc_action_v26(uuid,uuid,text,jsonb) from public,anon,authenticated;

create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare v_data jsonb; result jsonb; imp cc_imports%rowtype; r jsonb; rec jsonb; n int; pid uuid; amounts jsonb; i int; v numeric; first_inst int; cnt int; real_total numeric; invoice_ids uuid[];
begin
 if p_action<>'import_statement' or p_data is null or nullif(p_data->>'cycle','') is null
    or not exists(select 1 from jsonb_array_elements(case when jsonb_typeof(p_data->'rows')='array' then p_data->'rows' else '[]' end) x where jsonb_typeof(x->'amounts')='array') then
  return cc_action_v26(p_id,p_household,p_action,p_data);
 end if;
 v_data:=cc_import_normalize(p_data);
 if exists(select 1 from cc_requests where id=p_id) then return cc_action_v26(p_id,p_household,p_action,v_data);end if; -- repetição idempotente
 result:=cc_action_v26(p_id,p_household,p_action,v_data);
 select * into imp from cc_imports where id=(result->>'import_id')::uuid;
 for r,n in select value,ordinality from jsonb_array_elements(v_data->'rows') with ordinality loop
  continue when jsonb_typeof(r->'amounts') is distinct from 'array' or r->>'decision' is distinct from 'new' or r->>'kind' is distinct from 'purchase';
  rec:=imp.summary->'rows'->(n-1)::int; pid:=nullif(rec->>'purchase_id','')::uuid; continue when pid is null;
  amounts:=r->'amounts'; first_inst:=(r->>'installment')::int; cnt:=(r->>'count')::int; real_total:=nullif(r->>'real_total','')::numeric;
  if jsonb_array_length(amounts)<>cnt-first_inst+1 then raise exception 'Valores das parcelas incompletos: %',left(r->>'description',60);end if;
  if (amounts->>0)::numeric<>(r->>'amount')::numeric then raise exception 'A primeira parcela informada não confere: %',left(r->>'description',60);end if;
  for i in first_inst..cnt loop
   v:=(amounts->>(i-first_inst))::numeric;
   if v is null or v<=0 or v<>round(v,2) or v>9000000000000 then raise exception 'Valor de parcela inválido: %',left(r->>'description',60);end if;
   update cc_lines set amount=v where purchase_id=pid and installment=i and line_type='principal';
  end loop;
  if real_total is null or real_total<(select sum(amount) from cc_lines where purchase_id=pid and line_type='principal') then
   real_total:=(select sum(amount) from cc_lines where purchase_id=pid and line_type='principal')+(r->>'amount')::numeric*(first_inst-1);
  end if;
  update cc_purchases set amount=real_total where id=pid;
  -- O manifesto do desfazer passa a conter os valores finais.
  update cc_import_items m set snapshot=to_jsonb(l) from cc_lines l where m.import_id=imp.id and m.table_name='cc_lines' and m.entity_id=l.id and l.purchase_id=pid;
  update cc_import_items m set snapshot=to_jsonb(p) from cc_purchases p where m.import_id=imp.id and m.table_name='cc_purchases' and m.entity_id=p.id and p.id=pid;
  select array_agg(distinct invoice_id) into invoice_ids from cc_lines where purchase_id=pid;
  update cc_invoices set revision=revision+1 where id=any(invoice_ids);
 end loop;
 return result;
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';
