-- Additive credit module. No historical rows are converted or removed.
alter table public.credit_cards
 add column issuer text not null default '', add column brand text not null default '',
 add column last_four text not null default '' check(last_four='' or last_four ~ '^[0-9]{4}$'),
 add column credit_limit numeric(16,2) not null default 0 check(credit_limit>=0 and credit_limit<>'NaN'::numeric),
 add column automatic_debit boolean not null default false,
 add column color text not null default '#765484' check(color ~ '^#[0-9a-fA-F]{6}$'),
 add column card_status text not null default 'active' check(card_status in ('active','blocked','archived')),
 add column parent_card_id uuid, add column module_version integer not null default 1,
 add column revision bigint not null default 0;
alter table public.credit_cards add constraint cc_parent_fk foreign key(parent_card_id,household_id) references public.credit_cards(id,household_id);

create table public.cc_requests(id uuid primary key,household_id uuid not null references households,actor_id uuid not null references auth.users,action text not null,parameters jsonb not null,result jsonb,created_at timestamptz not null default now());
create table public.cc_invoices(id uuid primary key default gen_random_uuid(),household_id uuid not null references households,card_id uuid not null,cycle date not null,closing_date date not null,due_date date not null,revision bigint not null default 0,unique(card_id,cycle),unique(id,household_id),foreign key(card_id,household_id) references credit_cards(id,household_id));
create table public.cc_recurrences(id uuid primary key,household_id uuid not null references households,card_id uuid not null,responsible_id uuid not null references auth.users,title text not null,category text not null,amount numeric(16,2) not null check(amount>0 and amount<>'NaN'::numeric),mode text not null check(mode in ('automatic','manual')),variable boolean not null default false,unit text not null check(unit in ('days','months')),every integer not null check(every between 1 and 365),start_date date not null,end_date date,state text not null default 'active' check(state in ('active','paused','ended')),revision bigint not null default 0,unique(id,household_id),foreign key(card_id,household_id) references credit_cards(id,household_id));
create table public.cc_obligations(id uuid primary key default gen_random_uuid(),household_id uuid not null references households,card_id uuid not null,responsible_id uuid not null references auth.users,title text not null,category text not null,amount numeric(16,2) not null check(amount>0 and amount<>'NaN'::numeric),due_date date not null,mode text not null check(mode in ('automatic','manual')),state text not null default 'pending' check(state in ('pending','posted','cancelled')),recurrence_id uuid,generation_error text not null default '',revision bigint not null default 0,unique(recurrence_id,due_date),unique(id,household_id),foreign key(card_id,household_id) references credit_cards(id,household_id),foreign key(recurrence_id,household_id) references cc_recurrences(id,household_id));
create table public.cc_purchases(id uuid primary key default gen_random_uuid(),household_id uuid not null references households,card_id uuid not null,responsible_id uuid not null references auth.users,title text not null,category text not null,amount numeric(16,2) not null,charge_date date not null,installments integer not null check(installments between 1 and 120),next_installment integer not null,obligation_id uuid unique,created_at timestamptz not null default now(),unique(id,household_id),foreign key(card_id,household_id) references credit_cards(id,household_id),foreign key(obligation_id,household_id) references cc_obligations(id,household_id));
create table public.cc_lines(id uuid primary key default gen_random_uuid(),household_id uuid not null references households,invoice_id uuid not null,card_id uuid not null,purchase_id uuid,responsible_id uuid not null references auth.users,title text not null,category text not null,amount numeric(16,2) not null check(amount<>'NaN'::numeric),paid numeric(16,2) not null default 0 check(paid>=0),line_type text not null check(line_type in ('principal','fee','refund','discount','credit')),installment integer,charge_date date not null,unique(purchase_id,installment),unique(id,household_id),foreign key(invoice_id,household_id) references cc_invoices(id,household_id),foreign key(card_id,household_id) references credit_cards(id,household_id),foreign key(purchase_id,household_id) references cc_purchases(id,household_id));
create table public.cc_payments(id uuid primary key,household_id uuid not null references households,invoice_id uuid not null,account_id uuid not null,amount numeric(16,2) not null,paid_date date not null,reversed_at timestamptz,unique(id,household_id),foreign key(invoice_id,household_id) references cc_invoices(id,household_id),foreign key(account_id,household_id) references financial_accounts(id,household_id));
create table public.cc_allocations(payment_id uuid not null,line_id uuid not null,household_id uuid not null,amount numeric(16,2) not null check(amount>0),primary key(payment_id,line_id),foreign key(payment_id,household_id) references cc_payments(id,household_id),foreign key(line_id,household_id) references cc_lines(id,household_id));
create index cc_lines_invoice on public.cc_lines(invoice_id);
create index cc_pending_obligations on public.cc_obligations(household_id,due_date) where state='pending';
create index cc_lines_card on public.cc_lines(card_id);

