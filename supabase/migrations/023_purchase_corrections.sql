-- Purchase corrections preserve line IDs, imports, payments, refunds and audit.
-- No existing financial data is changed merely by applying this migration.
alter table public.cc_purchases add column revision bigint not null default 0;
alter function public.cc_action(uuid,uuid,text,jsonb) rename to cc_action_v22;
revoke all on function public.cc_action_v22(uuid,uuid,text,jsonb) from public,anon,authenticated;

create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare
 prior cc_requests%rowtype; purchase cc_purchases%rowtype; card credit_cards%rowtype; root credit_cards%rowtype;
 ln cc_lines%rowtype; inv cc_invoices%rowtype; ids uuid[]; old_ids uuid[]; new_ids uuid[]:='{}';
 v numeric; part numeric; value numeric; used numeric; old_principal numeric; committed numeric;
 qty int; first_part int; n int; cy date; purchase_date date; v_invoice uuid; existing_id uuid;
 v_title text; v_category text; structural boolean; financial boolean; confirmed boolean;
 result jsonb; today date:=(now() at time zone 'America/Fortaleza')::date;
begin
 if p_action<>'edit_purchase' then return cc_action_v22(p_id,p_household,p_action,p_data);end if;
 if p_id is null or not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 select * into prior from cc_requests where id=p_id;
 if found then
  if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;
  return prior.result;
 end if;
 select * into purchase from cc_purchases where id=(p_data->>'purchase_id')::uuid and household_id=p_household for update;
 if not found or purchase.revision is distinct from (p_data->>'revision')::bigint then raise exception 'Compra atualizada; recarregue e revise';end if;
 select * into card from credit_cards where id=(p_data->>'card_id')::uuid and household_id=p_household;
 if not found then raise exception 'Cartão inválido';end if;
 select * into root from credit_cards where id=coalesce(card.parent_card_id,card.id) for update;
 v:=(p_data->>'amount')::numeric;qty:=(p_data->>'installments')::int;first_part:=(p_data->>'next_installment')::int;
 cy:=(p_data->>'first_cycle')::date;purchase_date:=(p_data->>'date')::date;
 v_title:=trim(p_data->>'title');v_category:=trim(p_data->>'category');confirmed:=coalesce((p_data->>'confirm_reconciled')::boolean,false);
 if v is null or v='NaN'::numeric or v<=0 or v>9000000000000 or v<>round(v,2)
  or qty is null or qty not between 1 and 120 or first_part is null or first_part not between 1 and qty or v*100<qty
  or purchase_date is null or purchase_date>today or cy is null or cy<>date_trunc('month',cy)::date
  or coalesce(length(v_title),0) not between 1 and 200 or coalesce(length(v_category),0) not between 1 and 100 then raise exception 'Compra inválida';end if;
 select array_agg(distinct l.invoice_id) into old_ids from cc_lines l where l.purchase_id=purchase.id;
 -- Dates explicitly refer to the first remaining installment, not an invented past history.
 select * into inv from cc_invoices where id=(select l.invoice_id from cc_lines l where l.purchase_id=purchase.id and l.line_type='principal' and l.installment is not null order by l.installment limit 1);
 structural:=purchase.card_id<>card.id or purchase.installments<>qty or purchase.next_installment<>first_part or inv.cycle is distinct from cy;
 financial:=structural or purchase.amount<>v or purchase.charge_date<>purchase_date;
 if financial and cy<cc_cycle(purchase_date,root.closing_day) then raise exception 'Fatura anterior ao ciclo da compra';end if;
 if financial and (card.card_status<>'active' or root.card_status<>'active') then raise exception 'Cartão indisponível';end if;
 if financial and exists(select 1 from cc_lines l where l.purchase_id=purchase.id and (l.paid<>0 or exists(select 1 from cc_allocations a where a.line_id=l.id))) then
  raise exception 'Compra com histórico de pagamento: alteração financeira bloqueada; descrição e categoria podem ser corrigidas';
 end if;
 -- Refund/discount links remain in their historical invoices; cross-card moves would detach the credit.
 if purchase.card_id<>card.id and exists(select 1 from cc_lines where purchase_id=purchase.id and line_type in ('refund','discount')) then
  raise exception 'Compra com estorno ou desconto deve preservar o cartão vinculado';
 end if;
 if financial then
 for n in 0..(qty-first_part) loop
  v_invoice:=cc_invoice(root.id,(cy+make_interval(months=>n))::date);
  new_ids:=array_append(new_ids,v_invoice);
 end loop;
 else new_ids:=coalesce(old_ids,'{}');end if;
 select array_agg(distinct x) into ids from unnest(coalesce(old_ids,'{}')||new_ids) x;
 perform id from cc_invoices where id=any(ids) order by id for update;
 for inv in select * from cc_invoices where id=any(ids) loop
  -- Newly created invoices have no prior revision. Existing ones require the caller's snapshot.
  if inv.revision<>0 or inv.id=any(coalesce(old_ids,'{}')) then
   if (p_data->'invoice_revisions'->>inv.id::text)::bigint is distinct from inv.revision then raise exception 'Fatura atualizada; recarregue e revise';end if;
  end if;
  if financial and exists(select 1 from cc_payments where invoice_id=inv.id) then raise exception 'Fatura com histórico de pagamento: alteração financeira bloqueada';end if;
  if (inv.closing_date<=today or exists(select 1 from cc_payments where invoice_id=inv.id) or exists(select 1 from cc_invoice_targets where invoice_id=inv.id) or exists(select 1 from cc_imports where invoice_id=inv.id)) and not confirmed then
   raise exception 'Confirme a alteração de faturas fechadas ou conciliadas';
  end if;
 end loop;
 part:=trunc(v/qty,2);committed:=v-part*(first_part-1);
 if committed+coalesce((select sum(amount) from cc_lines where purchase_id=purchase.id and line_type in ('refund','discount')),0)<0 then raise exception 'Total inferior aos estornos e descontos existentes';end if;
 if financial then
  select coalesce(sum(l.amount-l.paid) filter(where l.line_type<>'fee'),0) into used from cc_lines l join credit_cards c on c.id=l.card_id where coalesce(c.parent_card_id,c.id)=root.id;
  select coalesce(sum(l.amount-l.paid),0) into old_principal from cc_lines l join credit_cards c on c.id=l.card_id where l.purchase_id=purchase.id and l.line_type='principal' and coalesce(c.parent_card_id,c.id)=root.id;
  used:=used+coalesce((select sum(e.amount-e.paid_amount) from financial_events e join credit_cards c on c.id=e.card_id where coalesce(c.parent_card_id,c.id)=root.id and e.status='pending'),0);
  if greatest(0,used-old_principal+committed)>root.credit_limit then raise exception 'Limite disponível insuficiente';end if;
 end if;
 if financial then
  -- Keep the same physical IDs in sequence; retired principal rows become audited zero rows.
  -- Imports and allocation foreign keys never dangle, and no historical row is deleted.
  select array_agg(l.id order by l.installment,l.id) into old_ids from cc_lines l where l.purchase_id=purchase.id and l.line_type='principal' and l.installment is not null;
  update cc_lines set installment=null where purchase_id=purchase.id and line_type='principal';
  for n in 0..(qty-first_part) loop
   value:=case when first_part+n=qty then v-part*(qty-1) else part end;
   existing_id:=old_ids[n+1];
   if existing_id is null then
    insert into cc_lines(household_id,invoice_id,card_id,purchase_id,responsible_id,title,category,amount,line_type,installment,charge_date)
     values(p_household,new_ids[n+1],card.id,purchase.id,purchase.responsible_id,v_title,v_category,value,'principal',first_part+n,purchase_date);
   else
    update cc_lines set invoice_id=new_ids[n+1],card_id=card.id,title=v_title,category=v_category,amount=value,installment=first_part+n,charge_date=purchase_date where id=existing_id;
   end if;
  end loop;
  update cc_lines set amount=0 where purchase_id=purchase.id and line_type='principal' and installment is null;
 else
  update cc_lines set title=v_title,category=v_category where purchase_id=purchase.id and line_type='principal';
 end if;
 update cc_purchases set card_id=card.id,title=v_title,category=v_category,amount=v,charge_date=purchase_date,installments=qty,next_installment=first_part,revision=revision+1 where id=purchase.id;
 update cc_invoices set revision=revision+1 where id=any(ids);
 -- Explicit confirmation invalidates the previous reconciliation total, retaining the new actual total.
 update cc_invoice_targets t set target=(select coalesce(sum(l.amount),0) from cc_lines l where l.invoice_id=t.invoice_id),updated_at=now() where t.invoice_id=any(ids);
 result:=jsonb_build_object('purchase_id',purchase.id);
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());
 return result;
end $$;
revoke all on function public.cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function public.cc_action(uuid,uuid,text,jsonb) to authenticated;
-- Audit reconciliation changes made by an explicitly confirmed correction.
create trigger cc_target_audit after insert or update on public.cc_invoice_targets for each row execute function public.cc_audit_row();
notify pgrst,'reload schema';
