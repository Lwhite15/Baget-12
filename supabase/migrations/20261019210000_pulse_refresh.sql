-- Between hunts (no AI): a quick "pulse" per scout whose results are kept only when the store's own page confirms them,
-- and a daily re-check of every open find's page (price, sold out, removed).
alter table public.agents add column if not exists last_pulse_at timestamptz;
alter table public.listings add column if not exists page_checked_at timestamptz;

-- Scouts due a pulse: on, within the plan's scout count, not hunted in the last hour, and not pulsed within the plan's
-- interval (Free 6h, Pro 3h by default). Marks them so the next tick doesn't take them again.
create or replace function public.claim_pulses(p_limit int default 30, p_free_minutes int default 360, p_pro_minutes int default 180)
returns setof jsonb language plpgsql security definer set search_path = public as $$
declare c jsonb;
begin
  for c in
    select to_jsonb(a) || jsonb_build_object('tz', p.tz, 'settings', p.settings, 'display_name', p.display_name, 'pro', pro.v)
      from public.agents a
      join public.profiles p on p.id = a.user_id
      cross join lateral (select public.is_pro(p.id) as v) pro
     where not a.paused
       and (select count(*) from public.agents x where x.user_id = a.user_id and not x.paused and x.created_at < a.created_at) < public.scout_limit(p.id)
       and coalesce(a.last_swept_at, 'epoch') < now() - interval '1 hour'
       and coalesce(a.last_pulse_at, 'epoch') < now() - make_interval(mins => case when pro.v then p_pro_minutes else p_free_minutes end)
       and a.last_swept_at is not null
     order by a.last_pulse_at nulls first
     limit greatest(1, least(p_limit, 200))
  loop
    update public.agents set last_pulse_at = now() where id = (c ->> 'id')::uuid;
    return next c;
  end loop;
end $$;
revoke all on function public.claim_pulses(int, int, int) from public, anon, authenticated;
grant execute on function public.claim_pulses(int, int, int) to service_role;

create or replace function public.configure_scheduler(p_url text, p_secret text)
returns text language plpgsql security definer set search_path = public as $$
declare
  sid uuid;
begin
  select id into sid from vault.secrets where name = 'baget_project_url';
  if sid is null then perform vault.create_secret(p_url, 'baget_project_url');
  else perform vault.update_secret(sid, p_url); end if;
  sid := null;
  select id into sid from vault.secrets where name = 'baget_cron_secret';
  if sid is null then perform vault.create_secret(p_secret, 'baget_cron_secret');
  else perform vault.update_secret(sid, p_secret); end if;

  perform cron.unschedule(jobid) from cron.job where jobname in ('baget-sweep', 'baget-release', 'baget-maintain', 'baget-pulse');
  perform cron.schedule('baget-sweep', '*/5 * * * *', $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'baget_project_url') || '/functions/v1/sweep',
      body := '{"mode":"scheduled"}'::jsonb,
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-baget-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'baget_cron_secret')),
      timeout_milliseconds := 150000)
  $job$);
  perform cron.schedule('baget-release', '2 * * * *', $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'baget_project_url') || '/functions/v1/push',
      body := '{"release":true}'::jsonb,
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-baget-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'baget_cron_secret')))
  $job$);
  perform cron.schedule('baget-maintain', '7,22,37,52 * * * *', $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'baget_project_url') || '/functions/v1/sweep',
      body := '{"maintain":true}'::jsonb,
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-baget-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'baget_cron_secret')),
      timeout_milliseconds := 150000)
  $job$);
  perform cron.schedule('baget-pulse', '3-59/10 * * * *', $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'baget_project_url') || '/functions/v1/sweep',
      body := '{"pulse":true}'::jsonb,
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-baget-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'baget_cron_secret')),
      timeout_milliseconds := 150000)
  $job$);
  return 'scheduled';
end $$;
revoke all on function public.configure_scheduler(text, text) from public, anon, authenticated;
grant execute on function public.configure_scheduler(text, text) to service_role;
