create table public.card_pdf_passwords(user_id uuid not null references auth.users,card_id uuid not null references credit_cards,encrypted_password text not null,updated_at timestamptz not null default now(),primary key(user_id,card_id));
alter table public.card_pdf_passwords enable row level security;
revoke all on public.card_pdf_passwords from public,anon,authenticated;
do $$begin if exists(select 1 from pg_roles where rolname='service_role') then grant select,insert,update,delete on public.card_pdf_passwords to service_role;end if;end $$;
-- Password plaintext is encrypted exclusively in the server, never returned to clients.
alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v21;
revoke all on function public.cc_action_v21(uuid,uuid,text,jsonb) from public,anon,authenticated;
create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare c credit_cards%rowtype;i uuid;original cc_purchases%rowtype;v numeric;d date;prior cc_requests%rowtype;lid uuid;description text;
begin
 if p_action='import_statement' and is_household_member(p_household) and exists(select 1 from jsonb_array_elements(p_data->'rows') r join cc_lines l on l.card_id=coalesce((p_data->>'card_id')::uuid,(select card_id from cc_invoices where id=(p_data->>'invoice_id')::uuid)) and l.line_type='refund' and l.charge_date=(r->>'date')::date and l.amount=(r->>'amount')::numeric and lower(trim(l.title))=lower(trim(r->>'description')) where r->>'kind' in ('refund','credit') and r->>'decision'='new') then raise exception 'Estorno já existente: vincule a linha da importação ao registro';end if;
 if p_action<>'card_refund' then return cc_action_v21(p_id,p_household,p_action,p_data);end if;
 if not is_household_member(p_household) or p_id is null then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 select * into prior from cc_requests where id=p_id;
 if found then if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;return prior.result;end if;
 select * into c from credit_cards where id=(p_data->>'card_id')::uuid and household_id=p_household;
 if not found then raise exception 'Cartão inválido';end if;
 v:=(p_data->>'amount')::numeric;d:=(p_data->>'date')::date;description:=trim(p_data->>'description');
 if v is null or v='NaN'::numeric or v<=0 or v>9000000000000 or v<>round(v,2) or d is null or d>(now() at time zone 'America/Fortaleza')::date or coalesce(length(description),0) not between 1 and 200 then raise exception 'Estorno inválido';end if;
 if p_data->>'purchase_id' is not null then
  select * into original from cc_purchases where id=(p_data->>'purchase_id')::uuid and card_id=c.id for update;
  if not found then raise exception 'Compra inválida';end if;
  if v>original.amount+coalesce((select sum(amount) from cc_lines where purchase_id=original.id and line_type in ('refund','discount')),0) then raise exception 'Estornos acumulados superiores ao principal da compra';end if;
 end if;
 if exists(select 1 from cc_lines where card_id=c.id and line_type='refund' and charge_date=d and amount=-v and lower(trim(title))=lower(description) and purchase_id is not distinct from original.id) then raise exception 'Estorno já registrado; confira o histórico';end if;
 i:=cc_invoice(coalesce(c.parent_card_id,c.id),cc_cycle(d,(select closing_day from credit_cards where id=coalesce(c.parent_card_id,c.id))));
 insert into cc_lines(household_id,invoice_id,card_id,purchase_id,responsible_id,title,category,amount,line_type,charge_date,original_description) values(p_household,i,c.id,original.id,coalesce(original.responsible_id,c.owner_id),description,coalesce(original.category,'Estorno no cartão'),-v,'refund',d,description) returning id into lid;
 update cc_invoices set revision=revision+1 where id=i;
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,jsonb_build_object('line_id',lid),now());return jsonb_build_object('line_id',lid);
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';
