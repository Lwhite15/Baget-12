-- Scouts slow down for people who stop opening Baget, and pick straight back up when they return.
--   active: opened in the last 3 days (or always-on: owner, comp plan, admins, Baget's own accounts) -> normal schedule
--   slow:   3 to 10 days away -> once a day
--   resting: 10+ days away -> no scheduled hunts; one text first ("your scouts found N while you were away")
-- "Opened" = the app's own check-in (touch_active) or a sign-in refresh, so it works on builds without the check-in too.

alter table public.profiles add column if not exists last_active_at timestamptz;

create or replace function public.last_active(uid uuid) returns timestamptz
language sql stable security definer set search_path = public, auth as $$
  select greatest(
    (select last_active_at from public.profiles where id = uid),
    (select max(greatest(s.updated_at, s.refreshed_at::timestamptz, s.created_at)) from auth.sessions s where s.user_id = uid),
    (select created_at from public.profiles where id = uid))
$$;

create or replace function public.always_hunts(uid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select uid::text like '0a99e1e0-5eed-4d3e-8a00-%'
      or exists (select 1 from public.app_admins where user_id = uid)
      or exists (select 1 from public.profiles where id = uid and (plan = 'comp' or settings ->> 'alwaysHunt' = 'true'))
$$;

create or replace function public.hunt_pace(uid uuid) returns text
language sql stable security definer set search_path = public as $$
  select case
    when public.always_hunts(uid) then 'active'
    when coalesce(public.last_active(uid), now()) > now() - interval '3 days' then 'active'
    when public.last_active(uid) > now() - interval '10 days' then 'slow'
    else 'resting' end
$$;
revoke all on function public.last_active(uuid), public.always_hunts(uuid), public.hunt_pace(uuid) from public, anon, authenticated;

-- The app checks in when it opens. Returns true when they'd been away (slow or resting), so the app hunts right away.
create or replace function public.touch_active() returns boolean
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); was text;
begin
  if uid is null then return false; end if;
  was := public.hunt_pace(uid);
  update public.profiles set last_active_at = now() where id = uid;
  return was <> 'active';
end $$;
revoke all on function public.touch_active() from public, anon;
grant execute on function public.touch_active() to authenticated;

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
     -- Scheduled hunts follow how recently they opened Baget: as usual for 3 days, then once a day, then rest after 10.
     -- Opening the app again brings them straight back (this check looks at the latest open every time).
     and (p_user is not null or public.hunt_pace(p.id) = 'active'
          or (public.hunt_pace(p.id) = 'slow' and coalesce(a.last_swept_at, 'epoch') < now() - interval '20 hours'))
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


-- Quick check-ins between hunts: only for people who are around.
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
       and public.hunt_pace(p.id) = 'active'
     order by a.last_pulse_at nulls first
     limit greatest(1, least(p_limit, 200))
  loop
    update public.agents set last_pulse_at = now() where id = (c ->> 'id')::uuid;
    return next c;
  end loop;
end $$;

-- One text as someone drifts toward resting (9+ days away), once per time away.
create or replace function public.resting_nudges() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; found_count int;
begin
  for r in
    select p.id, public.last_active(p.id) as last from public.profiles p
     where not public.always_hunts(p.id)
       and exists (select 1 from public.agents a where a.user_id = p.id and not a.paused)
       and public.last_active(p.id) < now() - interval '9 days'
       and coalesce((p.settings ->> 'restNudgedAt')::timestamptz, 'epoch') < public.last_active(p.id)
     limit 200
  loop
    select count(*) into found_count from public.finds f where f.user_id = r.id and f.status = 'open' and f.created_at > r.last;
    insert into public.notes (user_id, sender_name, kind, body)
    values (r.id, 'Your scouts', 'digest',
            case when found_count > 0
                 then 'Your scouts found ' || found_count || ' new things while you were away. They''ll take a break until you''re back; open Baget any time and they start hunting again.'
                 else 'Your scouts are taking a break while you''re away. Open Baget any time and they start hunting again.' end);
    update public.profiles set settings = coalesce(settings, '{}') || jsonb_build_object('restNudgedAt', now()) where id = r.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.resting_nudges() from public, anon, authenticated;
grant execute on function public.resting_nudges() to service_role;
