-- Additive modernization; preserves historical events and balances.
alter table public.financial_accounts add column color text not null default '#6366f1' check(color ~ '^#[0-9a-fA-F]{6}$');
create function public.set_account_color(p_account uuid,p_color text) returns void language plpgsql security definer set search_path=public as $$
begin
 if p_color is null or p_color !~ '^#[0-9a-fA-F]{6}$' then raise exception 'Cor inválida';end if;
 update financial_accounts set color=p_color where id=p_account and public.is_household_member(household_id);
 if not found then raise exception 'Sem permissão';end if;
end $$;
create function public.rename_member(p_name text) returns void language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or p_name is null or length(trim(p_name)) not between 1 and 120 or p_name like '%@%' then raise exception 'Informe seu nome';end if;
 update household_members set display_name=trim(p_name) where user_id=auth.uid();
end $$;
create table public.categories(id uuid primary key default gen_random_uuid(),household_id uuid not null references households,name text not null check(length(trim(name)) between 1 and 100),kind text not null check(kind in ('income','expense')),color text not null check(color ~ '^#[0-9a-fA-F]{6}$'),icon text not null check(icon in ('wallet','home','heart','car','shopping','briefcase')),active boolean not null default true,unique(household_id,kind,name));
alter table categories enable row level security;
create policy categories_read on categories for select to authenticated using(is_household_member(household_id));
create policy categories_add on categories for insert to authenticated with check(is_household_member(household_id));
create policy categories_edit on categories for update to authenticated using(is_household_member(household_id)) with check(is_household_member(household_id));
-- No delete policy. Deactivation preserves all historic category labels.
create table public.recurrence_requests(id uuid primary key,household_id uuid not null references households,parameters jsonb not null);
alter table recurrence_requests enable row level security;
create function public.schedule_events(p_id uuid,p_household uuid,p_owner uuid,p_account uuid,p_title text,p_amount numeric,p_due date,p_kind text,p_category text,p_variable boolean,p_unit text,p_every integer,p_end date,p_property uuid default null) returns void language plpgsql security definer set search_path=public as $$
declare params jsonb;previous recurrence_requests%rowtype;d date;anchor date;i integer:=0;last_date date;
begin
 if not is_household_member(p_household) or not exists(select 1 from household_members where household_id=p_household and user_id=p_owner) or not exists(select 1 from financial_accounts where id=p_account and household_id=p_household and active) then raise exception 'Sem permissão';end if;
 if p_id is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_title is null or length(trim(p_title)) not between 1 and 200 or p_due is null or p_kind is null or p_kind not in ('income','expense') or p_unit is null or p_unit not in ('once','days','months') or p_every is null or p_every not between 1 and 365 or p_category is null or length(p_category)>100 or p_variable is null or (p_end is not null and p_end<p_due) then raise exception 'Lançamento inválido';end if;
 params:=jsonb_build_array(p_household,p_owner,p_account,p_title,p_amount,p_due,p_kind,p_category,p_variable,p_unit,p_every,p_end,p_property);
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,8));
 select * into previous from recurrence_requests where id=p_id;
 if found then if previous.household_id<>p_household or previous.parameters<>params then raise exception 'Chave já utilizada';end if;return;end if;
 insert into recurrence_requests values(p_id,p_household,params);
 last_date:=coalesce(p_end,p_due+interval '1 year');
 if last_date>p_due+interval '5 years' then raise exception 'Limite de cinco anos';end if;
 loop
 if p_unit='months' then
 anchor:=(date_trunc('month',p_due)+make_interval(months=>i*p_every))::date;
 d:=anchor+least(extract(day from p_due)::int,extract(day from anchor+interval '1 month - 1 day')::int)-1;
 else d:=p_due+i*p_every;end if;
 exit when d>last_date;
 if i>=2000 then raise exception 'Muitas ocorrências';end if;
 insert into financial_events(household_id,created_by,owner_id,account_id,title,amount,due_date,kind,category,series_id,variable_amount,property_id) values(p_household,auth.uid(),p_owner,p_account,trim(p_title),p_amount,d,p_kind,p_category,p_id,p_variable,p_property);
 exit when p_unit='once';i:=i+1;
 end loop;
end $$;
create function public.edit_future(p_event uuid,p_amount numeric) returns void language plpgsql security definer set search_path=public as $$
declare e financial_events%rowtype;
begin
 select * into e from financial_events where id=p_event for update;
 if not found or not is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or e.series_id is null or e.card_id is not null then raise exception 'Série inválida';end if;
 update financial_events set amount=p_amount where household_id=e.household_id and series_id=e.series_id and due_date>=e.due_date and status='pending' and paid_amount=0;