-- New tables are read-only to clients; all writes pass the transactional RPC.
do $$declare t text;begin
 foreach t in array array['cc_requests','cc_invoices','cc_recurrences','cc_obligations','cc_purchases','cc_lines','cc_payments','cc_allocations'] loop
  execute format('alter table public.%I enable row level security',t);
  execute format('create policy cc_read on public.%I for select to authenticated using(public.is_household_member(household_id))',t);
  execute format('grant select on public.%I to authenticated',t);
 end loop;
end $$;

-- Applies to future card writes only; invalid legacy relationships remain for diagnosis.
create function public.cc_validate_card() returns trigger language plpgsql security definer set search_path=public as $$
declare p credit_cards%rowtype;
begin
 if not exists(select 1 from household_members where household_id=new.household_id and user_id=new.owner_id) then raise exception 'Titular inválido';end if;
 if not exists(select 1 from financial_accounts where id=new.account_id and household_id=new.household_id and owner_id=new.owner_id and account_type<>'investment' and active) then raise exception 'Selecione uma conta ativa do titular';end if;
 if new.parent_card_id is not null then
  select * into p from credit_cards where id=new.parent_card_id and household_id=new.household_id;
  if not found or p.parent_card_id is not null or p.id=new.id then raise exception 'Cartão principal inválido';end if;
 end if;
 if tg_op='UPDATE' then
  new.revision:=old.revision+1;
  if new.parent_card_id is distinct from old.parent_card_id and (exists(select 1 from cc_lines where card_id=new.id) or exists(select 1 from financial_events where card_id=new.id)) then raise exception 'Cartão com histórico não pode mudar de grupo de fatura';end if;
  if new.owner_id<>old.owner_id and (exists(select 1 from cc_invoices where card_id=new.id) or exists(select 1 from cc_lines where card_id=new.id) or exists(select 1 from financial_events where card_id=new.id)) then raise exception 'Cartão com histórico deve preservar titularidade; cadastre outro cartão';end if;
 end if;
 return new;
end $$;
create trigger cc_card_validation before insert or update on public.credit_cards for each row execute function public.cc_validate_card();

create function public.cc_day(p_month date,p_day integer) returns date language sql immutable as $$select date_trunc('month',p_month)::date+least(p_day,extract(day from date_trunc('month',p_month)+interval '1 month - 1 day')::int)-1$$;
create function public.cc_cycle(p_date date,p_close integer) returns date language sql immutable as $$select (date_trunc('month',p_date)+case when p_date>=public.cc_day(p_date,p_close) then interval '1 month' else interval '0' end)::date$$;
create function public.cc_invoice(p_card uuid,p_cycle date) returns uuid language plpgsql security definer set search_path=public as $$
declare c credit_cards%rowtype;v uuid;d date;
begin
 select * into c from credit_cards where id=p_card;
 if not found or not is_household_member(c.household_id) or c.parent_card_id is not null then raise exception 'Cartão inválido';end if;
 d:=cc_day((p_cycle+case when c.due_day<=c.closing_day then interval '1 month' else interval '0' end)::date,c.due_day);
 insert into cc_invoices(household_id,card_id,cycle,closing_date,due_date) values(c.household_id,c.id,date_trunc('month',p_cycle)::date,cc_day(p_cycle,c.closing_day),d) on conflict(card_id,cycle) do nothing;
 select id into v from cc_invoices where card_id=c.id and cycle=date_trunc('month',p_cycle)::date;return v;
