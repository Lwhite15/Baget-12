-- Launch capacity. Before: 3 hunts per 15 minutes in one worker (at most 288 a day, about 48 in a Free user's 4-hour
-- window). Now the scheduler runs every 5 minutes and hands each scout to its own worker, and photo/description
-- backfills run separately, so a slow hunt can't hold up the rest.

alter table public.agents add column if not exists sweep_claimed_at timestamptz;

create or replace function public.sweep_candidates(p_limit int default 20, p_daily_cap int default 30,
                                                   p_user uuid default null, p_agent uuid default null)
returns setof jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object('tz', p.tz, 'settings', p.settings, 'handle', p.handle, 'display_name', p.display_name, 'pro', pro.v,
           'runs_today', (select count(*) from public.sweep_runs r where r.user_id = a.user_id and r.created_at > now() - interval '24 hours' and r.error is null))
    from public.agents a
    join public.profiles p on p.id = a.user_id
    cross join lateral (select public.is_pro(p.id) as v) pro
   where not a.paused
     -- A scheduled hunt already handed out in the last 10 minutes is still running.
     and (p_user is not null or coalesce(a.sweep_claimed_at, 'epoch') < now() - interval '10 minutes')
     and (p_user is null or a.user_id = p_user)
     and (p_agent is null or a.id = p_agent)
     -- Only the plan's number of scouts hunt (the earliest ones that are on).
     and (select count(*) from public.agents x where x.user_id = a.user_id and not x.paused and x.created_at < a.created_at) < public.scout_limit(p.id)
     -- Free: inside the daily window. A brand-new scout always gets its first hunt.
     and (pro.v or a.last_swept_at is null or public.in_hunt_window(p.tz, p.settings))
     -- Daily cap on successful hunts: Free 3 (two scouts plus a first hunt), Pro 24, owner accounts the server cap.
     and (select count(*) from public.sweep_runs r where r.user_id = a.user_id and r.created_at > now() - interval '24 hours' and r.error is null)
         < case when p.plan = 'comp' then p_daily_cap when pro.v then least(p_daily_cap, 24) else 3 end
     and (
       -- manual (pull to refresh): Free only if this scout hasn't hunted today; Pro at most every 2 hours per scout
       (p_user is not null and coalesce(a.last_swept_at, 'epoch') < now() - case when pro.v then interval '2 hours' else interval '20 hours' end)
       or
       -- scheduled: Free once a day (in the window); Pro every 6 hours or the owner's longer interval
       (p_user is null and coalesce(a.last_swept_at, 'epoch') <
          now() - make_interval(mins => case when pro.v then greatest(360, coalesce((p.settings ->> 'sweepMinutes')::int, 360)) else 1200 end))
     )
   order by a.last_swept_at nulls first
   limit p_limit
$$;

-- Hands out the next scheduled hunts and marks them taken, so the next tick doesn't start the same scout twice.
create or replace function public.claim_sweeps(p_limit int default 20, p_daily_cap int default 30)
returns setof jsonb language plpgsql security definer set search_path = public as $$
declare c jsonb;
begin
  for c in select * from public.sweep_candidates(greatest(1, least(p_limit, 100)), p_daily_cap, null, null) loop
    update public.agents set sweep_claimed_at = now() where id = (c ->> 'id')::uuid;
    return next c;
  end loop;
end $$;
revoke all on function public.claim_sweeps(int, int) from public, anon, authenticated;
grant execute on function public.claim_sweeps(int, int) to service_role;

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

  perform cron.unschedule(jobid) from cron.job where jobname in ('baget-sweep', 'baget-release', 'baget-maintain');
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
  return 'scheduled';
end $$;
revoke all on function public.configure_scheduler(text, text) from public, anon, authenticated;
grant execute on function public.configure_scheduler(text, text) to service_role;
