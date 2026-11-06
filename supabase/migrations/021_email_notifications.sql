-- No email is sent by this migration. Users opt in after external setup.
create table notification_settings(household_id uuid primary key references households,enabled boolean not null default false,morning text not null default '08:00',evening text not null default '20:00',weekdays integer[] not null default '{1,2,3,4,5}',holidays date[] not null default '{}',skip_holidays boolean not null default true,timezone text not null default 'America/Fortaleza',recipients uuid[] not null default '{}',revision bigint not null default 0);
create table notification_deliveries(id uuid primary key default gen_random_uuid(),household_id uuid not null references households,user_id uuid not null references auth.users,local_date date not null,slot text not null,status text not null default 'processing',payload jsonb not null,provider_id text,error text,claimed_at timestamptz not null default now(),unique(household_id,user_id,local_date,slot));
alter table notification_settings enable row level security;alter table notification_deliveries enable row level security;
create policy member_read on notification_settings for select to authenticated using(is_household_member(household_id));
create policy member_read on notification_deliveries for select to authenticated using(is_household_member(household_id));
grant select on notification_settings,notification_deliveries to authenticated;
create function save_notification_settings(p_household uuid,p_data jsonb) returns void language plpgsql security definer set search_path=public as $$
declare ids uuid[];days integer[];tz text;rev bigint;
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_household::text,210));
 select revision into rev from notification_settings where household_id=p_household;
 if rev is not null and rev is distinct from (p_data->>'revision')::bigint then raise exception 'Configuração atualizada; recarregue';end if;
 select coalesce(array_agg(value::uuid),'{}') into ids from jsonb_array_elements_text(p_data->'recipients');
 select coalesce(array_agg(value::integer),'{}') into days from jsonb_array_elements_text(p_data->'weekdays');
 tz:=p_data->>'timezone';
 if not exists(select 1 from pg_timezone_names where name=tz) or coalesce(p_data->>'morning','')!~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or coalesce(p_data->>'evening','')!~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' or not(days<@array[0,1,2,3,4,5,6]) or exists(select 1 from unnest(ids) u where not exists(select 1 from household_members where household_id=p_household and user_id=u)) then raise exception 'Horário, dias ou destinatários inválidos';end if;
 insert into notification_settings values(p_household,(p_data->>'enabled')::boolean,p_data->>'morning',p_data->>'evening',days,array(select value::date from jsonb_array_elements_text(p_data->'holidays')),(p_data->>'skip_holidays')::boolean,tz,ids,coalesce(rev,0)+1) on conflict(household_id) do update set enabled=excluded.enabled,morning=excluded.morning,evening=excluded.evening,weekdays=excluded.weekdays,holidays=excluded.holidays,skip_holidays=excluded.skip_holidays,timezone=excluded.timezone,recipients=excluded.recipients,revision=excluded.revision;
end $$;
create function notification_snapshot(p_household uuid,p_date date) returns jsonb language sql security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') from (
 select e.id::text id,e.title,e.owner_id,e.amount-e.paid_amount amount,e.due_date from financial_events e where e.household_id=p_household and e.kind='expense' and e.status='pending' and e.credit_state='none' and e.card_id is null and e.due_date<=p_date
 union all select 'legacy:'||e.card_id||':'||e.due_date,'Fatura anterior · '||c.name,c.owner_id,sum(e.amount-e.paid_amount),e.due_date from financial_events e join credit_cards c on c.id=e.card_id where e.household_id=p_household and e.status='pending' and e.due_date<=p_date group by e.card_id,e.due_date,c.name,c.owner_id
 union all select i.id::text,'Fatura · '||c.name,c.owner_id,sum(l.amount-l.paid),i.due_date from cc_invoices i join credit_cards c on c.id=i.card_id join cc_lines l on l.invoice_id=i.id where i.household_id=p_household and i.due_date<=p_date group by i.id,c.name,c.owner_id having sum(l.amount-l.paid)>0
 union all select o.id::text,o.title||' · lançar manualmente no cartão',o.responsible_id,o.amount,o.due_date from cc_obligations o where o.household_id=p_household and o.mode='manual' and o.state='pending' and o.due_date<=p_date
 ) x;
$$;
create function notification_claim(p_household uuid,p_user uuid,p_date date,p_slot text,p_payload jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare row notification_deliveries%rowtype;
begin
 if not exists(select 1 from household_members where household_id=p_household and user_id=p_user) then return null;end if;
 insert into notification_deliveries(household_id,user_id,local_date,slot,payload) values(p_household,p_user,p_date,p_slot,p_payload) on conflict do nothing;
 select * into row from notification_deliveries where household_id=p_household and user_id=p_user and local_date=p_date and slot=p_slot for update;
 if row.status in ('sent','skipped') or (row.claimed_at>now()-interval '10 minutes' and row.payload<>p_payload) then return null;end if;
 -- Serialize concurrent workers: a fresh insert is claimed using the sent-at lease token.
 if row.status='processing' and row.provider_id='leased' and row.claimed_at>now()-interval '10 minutes' then return null;end if;
 update notification_deliveries set status='processing',provider_id='leased',claimed_at=now() where id=row.id;
 return jsonb_build_object('id',row.id,'payload',row.payload);
end $$;
revoke all on function save_notification_settings(uuid,jsonb),notification_snapshot(uuid,date),notification_claim(uuid,uuid,date,text,jsonb) from public,anon,authenticated;
grant execute on function save_notification_settings(uuid,jsonb) to authenticated;
do $$begin if exists(select 1 from pg_roles where rolname='service_role') then
 grant select,insert,update on notification_settings,notification_deliveries to service_role;
 grant execute on function notification_snapshot(uuid,date),notification_claim(uuid,uuid,date,text,jsonb) to service_role;
end if;end $$;
notify pgrst,'reload schema';
