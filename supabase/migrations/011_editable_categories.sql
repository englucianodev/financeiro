-- Predefined categories become editable household records. Existing labels remain intact.
alter table public.categories add column deleted_at timestamptz;
create function public.seed_household_categories(p_household uuid) returns void language sql security definer set search_path=public as $$
 insert into categories(household_id,name,kind,color,icon)
 select p_household,v.name,v.kind,case when v.kind='income' then '#0284c7' else '#e11d48' end,'wallet'
 from (values ('income','Salário'),('income','Aluguel recebido'),('income','Serviços'),('income','Rendimentos'),('income','Reembolso'),('income','Venda'),('income','Outros'),('expense','Alimentação'),('expense','Supermercado'),('expense','Transporte'),('expense','Combustível'),('expense','Moradia'),('expense','Energia'),('expense','Água'),('expense','Internet'),('expense','Condomínio'),('expense','Saúde'),('expense','Educação'),('expense','Lazer'),('expense','Cartão de crédito'),('expense','Financiamento'),('expense','Impostos'),('expense','Manutenção'),('expense','Outros')) as v(kind,name)
 on conflict(household_id,kind,name) do nothing;
$$;
do $$ declare h record;begin for h in select id from public.households loop perform public.seed_household_categories(h.id);end loop;end $$;
-- Expose legacy category labels too, without modifying the movements themselves.
insert into public.categories(household_id,name,kind,color,icon)
select distinct household_id,category,kind,case when kind='income' then '#0284c7' else '#e11d48' end,'wallet'
from public.financial_events where length(trim(category)) between 1 and 100
on conflict(household_id,kind,name) do nothing;
create function public.seed_new_household_categories() returns trigger language plpgsql security definer set search_path=public as $$
begin perform seed_household_categories(new.id);return new;end $$;
create trigger household_categories after insert on public.households for each row execute function public.seed_new_household_categories();
create function public.delete_category(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin
 update categories set active=false,deleted_at=coalesce(deleted_at,now()) where id=p_id and is_household_member(household_id);
 if not found then raise exception 'Sem permissão';end if;
end $$;
revoke all on function public.seed_household_categories(uuid),public.seed_new_household_categories(),public.delete_category(uuid) from public;
grant execute on function public.delete_category(uuid) to authenticated;
notify pgrst,'reload schema';