end $$;

create function public.cc_post_purchase(p_card uuid,p_responsible uuid,p_title text,p_category text,p_amount numeric,p_date date,p_count integer,p_next integer default 1,p_first_cycle date default null,p_obligation uuid default null) returns uuid language plpgsql security definer set search_path=public as $$
declare c credit_cards%rowtype;r credit_cards%rowtype;pid uuid;cy date;iv uuid;part numeric;v numeric;i integer;committed numeric;
begin
 select * into c from credit_cards where id=p_card;
 if not found or not is_household_member(c.household_id) or c.card_status<>'active' then raise exception 'Cartão indisponível';end if;
 select * into r from credit_cards where id=coalesce(c.parent_card_id,c.id) for update;
 if r.card_status<>'active' then raise exception 'Cartão principal indisponível';end if;
 if not exists(select 1 from household_members where household_id=c.household_id and user_id=p_responsible) then raise exception 'Responsável inválido';end if;
 if p_amount is null or p_amount='NaN'::numeric or p_amount<=0 or p_amount>9000000000000 or p_amount<>round(p_amount,2) or p_count is null or p_count not between 1 and 120 or p_next is null or p_next not between 1 and p_count or p_amount*100<p_count or p_date is null or p_date>(now() at time zone 'America/Fortaleza')::date or p_title is null or length(trim(p_title)) not between 1 and 200 or p_category is null or length(trim(p_category)) not between 1 and 100 then raise exception 'Compra inválida';end if;
 if p_next>1 and p_first_cycle is null then raise exception 'Informe a primeira fatura do parcelamento antigo';end if;
 cy:=coalesce(date_trunc('month',p_first_cycle)::date,cc_cycle(p_date,r.closing_day));
 part:=trunc(p_amount/p_count,2);committed:=p_amount-part*(p_next-1);
 -- New cards have an explicit limit; do not silently assume a limit for old cards.
 select greatest(coalesce(sum(case when l.line_type='fee' then 0 else l.amount-l.paid end),0),0) into v from cc_lines l join credit_cards k on k.id=l.card_id where coalesce(k.parent_card_id,k.id)=r.id;
 v:=v+coalesce((select sum(e.amount-e.paid_amount) from financial_events e join credit_cards k on k.id=e.card_id where coalesce(k.parent_card_id,k.id)=r.id and e.status='pending'),0);
 if v+committed>r.credit_limit then raise exception 'Limite disponível insuficiente';end if;
 insert into cc_purchases(household_id,card_id,responsible_id,title,category,amount,charge_date,installments,next_installment,obligation_id) values(c.household_id,c.id,p_responsible,trim(p_title),p_category,p_amount,p_date,p_count,p_next,p_obligation) returning id into pid;
 for i in p_next..p_count loop
  iv:=cc_invoice(r.id,(cy+make_interval(months=>i-p_next))::date);
  insert into cc_lines(household_id,invoice_id,card_id,purchase_id,responsible_id,title,category,amount,line_type,installment,charge_date) values(c.household_id,iv,c.id,pid,p_responsible,trim(p_title),p_category,case when i=p_count then p_amount-part*(p_count-1) else part end,'principal',i,p_date);
  update cc_invoices set revision=revision+1 where id=iv;
 end loop;return pid;
end $$;

