-- OPTIONAL, MANUAL INSTALLATION ONLY, AFTER 019.
-- First enable pg_cron in the Supabase Extensions screen. Run as the database owner.
-- This script installs a job; it does not mark any invoice paid.
do $$begin
 if not exists(select 1 from pg_extension where extname='pg_cron') then
  raise exception 'Ative pg_cron em Database > Extensions antes de executar este arquivo';
 end if;
end $$;

create or replace function public.cc_run_due_cards() returns void language plpgsql security definer set search_path=public as $$
declare grp record;previous_sub text:=current_setting('request.jwt.claim.sub',true);
begin
 for grp in select h.id,(select m.user_id from household_members m where m.household_id=h.id order by m.user_id limit 1) member_id
  from households h where exists(select 1 from credit_cards c where c.household_id=h.id and c.module_version=2 and c.card_status='active') loop
  if grp.member_id is not null then
   begin
    perform set_config('request.jwt.claim.sub',grp.member_id::text,true);
    perform cc_generate(grp.id,((now() at time zone 'America/Fortaleza')::date+interval '1 year')::date);
   exception when others then
    raise warning 'Geração de cartões falhou para o grupo %: %',grp.id,sqlerrm;
   end;
  end if;
 end loop;
 perform set_config('request.jwt.claim.sub',coalesce(previous_sub,''),true);
end $$;
revoke all on function public.cc_run_due_cards() from public,anon,authenticated;

-- Idempotent installation: do not create duplicate jobs or remove any existing job.
do $$begin
 if not exists(select 1 from cron.job where jobname='finance-credit-due') then
  perform cron.schedule('finance-credit-due','17 * * * *','select public.cc_run_due_cards()');
 end if;
end $$;

-- Inspect job status manually after installation:
select jobid,jobname,schedule,active from cron.job where jobname='finance-credit-due';
-- SELECT * FROM cron.job_run_details WHERE jobid IN
-- (SELECT jobid FROM cron.job WHERE jobname='finance-credit-due') ORDER BY start_time DESC LIMIT 20;
