-- Additive property details; all existing links and investment records are preserved.
alter table public.properties
 add column city text not null default '' check(length(city)<=120),
 add column tenure text not null default 'owned' check(tenure in ('owned','rented')),
 add column payment_status text not null default 'paid' check(payment_status in ('paid','financed')),
 add column debt numeric(16,2) not null default 0 check(debt>=0 and debt<>'NaN'::numeric and debt<=9000000000000),
 add column pending_installments integer;
alter table public.properties add constraint property_financing_details check(
 (payment_status='financed' or debt=0) and
 ((tenure='owned' and payment_status='financed' and pending_installments is not null and pending_installments>=0)
 or ((tenure<>'owned' or payment_status<>'financed') and pending_installments is null))
);
alter table public.properties add constraint property_value_finite check(estimated_value<>'NaN'::numeric and estimated_value<=9000000000000) not valid;
alter table public.investments add constraint investment_value_finite check(amount<>'NaN'::numeric and amount<=9000000000000) not valid;
create function public.save_property(p_id uuid,p_household uuid,p_name text,p_city text,p_tenure text,p_status text,p_value numeric,p_debt numeric,p_installments integer) returns void
language plpgsql security definer set search_path=public as $$
declare old_property properties%rowtype;
begin
 if not is_household_member(p_household) then raise exception 'Sem permissão';end if;
 if p_id is null or p_name is null or length(trim(p_name)) not between 1 and 120 or p_city is null or length(trim(p_city)) not between 1 and 120 or p_tenure is null or p_tenure not in ('owned','rented') or p_status is null or p_status not in ('paid','financed') or p_value is null or p_value='NaN'::numeric or p_value<0 or p_value>9000000000000 or p_value<>round(p_value,2) or p_debt is null or p_debt='NaN'::numeric or p_debt<0 or p_debt>9000000000000 or p_debt<>round(p_debt,2) then raise exception 'Dados do imóvel inválidos';end if;
 if (p_status='paid' and p_debt<>0) or (p_tenure='owned' and p_status='financed' and (p_installments is null or p_installments<0)) or ((p_tenure<>'owned' or p_status<>'financed') and p_installments is not null) then raise exception 'Dados do financiamento inválidos';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,13));
 select * into old_property from properties where id=p_id for update;
 if found then
 if old_property.household_id<>p_household then raise exception 'Sem permissão';end if;
 update properties set name=trim(p_name),city=trim(p_city),tenure=p_tenure,payment_status=p_status,estimated_value=p_value,debt=p_debt,pending_installments=p_installments where id=p_id;
 else insert into properties(id,household_id,name,city,tenure,payment_status,estimated_value,debt,pending_installments) values(p_id,p_household,trim(p_name),trim(p_city),p_tenure,p_status,p_value,p_debt,p_installments);
 end if;
end $$;
create function public.register_investment(p_id uuid,p_household uuid,p_owner uuid,p_name text,p_kind text,p_amount numeric,p_liquidity date) returns void
language plpgsql security definer set search_path=public as $$
declare old_investment investments%rowtype;
begin
 if not is_household_member(p_household) or not exists(select 1 from household_members where household_id=p_household and user_id=p_owner) then raise exception 'Sem permissão';end if;
 if p_id is null or p_name is null or length(trim(p_name)) not between 1 and 120 or p_kind is null or length(trim(p_kind)) not between 1 and 60 or p_amount is null or p_amount='NaN'::numeric or p_amount<0 or p_amount>9000000000000 or p_amount<>round(p_amount,2) then raise exception 'Investimento inválido';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_id::text,14));
 select * into old_investment from investments where id=p_id;
 if found then
 if old_investment.household_id<>p_household or old_investment.owner_id<>p_owner or old_investment.name<>trim(p_name) or old_investment.kind<>trim(p_kind) or old_investment.amount<>p_amount or old_investment.liquidity_date is distinct from p_liquidity then raise exception 'Chave já utilizada';end if;return;
 end if;
 insert into investments(id,household_id,owner_id,name,kind,amount,liquidity_date) values(p_id,p_household,p_owner,trim(p_name),trim(p_kind),p_amount,p_liquidity);
end $$;
revoke all on function public.save_property(uuid,uuid,text,text,text,text,numeric,numeric,integer),public.register_investment(uuid,uuid,uuid,text,text,numeric,date) from public;
grant execute on function public.save_property(uuid,uuid,text,text,text,text,numeric,numeric,integer),public.register_investment(uuid,uuid,uuid,text,text,numeric,date) to authenticated;
notify pgrst,'reload schema';