end $$;
create function public.estimate_variable() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.variable_amount and new.series_id is not null and new.status='settled' and old.status<>'settled' then
 update financial_events set amount=new.amount where series_id=new.series_id and household_id=new.household_id and due_date>new.due_date and status='pending' and paid_amount=0;
 end if;return new;
end $$;
create trigger variable_estimate after update on financial_events for each row execute function estimate_variable();
alter table household_invites add column revoked boolean not null default false;
create policy invites_read on household_invites for select to authenticated using(is_household_member(household_id));
create function public.issue_invite(p_household uuid,p_code text,p_hours integer) returns text language plpgsql security definer set search_path=public,extensions as $$
declare code text;
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 if p_hours is null or p_hours not between 1 and 168 then raise exception 'Validade de 1 a 168 horas';end if;
 code:=case when coalesce(trim(p_code),'')='' then upper(encode(gen_random_bytes(32),'hex')) else upper(trim(p_code)) end;
 if code !~ '^[A-Z0-9-]{8,64}$' then raise exception 'Código deve ter de 8 a 64 letras, números ou hífen';end if;
 insert into household_invites(token_hash,household_id,expires_at) values(encode(digest(code,'sha256'),'hex'),p_household,now()+make_interval(hours=>p_hours));
 return code;
exception when unique_violation then raise exception 'Código já utilizado. Escolha outro';
end $$;
create function public.revoke_invite(p_hash text) returns void language plpgsql security definer set search_path=public as $$
begin
 update household_invites set revoked=true where token_hash=p_hash and is_household_member(household_id);
 if not found then raise exception 'Sem permissão';end if;
end $$;
-- Failed attempts must commit, so return false instead of raising for invalid codes.
create table public.invite_attempts(user_id uuid primary key references auth.users,window_start timestamptz not null,attempts integer not null);
alter table invite_attempts enable row level security;
create function public.accept_invite(p_code text,p_name text) returns boolean language plpgsql security definer set search_path=public,extensions as $$
declare invitation household_invites%rowtype;attempt invite_attempts%rowtype;
begin
 if auth.uid() is null then raise exception 'Não autenticado';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));
 if p_name is null or length(trim(p_name)) not between 1 and 120 or p_name like '%@%' then raise exception 'Informe seu nome';end if;
 if exists(select 1 from household_members where user_id=auth.uid()) then raise exception 'Usuário já possui família';end if;
 insert into invite_attempts values(auth.uid(),now(),0) on conflict do nothing;
 select * into attempt from invite_attempts where user_id=auth.uid() for update;
 if attempt.window_start<now()-interval '1 hour' then update invite_attempts set window_start=now(),attempts=0 where user_id=auth.uid();elsif attempt.attempts>=10 then return false;end if;
 update invite_attempts set attempts=attempts+1 where user_id=auth.uid();
 select * into invitation from household_invites where token_hash in(encode(digest(upper(trim(p_code)),'sha256'),'hex'),encode(digest(trim(p_code),'sha256'),'hex')) for update;
 if not found or invitation.used_by is not null or invitation.revoked or invitation.expires_at<=now() then return false;end if;
 perform 1 from households where id=invitation.household_id for update;
 insert into household_members values(invitation.household_id,auth.uid(),trim(p_name));
 update household_invites set used_by=auth.uid() where token_hash=invitation.token_hash;
 return true;
end $$;
-- Close legacy invite endpoints to prevent bypass of revocation/rate limits.
revoke execute on function public.join_household(text,text),public.create_invite(uuid) from authenticated;
revoke all on function public.set_account_color(uuid,text),public.rename_member(text),public.schedule_events(uuid,uuid,uuid,uuid,text,numeric,date,text,text,boolean,text,integer,date,uuid),public.edit_future(uuid,numeric),public.estimate_variable(),public.issue_invite(uuid,text,integer),public.revoke_invite(text),public.accept_invite(text,text) from public;
grant execute on function public.set_account_color(uuid,text),public.rename_member(text),public.schedule_events(uuid,uuid,uuid,uuid,text,numeric,date,text,text,boolean,text,integer,date,uuid),public.edit_future(uuid,numeric),public.issue_invite(uuid,text,integer),public.revoke_invite(text),public.accept_invite(text,text) to authenticated;
notify pgrst,'reload schema';
