-- Apply after 001, first in a development project. No existing financial data is removed.

create table public.household_invites(token_hash text primary key,household_id uuid not null references public.households,expires_at timestamptz not null,used_by uuid references auth.users);

alter table public.household_invites enable row level security;

create function public.create_invite(p_household uuid) returns text language plpgsql security definer set search_path=public,extensions as $$

declare token text;

begin

 if not public.is_household_member(p_household) then raise exception 'Sem permissão'; end if;

 perform 1 from public.households where id=p_household for update;

 if (select count(*) from public.household_members where household_id=p_household)>=2 then raise exception 'Família completa'; end if;

 token:=encode(gen_random_bytes(32),'hex');

 insert into public.household_invites values(encode(digest(token,'sha256'),'hex'),p_household,now()+interval '24 hours',null);return token;

end $$;

create or replace function public.join_household(p_code text,p_display_name text) returns void language plpgsql security definer set search_path=public,extensions as $$

declare invitation public.household_invites%rowtype;

begin

 if auth.uid() is null then raise exception 'Não autenticado'; end if;

 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));

 if exists(select 1 from public.household_members where user_id=auth.uid()) then raise exception 'Usuário já possui família'; end if;

 select * into invitation from public.household_invites where token_hash=encode(digest(p_code,'sha256'),'hex') for update;

 if not found or invitation.used_by is not null or invitation.expires_at<=now() then raise exception 'Convite inválido ou expirado'; end if;

 perform 1 from public.households where id=invitation.household_id for update;

 if (select count(*) from public.household_members where household_id=invitation.household_id)>=2 then raise exception 'Família completa'; end if;

 if length(trim(p_display_name)) not between 1 and 120 then raise exception 'Nome inválido'; end if;

 insert into public.household_members values(invitation.household_id,auth.uid(),trim(p_display_name));

 update public.household_invites set used_by=auth.uid() where token_hash=invitation.token_hash;

end $$;

create or replace function public.create_household(p_name text,p_display_name text) returns uuid language plpgsql security definer set search_path=public,extensions as $$

declare h uuid;

begin

 if auth.uid() is null then raise exception 'Não autenticado'; end if;

 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text,0));

 if exists(select 1 from public.household_members where user_id=auth.uid()) then raise exception 'Usuário já possui família'; end if;

 if length(trim(p_name)) not between 1 and 120 or length(trim(p_display_name)) not between 1 and 120 then raise exception 'Nome inválido'; end if;

 insert into public.households(name) values(trim(p_name)) returning id into h;

 insert into public.household_members values(h,auth.uid(),trim(p_display_name));return h;

end $$;

create table public.account_ledger(id uuid primary key default gen_random_uuid(),household_id uuid not null references public.households,account_id uuid not null references public.financial_accounts,amount numeric(16,2) not null,operation_key text not null,event_id uuid references public.financial_events,actor_id uuid references auth.users,occurred_at timestamptz not null default now(),unique(account_id,operation_key));

alter table public.account_ledger enable row level security;

create policy ledger_read on public.account_ledger for select to authenticated using(public.is_household_member(household_id));

insert into public.account_ledger(household_id,account_id,amount,operation_key) select household_id,id,balance,'opening' from public.financial_accounts;

-- Reconstruct known legacy postings before installing the balance trigger.
insert into public.account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id,occurred_at)
select household_id,account_id,case when kind='income' then amount else -amount end,'legacy-settle:'||id,id,created_by,coalesce(settled_at,created_at) from public.financial_events where status='settled';
insert into public.account_ledger(household_id,account_id,amount,operation_key,actor_id,occurred_at)
select household_id,from_account,-amount,'legacy-transfer:'||id,created_by,created_at from public.financial_transfers
union all select household_id,to_account,amount,'legacy-transfer:'||id,created_by,created_at from public.financial_transfers;
update public.account_ledger opening set amount=opening.amount-coalesce((select sum(posting.amount) from public.account_ledger posting where posting.account_id=opening.account_id and posting.operation_key<>'opening'),0) where opening.operation_key='opening';
create function public.post_ledger() returns trigger language plpgsql security definer set search_path=public,extensions as $$

begin

 update public.financial_accounts set balance=balance+new.amount where id=new.account_id and household_id=new.household_id;

 if not found then raise exception 'Conta inválida'; end if;return new;

end $$;

create trigger ledger_post after insert on public.account_ledger for each row execute function public.post_ledger();

create function public.open_account_ledger() returns trigger language plpgsql security definer set search_path=public,extensions as $$

begin

 update public.financial_accounts set balance=0 where id=new.id;

 insert into public.account_ledger(household_id,account_id,amount,operation_key,actor_id) values(new.household_id,new.id,new.balance,'opening',auth.uid());return new;

end $$;

create trigger account_open after insert on public.financial_accounts for each row execute function public.open_account_ledger();

create or replace function public.settle_event(p_event_id uuid,p_account_id uuid) returns void language plpgsql security definer set search_path=public,extensions as $$