create function public.cc_generate(p_household uuid,p_through date) returns void language plpgsql security definer set search_path=public as $$
declare r cc_recurrences%rowtype;o cc_obligations%rowtype;c credit_cards%rowtype;d date;i integer;cap date;cur date:=(now() at time zone 'America/Fortaleza')::date;
begin
 if not is_household_member(p_household) or p_through is null or p_through>cur+interval '2 years' then raise exception 'Horizonte inválido';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 for c in select * from credit_cards where household_id=p_household and parent_card_id is null and module_version=2 and card_status='active' loop
  d:=date_trunc('month',cur)::date;
  while d<=p_through loop perform cc_invoice(c.id,d);d:=(d+interval '1 month')::date;end loop;
 end loop;
 for r in select * from cc_recurrences where household_id=p_household and state='active' and card_id in (select id from credit_cards where card_status='active') order by id loop
  cap:=least(coalesce(r.end_date,p_through),p_through);i:=0;d:=r.start_date;
  while d<=cap loop
   if i>4000 then raise exception 'Muitas ocorrências';end if;
   insert into cc_obligations(household_id,card_id,responsible_id,title,category,amount,due_date,mode,recurrence_id) values(r.household_id,r.card_id,r.responsible_id,r.title,r.category,r.amount,d,r.mode,r.id) on conflict(recurrence_id,due_date) do nothing;
   i:=i+1;d:=case when r.unit='days' then r.start_date+i*r.every else cc_day((date_trunc('month',r.start_date)+make_interval(months=>i*r.every))::date,extract(day from r.start_date)::int) end;
  end loop;
 end loop;
 for o in select ob.* from cc_obligations ob join credit_cards plastic on plastic.id=ob.card_id left join cc_recurrences rec on rec.id=ob.recurrence_id where ob.household_id=p_household and ob.state='pending' and ob.mode='automatic' and ob.due_date<=cur and plastic.card_status='active' and (rec.id is null or rec.state='active') order by ob.due_date,ob.id for update of ob loop
  -- Over-limit or blocked automatic charges stay visible and pending; never disappear.
  begin
   perform cc_post_purchase(o.card_id,o.responsible_id,o.title,o.category,o.amount,o.due_date,1,1,null,o.id);
   update cc_obligations set state='posted',revision=revision+1 where id=o.id;
  exception when raise_exception then update cc_obligations set generation_error=sqlerrm where id=o.id and generation_error is distinct from sqlerrm;
  end;
 end loop;
end $$;

