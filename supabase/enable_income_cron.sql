-- Optional: enable pg_cron in Supabase Integrations first, then run as database owner.
-- Private worker is not exposed to application users; executes every five minutes.
select cron.schedule('finance-confirm-income','*/5 * * * *', $job$select public.post_due_income(null);$job$);
