-- Additive, after 019. All imports require explicit final confirmation.
alter table cc_lines drop constraint cc_lines_line_type_check;
alter table cc_lines add constraint cc_lines_line_type_check check(line_type in ('principal','fee','refund','discount','credit','adjustment'));
alter table cc_lines add column original_description text,add column bank_transaction_id text;
create unique index cc_bank_transaction_unique on cc_lines(card_id,bank_transaction_id) where bank_transaction_id is not null;
create table cc_imports(id uuid primary key,household_id uuid not null references households,card_id uuid not null references credit_cards,invoice_id uuid not null references cc_invoices,file_hash text not null check(file_hash ~ '^[a-f0-9]{64}$'),file_name text not null,actor_id uuid not null references auth.users,summary jsonb not null,created_at timestamptz not null default now(),unique(card_id,file_hash));
create table cc_invoice_targets(invoice_id uuid primary key references cc_invoices,household_id uuid not null references households,target numeric(16,2) not null,updated_at timestamptz not null default now());
create table cc_adjustment_reversals(line_id uuid primary key references cc_lines,household_id uuid not null references households,reversal_line_id uuid not null references cc_lines);
do $$declare t text;begin foreach t in array array['cc_imports','cc_invoice_targets','cc_adjustment_reversals'] loop
 execute format('alter table %I enable row level security',t);
 execute format('create policy member_read on %I for select to authenticated using(is_household_member(household_id))',t);
 execute format('grant select on %I to authenticated',t);
 execute format('create trigger cc_audit after insert or update on %I for each row execute function cc_audit_row()',t);
end loop;end $$;
create function cc_reconcile(p_invoice uuid,p_total numeric) returns uuid language plpgsql security definer set search_path=public as $$
declare i cc_invoices%rowtype;c credit_cards%rowtype;delta numeric;lid uuid;
begin
 select * into i from cc_invoices where id=p_invoice for update;select * into c from credit_cards where id=i.card_id;
 if not is_household_member(i.household_id) or p_total is null or p_total='NaN'::numeric or abs(p_total)>9000000000000 or p_total<>round(p_total,2) then raise exception 'Total inválido';end if;
 select p_total-coalesce(sum(amount),0) into delta from cc_lines where invoice_id=i.id;
 if delta<>0 then insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date) values(i.household_id,i.id,c.id,c.owner_id,case when delta>0 then 'Complemento de Fatura' else 'Redução de Fatura' end,'Ajuste de Fatura',delta,'adjustment',i.closing_date) returning id into lid;end if;
 update cc_invoices set revision=revision+1 where id=i.id;return lid;
