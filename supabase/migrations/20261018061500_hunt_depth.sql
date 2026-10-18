-- Hunt depth by plan. Free: standard hunts, two per day inside the window. Pro: deep hunts around the clock.
-- Sweeps learn the plan from the candidate row ("pro").
create or replace function public.sweep_candidates(p_limit int default 20, p_daily_cap int default 30,
                                                   p_user uuid default null, p_agent uuid default null)
returns setof jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object('tz', p.tz, 'settings', p.settings, 'handle', p.handle, 'display_name', p.display_name, 'pro', public.is_pro(p.id),
           'runs_today', (select count(*) from public.sweep_runs r where r.user_id = a.user_id and r.created_at > now() - interval '24 hours' and r.error is null))
    from public.agents a
    join public.profiles p on p.id = a.user_id
   where not a.paused
     -- Free plan: agents hunt only during the owner's daily window. A brand-new agent always gets its first hunt.
     and (public.is_pro(p.id) or a.last_swept_at is null or public.in_hunt_window(p.tz, p.settings))
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
            -- Free: twice inside the 4-hour window (standard hunts). Pro: deep hunts on the owner's interval, around the clock.
            case when public.is_pro(p.id) then coalesce((p.settings ->> 'sweepMinutes')::int, 180) else 120 end,
            ceil((case when public.is_pro(p.id) then 1440.0 else 240.0 end) * (select count(*) from public.agents x where x.user_id = a.user_id and not x.paused) / greatest(p_daily_cap, 1))::int)))
     )
   order by a.last_swept_at nulls first
   limit p_limit
$$;
