-- Free and Pro.
--   Free: agents hunt for 4 hours a day, in a window the person picks (settings.huntStart, local hour, default 9am),
--         sweeping every hour inside it. Outside the window they rest. A new agent always gets its first hunt.
--   Pro:  agents hunt around the clock on the person's interval.
-- The plan lives on the profile and only the server can change it (after verifying an App Store purchase).

alter table public.profiles add column if not exists plan text not null default 'free';
alter table public.profiles drop constraint if exists profiles_plan_check;
alter table public.profiles add constraint profiles_plan_check check (plan in ('free', 'pro', 'comp'));
alter table public.profiles add column if not exists pro_until timestamptz;
alter table public.profiles add column if not exists pro_product text check (char_length(pro_product) <= 100);
alter table public.profiles add column if not exists pro_environment text check (char_length(pro_environment) <= 20);
alter table public.profiles add column if not exists original_transaction_id text unique check (char_length(original_transaction_id) <= 64);

-- The owner's accounts and the App Review demo account get Pro for free.
update public.profiles set plan = 'comp'
 where id in (select user_id from public.app_admins) or id = '0a99e1e0-5eed-4d3e-8a00-00000000d3e0';

create or replace function public.is_pro(uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select plan = 'comp' or (plan = 'pro' and pro_until > now()) from public.profiles where id = uid), false)
$$;
revoke all on function public.is_pro(uuid) from public, anon, authenticated;

create or replace function public.hunt_start(settings jsonb)
returns int language sql immutable as $$
  select case when (settings ->> 'huntStart') ~ '^[0-9]{1,2}$' and (settings ->> 'huntStart')::int between 0 and 23
              then (settings ->> 'huntStart')::int else 9 end
$$;

create or replace function public.in_hunt_window(tz text, settings jsonb, p_at timestamptz default now())
returns boolean language sql stable as $$
  select ((extract(hour from p_at at time zone coalesce(nullif(tz, ''), 'America/New_York'))::int - public.hunt_start(settings) + 24) % 24) < 4
$$;

-- What the app shows: your plan, and for Free, whether your scouts are hunting now and when the window opens or closes.
create or replace function public.my_plan()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'plan', p.plan,
    'pro', public.is_pro(p.id),
    'pro_until', p.pro_until,
    'hunt_start', public.hunt_start(p.settings),
    'hours', 4,
    'hunting_now', public.is_pro(p.id) or public.in_hunt_window(p.tz, p.settings),
    'tz', p.tz)
  from public.profiles p where p.id = auth.uid()
$$;
revoke all on function public.my_plan() from public, anon;
grant execute on function public.my_plan() to authenticated;

create or replace function public.sweep_candidates(p_limit int default 20, p_daily_cap int default 30,
                                                   p_user uuid default null, p_agent uuid default null)
returns setof jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object('tz', p.tz, 'settings', p.settings, 'handle', p.handle, 'display_name', p.display_name,
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
            -- Free: every hour inside the window. Pro: the owner's interval, around the clock.
            case when public.is_pro(p.id) then coalesce((p.settings ->> 'sweepMinutes')::int, 180) else 60 end,
            ceil((case when public.is_pro(p.id) then 1440.0 else 240.0 end) * (select count(*) from public.agents x where x.user_id = a.user_id and not x.paused) / greatest(p_daily_cap, 1))::int)))
     )
   order by a.last_swept_at nulls first
   limit p_limit
$$;
