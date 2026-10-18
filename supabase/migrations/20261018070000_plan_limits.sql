-- Plan limits (cost control):
--   Free: 2 scouts, one standard hunt a day each, inside the 4-hour window. Pull-to-refresh can't add extra hunts.
--   Pro:  5 scouts, a deep hunt every 6 hours around the clock; pull-to-refresh at most every 2 hours per scout.
--   Comp (owner, house account): Pro rules with up to 12 scouts.
-- Existing free accounts with more scouts keep them, but only their first 2 that are on go hunting.

create or replace function public.scout_limit(uid uuid)
returns int language sql stable security definer set search_path = public as $$
  select case when (select plan from public.profiles where id = uid) = 'comp' then 12
              when public.is_pro(uid) then 5 else 2 end
$$;
revoke all on function public.scout_limit(uuid) from public, anon, authenticated;

create or replace function public.limit_agents()
returns trigger language plpgsql security definer set search_path = public as $$
declare lim int := public.scout_limit(new.user_id);
begin
  if (select count(*) from public.agents where user_id = new.user_id) >= lim then
    raise exception 'agent_limit' using hint = case when lim <= 2 then 'Free includes 2 scouts. Go Pro for up to 5.'
                                                    else format('A squad can have up to %s scouts.', lim) end;
  end if;
  return new;
end $$;

create or replace function public.sweep_candidates(p_limit int default 20, p_daily_cap int default 30,
                                                   p_user uuid default null, p_agent uuid default null)
returns setof jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object('tz', p.tz, 'settings', p.settings, 'handle', p.handle, 'display_name', p.display_name, 'pro', pro.v,
           'runs_today', (select count(*) from public.sweep_runs r where r.user_id = a.user_id and r.created_at > now() - interval '24 hours' and r.error is null))
    from public.agents a
    join public.profiles p on p.id = a.user_id
    cross join lateral (select public.is_pro(p.id) as v) pro
   where not a.paused
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

create or replace function public.my_plan()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'plan', p.plan,
    'pro', public.is_pro(p.id),
    'pro_until', p.pro_until,
    'hunt_start', public.hunt_start(p.settings),
    'hours', 4,
    'hunting_now', public.is_pro(p.id) or public.in_hunt_window(p.tz, p.settings),
    'scouts', public.scout_limit(p.id),
    'tz', p.tz)
  from public.profiles p where p.id = auth.uid()
$$;