declare ev public.financial_events%rowtype;

begin

 select * into ev from public.financial_events where id=p_event_id for update;

 if not found or not public.is_household_member(ev.household_id) then raise exception 'Sem permissão'; end if;

 if ev.status='settled' then return; end if;

 if ev.status<>'pending' then raise exception 'Lançamento cancelado'; end if;

 perform 1 from public.financial_accounts where id=p_account_id and household_id=ev.household_id and active for update;

 if not found then raise exception 'Conta inválida'; end if;

 insert into public.account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(ev.household_id,p_account_id,case when ev.kind='income' then ev.amount else -ev.amount end,'settle:'||ev.id,ev.id,auth.uid());

 update public.financial_events set account_id=p_account_id,status='settled',settled_at=now() where id=ev.id;

end $$;

create function public.reverse_event(p_event_id uuid) returns void language plpgsql security definer set search_path=public,extensions as $$

declare ev public.financial_events%rowtype;

begin

 select * into ev from public.financial_events where id=p_event_id for update;

 if not found or not public.is_household_member(ev.household_id) then raise exception 'Sem permissão'; end if;

 if ev.status='cancelled' then return; end if;

 if ev.status<>'settled' then raise exception 'Lançamento não confirmado'; end if;

 insert into public.account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(ev.household_id,ev.account_id,case when ev.kind='income' then -ev.amount else ev.amount end,'reverse:'||ev.id,ev.id,auth.uid());

 update public.financial_events set status='cancelled' where id=ev.id;

end $$;

revoke execute on function public.transfer_funds(uuid,uuid,numeric) from authenticated;

create function public.transfer_funds(p_from uuid,p_to uuid,p_amount numeric,p_key uuid) returns void language plpgsql security definer set search_path=public,extensions as $$

declare a public.financial_accounts%rowtype;b public.financial_accounts%rowtype;

begin

 if p_key is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_from=p_to then raise exception 'Transferência inválida'; end if;

 perform pg_advisory_xact_lock(hashtextextended(p_key::text,1));

 perform id from public.financial_accounts where id in(p_from,p_to) order by id for update;

 select * into a from public.financial_accounts where id=p_from;select * into b from public.financial_accounts where id=p_to;

 if a.id is null or b.id is null or a.household_id<>b.household_id or not public.is_household_member(a.household_id) or not a.active or not b.active then raise exception 'Contas inválidas'; end if;

 if exists(select 1 from public.account_ledger where operation_key='transfer:'||p_key) then

 if not exists(select 1 from public.account_ledger where operation_key='transfer:'||p_key and account_id=p_from and amount=-p_amount) or not exists(select 1 from public.account_ledger where operation_key='transfer:'||p_key and account_id=p_to and amount=p_amount) then raise exception 'Chave já utilizada'; end if;return;end if;

 insert into public.account_ledger(household_id,account_id,amount,operation_key,actor_id) values(a.household_id,p_from,-p_amount,'transfer:'||p_key,auth.uid()),(a.household_id,p_to,p_amount,'transfer:'||p_key,auth.uid());

 insert into public.financial_transfers(household_id,from_account,to_account,amount,created_by) values(a.household_id,p_from,p_to,p_amount,auth.uid());

end $$;

create function public.set_primary_account(p_account uuid) returns void language plpgsql security definer set search_path=public,extensions as $$

declare a public.financial_accounts%rowtype;

begin

 select * into a from public.financial_accounts where id=p_account;

 if not found or not public.is_household_member(a.household_id) or not a.active then raise exception 'Sem permissão'; end if;

 perform 1 from public.households where id=a.household_id for update;

 update public.financial_accounts set is_primary=false where household_id=a.household_id and owner_id=a.owner_id and is_primary;

 update public.financial_accounts set is_primary=true where id=p_account;

end $$;

revoke all on function public.create_invite(uuid),public.reverse_event(uuid),public.transfer_funds(uuid,uuid,numeric,uuid),public.set_primary_account(uuid),public.post_ledger(),public.open_account_ledger() from public;

grant execute on function public.create_invite(uuid),public.reverse_event(uuid),public.transfer_funds(uuid,uuid,numeric,uuid),public.set_primary_account(uuid) to authenticated;

-- Prevent forged settled events and invalid ownership on direct inserts.

drop policy events_insert on public.financial_events;

create policy events_insert on public.financial_events for insert to authenticated with check(

 public.is_household_member(household_id) and created_by=auth.uid() and status='pending' and settled_at is null

 and exists(select 1 from public.household_members m where m.household_id=financial_events.household_id and m.user_id=owner_id)

 and exists(select 1 from public.financial_accounts a where a.id=account_id and a.household_id=financial_events.household_id and a.active)

);

alter table public.financial_events add constraint event_title_valid check(length(trim(title)) between 1 and 200) not valid;

alter table public.financial_accounts add constraint account_name_valid check(length(trim(name)) between 1 and 120) not valid;