create function public.cc_action(p_id uuid,p_household uuid,p_action text,p_data jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare req cc_requests%rowtype;c credit_cards%rowtype;r credit_cards%rowtype;iv cc_invoices%rowtype;ob cc_obligations%rowtype;rec cc_recurrences%rowtype;pay cc_payments%rowtype;ln cc_lines%rowtype;a cc_allocations%rowtype;
 v_id uuid;root_id uuid;owner uuid;acct uuid;other uuid;v numeric;due numeric;portion numeric;rest numeric;discount numeric;qty integer;cur date:=(now() at time zone 'America/Fortaleza')::date;op_date date;cy date;result jsonb:='{}';expected bigint;old_data jsonb;
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 if p_id is null or p_data is null then raise exception 'Requisição inválida';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,191));
 select * into req from cc_requests where id=p_id;
 if found then
  if req.household_id<>p_household or req.action<>p_action or req.parameters<>p_data then raise exception 'Chave já utilizada';end if;return req.result;
 end if;
 -- Household-wide serialization covers shared limits, adjustments and payment reversals.
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,190));
 if p_action='save_card' then
  v_id:=coalesce((p_data->>'card_id')::uuid,p_id);select * into c from credit_cards where id=v_id for update;
  if found and (c.household_id<>p_household or (p_data->>'revision')::bigint is distinct from c.revision) then raise exception 'Cartão atualizado por outra operação';end if;
  owner:=(p_data->>'owner_id')::uuid;acct:=(p_data->>'account_id')::uuid;root_id:=(p_data->>'parent_card_id')::uuid;v:=(p_data->>'credit_limit')::numeric;
  if p_data->>'name' is null or length(trim(p_data->>'name')) not between 1 and 120 or v is null or v='NaN'::numeric or v<0 or v>9000000000000 or v<>round(v,2) or (p_data->>'closing_day')::int not between 1 and 31 or (p_data->>'due_day')::int not between 1 and 31 or coalesce(p_data->>'card_status','') not in ('active','blocked','archived') then raise exception 'Dados do cartão inválidos';end if;
  if c.id is null then
   insert into credit_cards(id,household_id,owner_id,account_id,name,closing_day,due_day,issuer,brand,last_four,credit_limit,automatic_debit,color,card_status,parent_card_id,module_version) values(v_id,p_household,owner,acct,trim(p_data->>'name'),(p_data->>'closing_day')::int,(p_data->>'due_day')::int,coalesce(p_data->>'issuer',''),coalesce(p_data->>'brand',''),coalesce(p_data->>'last_four',''),v,coalesce((p_data->>'automatic_debit')::boolean,false),coalesce(p_data->>'color','#765484'),p_data->>'card_status',root_id,2);
  else
   update credit_cards set owner_id=owner,account_id=acct,name=trim(p_data->>'name'),closing_day=(p_data->>'closing_day')::int,due_day=(p_data->>'due_day')::int,issuer=coalesce(p_data->>'issuer',''),brand=coalesce(p_data->>'brand',''),last_four=coalesce(p_data->>'last_four',''),credit_limit=v,automatic_debit=coalesce((p_data->>'automatic_debit')::boolean,false),color=coalesce(p_data->>'color','#765484'),card_status=p_data->>'card_status',parent_card_id=root_id,module_version=2 where id=v_id;
  end if;result:=jsonb_build_object('card_id',v_id);
 elsif p_action in ('purchase','obligation','recurrence') then
  select * into c from credit_cards where id=(p_data->>'card_id')::uuid and household_id=p_household;
  if not found or c.card_status<>'active' then raise exception 'Cartão indisponível';end if;
  owner:=(p_data->>'responsible_id')::uuid;v:=(p_data->>'amount')::numeric;op_date:=(p_data->>'date')::date;
  if not exists(select 1 from household_members where household_id=p_household and user_id=owner) or v is null or v='NaN'::numeric or v<=0 or v>9000000000000 or v<>round(v,2) or op_date is null or length(trim(coalesce(p_data->>'title',''))) not between 1 and 200 or length(trim(coalesce(p_data->>'category',''))) not between 1 and 100 then raise exception 'Lançamento inválido';end if;
  if p_action='purchase' then
   v_id:=cc_post_purchase(c.id,owner,p_data->>'title',p_data->>'category',v,op_date,(p_data->>'installments')::int,coalesce((p_data->>'next_installment')::int,1),(p_data->>'first_cycle')::date,null);
  elsif p_action='obligation' then
   insert into cc_obligations(household_id,card_id,responsible_id,title,category,amount,due_date,mode) values(p_household,c.id,owner,p_data->>'title',p_data->>'category',v,op_date,p_data->>'mode') returning id into v_id;
   perform cc_generate(p_household,cur);
  else
   if (p_data->>'end_date')::date<op_date then raise exception 'Término inválido';end if;
   insert into cc_recurrences(id,household_id,card_id,responsible_id,title,category,amount,mode,variable,unit,every,start_date,end_date) values(p_id,p_household,c.id,owner,p_data->>'title',p_data->>'category',v,p_data->>'mode',coalesce((p_data->>'variable')::boolean,false),p_data->>'unit',(p_data->>'every')::int,op_date,(p_data->>'end_date')::date) returning id into v_id;
   perform cc_generate(p_household,least(cur+interval '1 year',coalesce((p_data->>'end_date')::date,cur+interval '1 year'))::date);
  end if;result:=jsonb_build_object('id',v_id);
 elsif p_action in ('confirm_obligation','edit_obligation','cancel_obligation') then
  select * into ob from cc_obligations where id=(p_data->>'obligation_id')::uuid and household_id=p_household for update;
  if not found or ob.state<>'pending' or (p_data->>'revision')::bigint is distinct from ob.revision then raise exception 'Obrigação alterada; atualize a tela';end if;
  if p_action='confirm_obligation' then
   if ob.mode<>'manual' then raise exception 'Cobranças automáticas são registradas pela rotina';end if;
   op_date:=(p_data->>'date')::date;v:=coalesce((p_data->>'amount')::numeric,ob.amount);
   v_id:=cc_post_purchase(ob.card_id,ob.responsible_id,ob.title,ob.category,v,op_date,1,1,null,ob.id);
   update cc_obligations set state='posted',amount=v,revision=revision+1 where id=ob.id;result:=jsonb_build_object('purchase_id',v_id);
   update cc_recurrences set amount=v,revision=revision+1 where id=ob.recurrence_id and variable;
   update cc_obligations set amount=v,revision=revision+1 where recurrence_id=ob.recurrence_id and state='pending' and due_date>ob.due_date and exists(select 1 from cc_recurrences where id=ob.recurrence_id and variable);
  elsif p_action='cancel_obligation' then update cc_obligations set state='cancelled',revision=revision+1 where id=ob.id;
  else
   v:=(p_data->>'amount')::numeric;op_date:=(p_data->>'date')::date;
   if v is null or v='NaN'::numeric or v<=0 or v>9000000000000 or v<>round(v,2) or op_date is null then raise exception 'Valor ou data inválidos';end if;
   update cc_obligations set amount=v,due_date=op_date,revision=revision+1 where id=ob.id;
  end if;
 elsif p_action='edit_recurrence' then
  select * into rec from cc_recurrences where id=(p_data->>'recurrence_id')::uuid and household_id=p_household for update;
  if not found or (p_data->>'revision')::bigint is distinct from rec.revision then raise exception 'Recorrência atualizada; recarregue';end if;
  v:=(p_data->>'amount')::numeric;
  if v is null or v='NaN'::numeric or v<=0 or v>9000000000000 or v<>round(v,2) then raise exception 'Valor inválido';end if;
  if (p_data->>'end_date')::date<rec.start_date then raise exception 'Término inválido';end if;
  if rec.state='ended' and p_data->>'state'<>'ended' then raise exception 'Recorrência encerrada: cadastre uma nova regra';end if;
  if (p_data->>'unit' is not null and p_data->>'unit'<>rec.unit) or ((p_data->>'every')::int is not null and (p_data->>'every')::int<>rec.every) or ((p_data->>'start_date')::date is not null and (p_data->>'start_date')::date<>rec.start_date) then
   if p_data->>'state'<>'active' or (p_data->>'start_date')::date<cur then raise exception 'Nova periodicidade deve iniciar hoje ou no futuro, com estado ativo';end if;
   update cc_recurrences set state='ended',revision=revision+1 where id=rec.id;
   update cc_obligations set state='cancelled',revision=revision+1 where recurrence_id=rec.id and state='pending' and due_date>=cur;
   insert into cc_recurrences(id,household_id,card_id,responsible_id,title,category,amount,mode,variable,unit,every,start_date,end_date) values(p_id,p_household,rec.card_id,rec.responsible_id,rec.title,rec.category,v,rec.mode,rec.variable,coalesce(p_data->>'unit',rec.unit),coalesce((p_data->>'every')::int,rec.every),coalesce((p_data->>'start_date')::date,cur),(p_data->>'end_date')::date);
   perform cc_generate(p_household,(cur+interval '1 year')::date);
   result:=jsonb_build_object('recurrence_id',p_id);
   insert into cc_requests(id,household_id,actor_id,action,parameters,result) values(p_id,p_household,auth.uid(),p_action,p_data,result);return result;
  end if;
  -- Existing posted history stays immutable. Pending occurrences can be explicitly cancelled.
  update cc_recurrences set amount=v,state=p_data->>'state',end_date=(p_data->>'end_date')::date,revision=revision+1 where id=rec.id;
  update cc_obligations set amount=v,revision=revision+1 where recurrence_id=rec.id and state='pending';
  if p_data->>'state'='ended' or coalesce((p_data->>'cancel_pending')::boolean,false) then update cc_obligations set state='cancelled',revision=revision+1 where recurrence_id=rec.id and state='pending' and due_date>=cur;end if;
  perform cc_generate(p_household,(cur+interval '1 year')::date);
 elsif p_action in ('pay_invoice','fee','refund','anticipate','transfer_credit') then
  select * into iv from cc_invoices where id=(p_data->>'invoice_id')::uuid and household_id=p_household for update;
  if not found or (p_data->>'revision')::bigint is distinct from iv.revision then raise exception 'Fatura atualizada; recarregue';end if;
  select * into r from credit_cards where id=iv.card_id for update;
  v:=(p_data->>'amount')::numeric;op_date:=coalesce((p_data->>'date')::date,cur);
  if v is null or v='NaN'::numeric or v<=0 or v>9000000000000 or v<>round(v,2) or op_date>cur then raise exception 'Valor ou data inválidos';end if;
  select coalesce(sum(amount-paid),0) into due from cc_lines where invoice_id=iv.id;
  if p_action='pay_invoice' then
   acct:=coalesce((p_data->>'account_id')::uuid,r.account_id);
   if not exists(select 1 from financial_accounts where id=acct and household_id=p_household and owner_id=r.owner_id and account_type<>'investment' and active) then raise exception 'Selecione uma conta ativa do titular';end if;
   if v>due then raise exception 'Valor superior ao saldo da fatura';end if;
   insert into cc_payments(id,household_id,invoice_id,account_id,amount,paid_date) values(p_id,p_household,iv.id,acct,v,op_date);
   rest:=v;
   for ln in select * from cc_lines where invoice_id=iv.id and amount>paid order by (line_type='fee') desc,charge_date,id for update loop
    exit when rest=0;portion:=least(rest,ln.amount-ln.paid);
    insert into cc_allocations values(p_id,ln.id,p_household,portion);update cc_lines set paid=paid+portion where id=ln.id;rest:=rest-portion;
   end loop;
   insert into account_ledger(household_id,account_id,amount,operation_key,actor_id) values(p_household,acct,-v,'cc-pay:'||p_id,auth.uid());
  elsif p_action='fee' then
   insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,iv.id,r.id,r.owner_id,coalesce(nullif(trim(p_data->>'title'),''),'Juros / multa informados'),'Encargos',v,'fee',op_date);
  elsif p_action='refund' then
   select * into ln from cc_lines where id=(p_data->>'line_id')::uuid and household_id=p_household and line_type='principal' for update;
   if not found or not exists(select 1 from credit_cards where id=ln.card_id and coalesce(parent_card_id,id)=r.id) then raise exception 'Compra inválida';end if;
   if v>coalesce((select sum(amount) from cc_lines where purchase_id=ln.purchase_id and line_type in ('principal','refund','discount')),0) then raise exception 'Estorno superior ao principal disponível';end if;
   insert into cc_lines(household_id,invoice_id,card_id,purchase_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,iv.id,ln.card_id,ln.purchase_id,ln.responsible_id,'Estorno · '||ln.title,ln.category,-v,'refund',op_date);
  elsif p_action='anticipate' then
   select * into ln from cc_lines where id=(p_data->>'line_id')::uuid and household_id=p_household and line_type='principal' for update;
   if not found or ln.paid<>0 or ln.invoice_id=iv.id or not exists(select 1 from cc_invoices where id=ln.invoice_id and card_id=r.id and due_date>iv.due_date) then raise exception 'Parcela futura inválida';end if;
   if v<>ln.amount then raise exception 'Valor da parcela mudou';end if;
   discount:=coalesce((p_data->>'discount')::numeric,0);
   if discount='NaN'::numeric or discount<0 or discount>v or discount<>round(discount,2) then raise exception 'Desconto inválido';end if;
   update cc_lines set invoice_id=iv.id where id=ln.id;
   if discount>0 then insert into cc_lines(household_id,invoice_id,card_id,purchase_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,iv.id,ln.card_id,ln.purchase_id,ln.responsible_id,'Desconto por antecipação',ln.category,-discount,'discount',op_date);end if;
   update cc_invoices set revision=revision+1 where id=ln.invoice_id;
  else
   select * into ln from cc_lines where invoice_id=iv.id limit 1;
   other:=(p_data->>'target_invoice_id')::uuid;
   if v> -due or not exists(select 1 from cc_invoices where id=other and card_id=r.id and id<>iv.id) then raise exception 'Crédito ou destino inválido';end if;
   insert into cc_lines(household_id,invoice_id,card_id,responsible_id,title,category,amount,line_type,charge_date) values(p_household,iv.id,r.id,r.owner_id,'Crédito transferido','Crédito',v,'credit',op_date),(p_household,other,r.id,r.owner_id,'Crédito recebido','Crédito',-v,'credit',op_date);
   update cc_invoices set revision=revision+1 where id=other;
  end if;
  update cc_invoices set revision=revision+1 where id=iv.id;
 elsif p_action='undo_payment' then
  select * into pay from cc_payments where id=(p_data->>'payment_id')::uuid and household_id=p_household for update;
  if not found or pay.reversed_at is not null then raise exception 'Pagamento já desfeito';end if;
  select * into iv from cc_invoices where id=pay.invoice_id for update;
  for a in select * from cc_allocations where payment_id=pay.id loop update cc_lines set paid=paid-a.amount where id=a.line_id;end loop;
  insert into account_ledger(household_id,account_id,amount,operation_key,actor_id) values(p_household,pay.account_id,pay.amount,'cc-undo:'||pay.id,auth.uid());
  update cc_payments set reversed_at=now() where id=pay.id;update cc_invoices set revision=revision+1 where id=pay.invoice_id;
 else raise exception 'Operação inválida';end if;
 insert into cc_requests(id,household_id,actor_id,action,parameters,result) values(p_id,p_household,auth.uid(),p_action,p_data,result);return result;