end $$;
alter function cc_action(uuid,uuid,text,jsonb) rename to cc_action_v19;
revoke all on function cc_action_v19(uuid,uuid,text,jsonb),cc_reconcile(uuid,numeric) from public,anon,authenticated;
create function cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare i cc_invoices%rowtype;c credit_cards%rowtype;plastic credit_cards%rowtype;prior cc_requests%rowtype;row jsonb;pid uuid;lid uuid;old_target numeric;result jsonb;v numeric;original cc_lines%rowtype;n_new int:=0;n_link int:=0;n_skip int:=0;records jsonb:='[]';
begin
 if p_action not in ('import_statement','adjust_invoice','reverse_adjustment') then return cc_action_v19(p_id,p_household,p_action,p_data);end if;
 if not is_household_member(p_household) or p_id is null then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 select * into prior from cc_requests where id=p_id;
 if found then if prior.household_id<>p_household or prior.action<>p_action or prior.parameters<>p_data then raise exception 'Chave já utilizada';end if;return prior.result;end if;
 select * into i from cc_invoices where id=(p_data->>'invoice_id')::uuid and household_id=p_household for update;
 if not found or i.revision is distinct from (p_data->>'revision')::bigint then raise exception 'Fatura atualizada; revise novamente';end if;
 select * into c from credit_cards where id=i.card_id;
 if p_action='adjust_invoice' then
  lid:=cc_reconcile(i.id,(p_data->>'total')::numeric);
  insert into cc_invoice_targets values(i.id,p_household,(p_data->>'total')::numeric,now()) on conflict(invoice_id) do update set target=excluded.target,updated_at=now();
 elsif p_action='reverse_adjustment' then
  select * into original from cc_lines where id=(p_data->>'line_id')::uuid and invoice_id=i.id and line_type='adjustment';
  if not found or exists(select 1 from cc_adjustment_reversals where line_id=original.id or reversal_line_id=original.id) then raise exception 'Ajuste inválido ou já revertido';end if;
  insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,i.id,c.id,c.owner_id,'Reversão · '||original.title,'Ajuste de Fatura',-original.amount,'adjustment',i.closing_date) returning id into lid;
  insert into cc_adjustment_reversals values(original.id,p_household,lid);update cc_invoices set revision=revision+1 where id=i.id;
  insert into cc_invoice_targets values(i.id,p_household,(select sum(amount) from cc_lines where invoice_id=i.id),now()) on conflict(invoice_id) do update set target=excluded.target,updated_at=now();
 else
  select * into plastic from credit_cards where id=coalesce((p_data->>'card_id')::uuid,c.id) and household_id=p_household and coalesce(parent_card_id,id)=c.id;
  if not found then raise exception 'Cartão da importação inválido';end if;
  if p_data->>'confirmed' is distinct from 'true' or jsonb_typeof(p_data->'rows')<>'array' or jsonb_array_length(p_data->'rows') not between 1 and 1000 then raise exception 'Confirme a conferência dos lançamentos';end if;
  if exists(select 1 from cc_imports where card_id=plastic.id and file_hash=p_data->>'file_hash') then raise exception 'Arquivo já importado: consulte o histórico';end if;
  select target into old_target from cc_invoice_targets where invoice_id=i.id;
  if coalesce((p_data->>'keep_target')::boolean,false) and old_target is not null then perform cc_reconcile(i.id,old_target-coalesce((select sum((value->>'amount')::numeric) from jsonb_array_elements(p_data->'rows') where value->>'decision'='new'),0));end if;
  for row in select value from jsonb_array_elements(p_data->'rows') loop
   lid:=null;
   if row->>'decision'='skip' then n_skip:=n_skip+1;
   elsif row->>'decision'='link' then
    select * into original from cc_lines where id=(row->>'match_id')::uuid and household_id=p_household and card_id=plastic.id;
    if not found then raise exception 'Correspondência inválida';end if;lid:=original.id;n_link:=n_link+1;
   elsif row->>'decision'='new' then
    if row->>'kind'='payment' then raise exception 'Pagamento anterior não é compra; descarte ou vincule ao histórico';end if;
    v:=(row->>'amount')::numeric;
    if v is null or v='NaN'::numeric or v=0 or abs(v)>9000000000000 or v<>round(v,2) or length(trim(coalesce(row->>'description',''))) not between 1 and 200 or length(trim(coalesce(row->>'category',''))) not between 1 and 100 or (row->>'date')::date is null or (row->>'date')::date>(now() at time zone 'America/Fortaleza')::date then raise exception 'Linha incompleta ou inválida';end if;
    if row->>'kind'='purchase' and v>0 then
     if (row->>'total_amount')::numeric is null then raise exception 'Confirme o valor total do parcelamento';end if;
     pid:=cc_post_purchase(plastic.id,plastic.owner_id,row->>'description',row->>'category',(row->>'total_amount')::numeric,(row->>'date')::date,(row->>'count')::int,(row->>'installment')::int,i.cycle,null);
     select id into lid from cc_lines where purchase_id=pid and installment=(row->>'installment')::int;
     if (select amount from cc_lines where id=lid)<>v then raise exception 'Parcela não corresponde ao total confirmado';end if;
    elsif row->>'kind' in ('refund','fee','credit') then
     if (row->>'kind'='fee' and v<0) or (row->>'kind' in ('refund','credit') and v>0) then raise exception 'Sinal incompatível com o tipo';end if;
     insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,i.id,plastic.id,plastic.owner_id,row->>'description',row->>'category',v,case when row->>'kind'='fee' then 'fee' else 'refund' end,(row->>'date')::date) returning id into lid;
    else raise exception 'Tipo inválido';end if;
    update cc_lines set original_description=row->>'original',bank_transaction_id=nullif(row->>'bank_id','') where id=lid;n_new:=n_new+1;
   else raise exception 'Decida explicitamente cada linha';end if;
   records:=records||jsonb_build_array(row||jsonb_build_object('line_id',lid));
  end loop;
  if coalesce((p_data->>'keep_target')::boolean,false) then
   if old_target is null then raise exception 'Não há total conciliado anterior';end if;perform cc_reconcile(i.id,old_target);
  end if;
  update cc_invoices set revision=revision+1 where id=i.id;
  insert into cc_imports values(p_id,p_household,plastic.id,i.id,p_data->>'file_hash',left(p_data->>'file_name',200),auth.uid(),jsonb_build_object('identified',jsonb_array_length(p_data->'rows'),'imported',n_new,'linked',n_link,'discarded',n_skip,'rows',records,'metadata',p_data->'metadata'),now());
 end if;
 result:=jsonb_build_object('line_id',lid,'imported',n_new,'linked',n_link,'discarded',n_skip);
 insert into cc_requests values(p_id,p_household,auth.uid(),p_action,p_data,result,now());return result;
end $$;
revoke all on function cc_action(uuid,uuid,text,jsonb) from public,anon;
grant execute on function cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';

create function record_cc_import_error(p_household uuid,p_data jsonb) returns void language plpgsql security definer set search_path=public as $$
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 insert into cc_requests values(gen_random_uuid(),p_household,auth.uid(),'import_client_error',jsonb_build_object('file_name',left(p_data->>'file_name',200),'error',left(p_data->>'error',500)),'{}',now());
end $$;
revoke all on function record_cc_import_error(uuid,jsonb) from public,anon;
grant execute on function record_cc_import_error(uuid,jsonb) to authenticated;
