-- Per-agent controls: turn an agent off (no sweeps, no texts) and tune how much it texts.
--   alerts: 'normal' follows the account's "How often Baget texts you"; 'quiet' texts only top finds (score 90+); 'off' never texts.
alter table public.agents add column if not exists paused boolean not null default false;
alter table public.agents add column if not exists alerts text not null default 'normal';
alter table public.agents drop constraint if exists agents_alerts_check;
alter table public.agents add constraint agents_alerts_check check (alerts in ('normal','quiet','off'));
grant update (paused, alerts) on public.agents to authenticated;

create or replace function public.sweep_candidates(p_limit int default 20, p_daily_cap int default 30,
                                                   p_user uuid default null, p_agent uuid default null)
returns setof jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object('tz', p.tz, 'settings', p.settings, 'handle', p.handle,
           'runs_today', (select count(*) from public.sweep_runs r where r.user_id = a.user_id and r.created_at > now() - interval '24 hours' and r.error is null))
    from public.agents a
    join public.profiles p on p.id = a.user_id
   where not a.paused
     and (p_user is null or a.user_id = p_user)
     and (p_agent is null or a.id = p_agent)
     and (select count(*) from public.sweep_runs r where r.user_id = a.user_id and r.created_at > now() - interval '24 hours' and r.error is null) < p_daily_cap
     and (
       (p_user is not null and coalesce(a.last_swept_at, 'epoch') < now() - interval '10 minutes')
       or
       -- scheduled: owner's interval, never more than hourly, spread over the day (only agents that are on count)
       (p_user is null and coalesce(a.last_swept_at, 'epoch') <
          now() - make_interval(mins => greatest(
            60,
            coalesce((p.settings ->> 'sweepMinutes')::int, 180),
            ceil(1440.0 * (select count(*) from public.agents x where x.user_id = a.user_id and not x.paused) / greatest(p_daily_cap, 1))::int)))
     )
   order by a.last_swept_at nulls first
   limit p_limit
$$;
