-- Sweeps get the person's name so agents can write texts addressed to them.
create or replace function public.sweep_candidates(p_limit int default 20, p_daily_cap int default 30,
                                                   p_user uuid default null, p_agent uuid default null)
returns setof jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object('tz', p.tz, 'settings', p.settings, 'handle', p.handle, 'display_name', p.display_name,
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