end $$;

-- Internal helpers are not public endpoints.
revoke all on function public.cc_validate_card(),public.cc_invoice(uuid,date),public.cc_post_purchase(uuid,uuid,text,text,numeric,date,integer,integer,date,uuid),public.cc_generate(uuid,date),public.cc_action(uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.cc_generate(uuid,date),public.cc_action(uuid,uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';

-- Prevent new-module cards from bypassing consolidated invoices via the legacy endpoint.
alter function public.create_card_purchase(uuid,uuid,text,numeric,date,integer) rename to create_card_purchase_legacy;
revoke all on function public.create_card_purchase_legacy(uuid,uuid,text,numeric,date,integer) from public,anon,authenticated;
create function public.create_card_purchase(p_id uuid,p_card uuid,p_title text,p_amount numeric,p_date date,p_installments integer) returns void language plpgsql security definer set search_path=public as $$
begin
 if exists(select 1 from credit_cards where id=p_card and module_version=2) then raise exception 'Use Despesa no cartão no módulo de cartões';end if;
 perform create_card_purchase_legacy(p_id,p_card,p_title,p_amount,p_date,p_installments);
end $$;
revoke all on function public.create_card_purchase(uuid,uuid,text,numeric,date,integer) from public,anon;
grant execute on function public.create_card_purchase(uuid,uuid,text,numeric,date,integer) to authenticated;
notify pgrst,'reload schema';

-- Row-level audit for edits, cancellations, allocations and compensating actions.
create table public.cc_audit(id bigint generated always as identity primary key,household_id uuid not null references households,actor_id uuid,table_name text not null,before_data jsonb,after_data jsonb,occurred_at timestamptz not null default now());
alter table public.cc_audit enable row level security;
create policy cc_audit_read on public.cc_audit for select to authenticated using(is_household_member(household_id));
grant select on public.cc_audit to authenticated;
create function public.cc_audit_row() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into cc_audit(household_id,actor_id,table_name,before_data,after_data) values(new.household_id,auth.uid(),tg_table_name,case when tg_op='UPDATE' then to_jsonb(old) else null end,to_jsonb(new));return new;
end $$;
revoke all on function public.cc_audit_row() from public,anon,authenticated;
do $$declare t text;begin
 foreach t in array array['credit_cards','cc_invoices','cc_recurrences','cc_obligations','cc_purchases','cc_lines','cc_payments','cc_allocations'] loop
  execute format('create trigger cc_audit after insert or update on public.%I for each row execute function public.cc_audit_row()',t);
 end loop;
end $$;
notify pgrst,'reload schema';
