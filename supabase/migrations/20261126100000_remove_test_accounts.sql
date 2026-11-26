-- Test accounts made by the QA walkthrough and the demo/daily Reels (qa-<run>@example.com, demo-…, reel-…). Each run now
-- deletes its own account at the end; this removes the ones left from earlier runs and, as a backstop, sweeps any
-- leftover older than a day once a day. The App Review and screenshots accounts don't match and are never touched.
-- Deleting the auth user cascades to profiles and everything that hangs off them.
delete from auth.users where email ~ '^(qa|demo|reel)-[0-9]+@example\.com$';

do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then return; end if;
  perform cron.unschedule(jobid) from cron.job where jobname = 'baget-test-accounts';
  perform cron.schedule('baget-test-accounts', '17 9 * * *', $job$
    delete from auth.users where email ~ '^(qa|demo|reel)-[0-9]+@example\.com$' and created_at < now() - interval '1 day';
  $job$);
end $$;
