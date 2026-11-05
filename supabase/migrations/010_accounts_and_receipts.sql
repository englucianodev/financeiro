-- Additive account editing, owner validation and auditable automatic income.
alter table public.financial_accounts add column account_type text not null default 'checking' check(account_type in ('checking','recurring','investment'));
create table public.account_edits(id uuid primary key,household_id uuid not null references households,parameters jsonb not null);
alter table account_edits enable row level security;
create function public.save_account(p_id uuid,p_account uuid,p_name text,p_owner uuid,p_color text,p_primary boolean,p_type text,p_balance numeric,p_expected_balance numeric) returns void language plpgsql security definer set search_path=public as $$
declare a financial_accounts%rowtype;params jsonb;previous account_edits%rowtype;
begin
 select * into a from financial_accounts where id=p_account;
 if not found or not is_household_member(a.household_id) then raise exception 'Sem permissão';end if;
 perform 1 from households where id=a.household_id for update;
 select * into a from financial_accounts where id=p_account for update;
 if p_id is null or p_name is null or length(trim(p_name)) not between 1 and 120 or p_color is null or p_color !~ '^#[0-9a-fA-F]{6}$' or p_type is null or p_type not in ('checking','recurring','investment') or p_primary is null or p_balance is null or p_balance='NaN'::numeric or abs(p_balance)>9000000000000 or p_balance<>round(p_balance,2) or not exists(select 1 from household_members where household_id=a.household_id and user_id=p_owner) then raise exception 'Dados da conta inválidos';end if;
 params:=jsonb_build_array(p_account,p_name,p_owner,p_color,p_primary,p_type,p_balance,p_expected_balance);
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,10));
 select * into previous from account_edits where id=p_id;
 if found then if previous.household_id<>a.household_id or previous.parameters<>params then raise exception 'Chave já utilizada';end if;return;end if;
 if p_expected_balance is null or a.balance<>p_expected_balance then raise exception 'Saldo alterado. Atualize a conta antes de salvar';end if;
 if a.owner_id<>p_owner and (exists(select 1 from financial_events where account_id=a.id) or exists(select 1 from account_ledger where account_id=a.id and operation_key<>'opening') or exists(select 1 from credit_cards where account_id=a.id) or exists(select 1 from scheduled_transfers where from_account=a.id or to_account=a.id)) then raise exception 'Conta com histórico: preserve o titular e crie outra conta';end if;
 insert into account_edits values(p_id,a.household_id,params);
 if p_primary then update financial_accounts set is_primary=false where household_id=a.household_id and owner_id=p_owner and is_primary;end if;
 update financial_accounts set name=trim(p_name),owner_id=p_owner,color=p_color,account_type=p_type,is_primary=p_primary where id=a.id;
 if p_balance<>a.balance then insert into account_ledger(household_id,account_id,amount,operation_key,actor_id) values(a.household_id,a.id,p_balance-a.balance,'adjustment:'||p_id,auth.uid());end if;
end $$;
-- New predictions must use an active account belonging to their responsible person.
-- Existing historical links are left intact.
create function public.validate_event_owner() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if not exists(select 1 from financial_accounts where id=new.account_id and household_id=new.household_id and owner_id=new.owner_id and active) then raise exception 'Selecione uma conta do responsável';end if;
 return new;
end $$;
create trigger event_owner before insert on financial_events for each row execute function validate_event_owner();
alter table financial_events add column auto_receipt_suppressed boolean not null default false;
create function public.suppress_reversed_income() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.kind='income' and old.paid_amount>0 and new.paid_amount=0 then new.auto_receipt_suppressed:=true;end if;return new;
end $$;
create trigger income_reversal before update on financial_events for each row execute function suppress_reversed_income();
-- Private worker callable by cron; every posting locks the event and uses a unique key.
create function public.post_due_income(p_household uuid) returns integer language plpgsql security definer set search_path=public as $$
declare e financial_events%rowtype;pid uuid;n integer:=0;remaining numeric;
begin
 for e in select ev.* from financial_events ev join financial_accounts a on a.id=ev.account_id where ev.kind='income' and ev.status='pending' and not ev.auto_receipt_suppressed and ev.due_date<=(now() at time zone 'America/Fortaleza')::date and a.active and (p_household is null or ev.household_id=p_household) order by ev.id for update of ev skip locked loop
 remaining:=e.amount-e.paid_amount;pid:=gen_random_uuid();
 perform 1 from financial_accounts where id=e.account_id for update;
 insert into event_payments(id,household_id,event_id,account_id,amount,paid_date,actor_id) values(pid,e.household_id,e.id,e.account_id,remaining,e.due_date,e.created_by);
 insert into account_ledger(household_id,account_id,amount,operation_key,event_id,actor_id) values(e.household_id,e.account_id,remaining,'auto-income:'||e.id,e.id,e.created_by);
 update financial_events set paid_amount=amount,status='settled',settled_at=now() where id=e.id;n:=n+1;
 end loop;return n;
end $$;
create function public.confirm_due_income(p_household uuid) returns integer language plpgsql security definer set search_path=public as $$
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 return post_due_income(p_household);
end $$;
create table public.income_corrections(id uuid primary key,household_id uuid not null references households,parameters jsonb not null);
alter table income_corrections enable row level security;
create function public.correct_income(p_id uuid,p_event uuid,p_amount numeric,p_date date,p_expected numeric) returns void language plpgsql security definer set search_path=public as $$
declare e financial_events%rowtype;previous income_corrections%rowtype;params jsonb;
begin
 select * into e from financial_events where id=p_event for update;
 if not found or not is_household_member(e.household_id) then raise exception 'Sem permissão';end if;
 if p_id is null or p_amount is null or p_amount<=0 or p_amount='NaN'::numeric or p_amount<>round(p_amount,2) or p_date is null or p_date>(now() at time zone 'America/Fortaleza')::date or e.kind<>'income' then raise exception 'Recebimento inválido';end if;
 params:=jsonb_build_array(p_event,p_amount,p_date,p_expected);
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,11));select * into previous from income_corrections where id=p_id;
 if found then if previous.household_id<>e.household_id or previous.parameters<>params then raise exception 'Chave já utilizada';end if;return;end if;
 if e.status<>'settled' or p_expected is null or e.paid_amount<>p_expected then raise exception 'Recebimento alterado. Atualize a página';end if;
 insert into income_corrections values(p_id,e.household_id,params);
 perform reverse_event(e.id);
 update financial_events set amount=p_amount where id=e.id;
 perform pay_event(p_id,e.id,e.account_id,p_amount,p_date,0);
end $$;
revoke all on function public.save_account(uuid,uuid,text,uuid,text,boolean,text,numeric,numeric),public.validate_event_owner(),public.suppress_reversed_income(),public.post_due_income(uuid),public.confirm_due_income(uuid),public.correct_income(uuid,uuid,numeric,date,numeric) from public;
grant execute on function public.save_account(uuid,uuid,text,uuid,text,boolean,text,numeric,numeric),public.confirm_due_income(uuid),public.correct_income(uuid,uuid,numeric,date,numeric) to authenticated;
-- Cron is configured separately after pg_cron is enabled; fallback also runs at login/foreground.
notify pgrst,'reload schema';
