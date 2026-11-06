-- Manual only, after 021. Enable pg_cron, pg_net and Vault in Supabase first.
-- Store these Vault secrets MANUALLY (never paste real keys into this repository):
-- finance_app_url = https://YOUR_APP.vercel.app
-- finance_notifications_secret = same random value as NOTIFICATIONS_CRON_SECRET
do $$begin
 if not exists(select 1 from cron.job where jobname='finance-email-notifications') then
  perform cron.schedule('finance-email-notifications','*/5 * * * *',$job$
   select net.http_post(
    url:=(select decrypted_secret from vault.decrypted_secrets where name='finance_app_url' limit 1)||'/api/notifications',
    headers:=jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||(select decrypted_secret from vault.decrypted_secrets where name='finance_notifications_secret' limit 1)),
    body:='{}'::jsonb,timeout_milliseconds:=10000);
  $job$);
 end if;
end $$;
