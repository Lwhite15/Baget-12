-- Agents search more often by default: every 3 hours (was 6). People who never changed it move to 3 hours.
update public.profiles
   set settings = jsonb_set(settings, '{sweepMinutes}', '180')
 where coalesce((settings ->> 'sweepMinutes')::int, 360) = 360;

-- Agents due for a sweep, with their owner's timezone and settings.
create or replace function public.sweep_candidates(p_limit int default 20, p_daily_cap int default 30,
                                                   p_user uuid default null, p_agent uuid default null)
returns setof jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object('tz', p.tz, 'settings', p.settings, 'handle', p.handle,
           'runs_today', (select count(*) from public.sweep_runs r where r.user_id = a.user_id and r.created_at > now() - interval '24 hours'))
    from public.agents a
    join public.profiles p on p.id = a.user_id
   where (p_user is null or a.user_id = p_user)
     and (p_agent is null or a.id = p_agent)
     and (select count(*) from public.sweep_runs r where r.user_id = a.user_id and r.created_at > now() - interval '24 hours') < p_daily_cap
     and (
       -- manual sweeps: at most one per agent every 10 minutes
       (p_user is not null and coalesce(a.last_swept_at, 'epoch') < now() - interval '10 minutes')
       or
       -- scheduled sweeps: on each owner's chosen interval, never more than hourly
       (p_user is null and coalesce(a.last_swept_at, 'epoch') <
          now() - make_interval(mins => greatest(60, coalesce((p.settings ->> 'sweepMinutes')::int, 180))))
     )
   order by a.last_swept_at nulls first
   limit p_limit
$$;

