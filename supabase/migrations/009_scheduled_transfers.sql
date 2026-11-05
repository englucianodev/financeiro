create table public.scheduled_transfers(id uuid primary key,household_id uuid not null references households,from_account uuid not null,to_account uuid not null,amount numeric(16,2) not null check(amount>0 and amount<>'NaN'::numeric),due_date date not null,status text not null default 'pending' check(status in ('pending','settled')),foreign key(from_account,household_id) references financial_accounts(id,household_id),foreign key(to_account,household_id) references financial_accounts(id,household_id),check(from_account<>to_account));
alter table scheduled_transfers enable row level security;
create policy scheduled_read on scheduled_transfers for select to authenticated using(is_household_member(household_id));
create function public.schedule_transfer(p_id uuid,p_from uuid,p_to uuid,p_amount numeric,p_date date) returns void language plpgsql security definer set search_path=public as $$
declare h uuid;previous scheduled_transfers%rowtype;
begin
 select household_id into h from financial_accounts where id=p_from and active;
 if h is null or not is_household_member(h) or not exists(select 1 from financial_accounts where id=p_to and household_id=h and active) then raise exception 'Sem permissão';end if;
 if p_id is null or p_date is null or p_amount is null or p_amount<=0 or p_amount<>round(p_amount,2) or p_amount='NaN'::numeric then raise exception 'Transferência inválida';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,9));
 select * into previous from scheduled_transfers where id=p_id;
 if found then if previous.household_id<>h or previous.from_account<>p_from or previous.to_account<>p_to or previous.amount<>p_amount or previous.due_date<>p_date then raise exception 'Chave já utilizada';end if;return;end if;
 insert into scheduled_transfers(id,household_id,from_account,to_account,amount,due_date) values(p_id,h,p_from,p_to,p_amount,p_date);
end $$;
create function public.execute_transfer(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
declare t scheduled_transfers%rowtype;
begin
 select * into t from scheduled_transfers where id=p_id for update;
 if not found or not is_household_member(t.household_id) then raise exception 'Sem permissão';end if;
 if t.status='settled' then return;end if;
 if t.due_date>(now() at time zone 'America/Fortaleza')::date then raise exception 'Confirme somente na data prevista ou depois';end if;
 perform transfer_funds(t.from_account,t.to_account,t.amount,t.id);
 update scheduled_transfers set status='settled' where id=p_id;
end $$;
revoke all on function schedule_transfer(uuid,uuid,uuid,numeric,date),execute_transfer(uuid) from public;
grant execute on function schedule_transfer(uuid,uuid,uuid,numeric,date),execute_transfer(uuid) to authenticated;
notify pgrst,'reload schema';
