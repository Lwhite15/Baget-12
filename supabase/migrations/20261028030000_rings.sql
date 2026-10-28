-- Rings: a ring around your icon that friends see.
--  * creator: 1 of 1, Larry's alone (a unique index means a second can never exist).
--  * founding: gold and silver, given once to Baget's founding testers. Never earned; only a migration adds it.
--  * first_like, crew_3, streak_7, first_buy: earned by using Baget (my_rings() awards them).
--  * pro_glow: worn by Pro members while they're Pro; not owned.
-- Nobody can give themselves a ring: people can only read their own rings, and the ring you wear is checked against
-- what you own every time it changes.

create table if not exists public.user_rings (
  user_id   uuid not null references public.profiles(id) on delete cascade,
  ring      text not null check (ring in ('creator', 'founding', 'first_like', 'crew_3', 'streak_7', 'first_buy')),
  earned_at timestamptz not null default now(),
  primary key (user_id, ring)
);
create unique index if not exists user_rings_one_creator on public.user_rings (ring) where ring = 'creator';
alter table public.user_rings enable row level security;
revoke all on public.user_rings from anon, authenticated;
grant select on public.user_rings to authenticated;
drop policy if exists user_rings_own on public.user_rings;
create policy user_rings_own on public.user_rings for select to authenticated using (user_id = auth.uid());

-- Days you reacted to finds (liked, passed or bought), for the 7-day streak. Server only.
create table if not exists public.activity_days (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day     date not null,
  primary key (user_id, day)
);
alter table public.activity_days enable row level security;
revoke all on public.activity_days from anon, authenticated;

create or replace function public.note_activity_day() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status and new.status in ('liked', 'passed', 'acquired') then
    insert into public.activity_days (user_id, day)
    select new.user_id, (now() at time zone coalesce(p.tz, 'America/New_York'))::date from public.profiles p where p.id = new.user_id
    on conflict do nothing;
  end if;
  return new;
end $$;
drop trigger if exists finds_activity_day on public.finds;
create trigger finds_activity_day after update of status on public.finds for each row execute function public.note_activity_day();

-- The ring you wear.
alter table public.profiles add column if not exists ring text;
grant update (ring) on public.profiles to authenticated;

create or replace function public.check_worn_ring() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.ring is not null and new.ring is distinct from old.ring then
    if new.ring = 'pro_glow' then
      if not public.is_pro(new.id) then raise exception 'Pro glow is for Pro members' using errcode = '42501'; end if;
    elsif not exists (select 1 from public.user_rings r where r.user_id = new.id and r.ring = new.ring) then
      raise exception 'You haven''t earned that ring' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists profiles_check_ring on public.profiles;
create trigger profiles_check_ring before update of ring on public.profiles for each row execute function public.check_worn_ring();

-- The ring someone actually shows: what they wear, if they still own it (Pro glow only while they're Pro).
create or replace function public.shown_ring(uid uuid) returns text
language sql stable security definer set search_path = public as $$
  select case when p.ring is null then null
              when p.ring = 'pro_glow' then case when public.is_pro(p.id) then 'pro_glow' end
              when exists (select 1 from public.user_rings r where r.user_id = p.id and r.ring = p.ring) then p.ring end
    from public.profiles p where p.id = uid
$$;
revoke all on function public.shown_ring(uuid) from public, anon, authenticated;

-- Your rings: awards anything newly earned, then returns what you own, what you wear, progress, and your palette.
create or replace function public.my_rings()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  today date;
  streak int := 0;
  best int := 0;
  fresh text[];
begin
  if me is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select (now() at time zone coalesce(tz, 'America/New_York'))::date into today from public.profiles where id = me;

  -- Runs of consecutive days: the longest ever, and the one running now (today or through yesterday).
  with d as (select day, day - (row_number() over (order by day))::int as grp from public.activity_days where user_id = me),
       runs as (select min(day) as s, max(day) as e, count(*)::int as n from d group by grp)
  select coalesce(max(n), 0), coalesce(max(n) filter (where e >= today - 1), 0) into best, streak from runs;

  with earned as (
    select 'first_like'::text as ring where exists (select 1 from public.finds where user_id = me and status in ('liked', 'acquired'))
    union all select 'crew_3' where (select count(*) from public.friendships where status = 'accepted' and me in (requester, addressee)) >= 3
    union all select 'streak_7' where best >= 7
    union all select 'first_buy' where exists (select 1 from public.purchases where user_id = me)
  ), ins as (
    insert into public.user_rings (user_id, ring) select me, ring from earned on conflict do nothing returning ring
  )
  select coalesce(array_agg(ring), '{}') into fresh from ins;

  return jsonb_build_object(
    'owned', coalesce((select jsonb_agg(jsonb_build_object('ring', ring, 'earned_at', earned_at) order by earned_at)
                         from public.user_rings where user_id = me), '[]'::jsonb),
    'new', to_jsonb(fresh),
    'wearing', public.shown_ring(me),
    'pro', public.is_pro(me),
    'streak', streak,
    'friends', (select count(*) from public.friendships where status = 'accepted' and me in (requester, addressee)),
    'palette', (select taste_card -> 'palette' from public.profiles where id = me)
  );
end $$;
revoke all on function public.my_rings() from public, anon;
grant execute on function public.my_rings() to authenticated;

-- Friends' icons now come with the ring they show and their taste palette (for the "taste palette" color).
drop function if exists public.friend_icons();
create function public.friend_icons()
returns table (friend_id uuid, icon jsonb, ring text, palette jsonb) language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.settings -> 'avatar', '{}'::jsonb), public.shown_ring(p.id), p.taste_card -> 'palette'
    from public.friendships f
    join public.profiles p on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
   where auth.uid() in (f.requester, f.addressee)
$$;
revoke all on function public.friend_icons() from public, anon;
grant execute on function public.friend_icons() to authenticated;

-- The 1 of 1: Larry, Baget's creator.
insert into public.user_rings (user_id, ring)
select id, 'creator' from public.profiles where id = 'e7f350ab-b812-4718-9b07-490aba66465c'
on conflict do nothing;

-- Founding testers: everyone with an account today (not Baget's own system accounts).
insert into public.user_rings (user_id, ring)
select id, 'founding' from public.profiles where id::text not like '0a99e1e0-5eed-4d3e-8a00-%'
on conflict do nothing;

-- Start everyone wearing their best ring.
update public.profiles set ring = 'creator' where id = 'e7f350ab-b812-4718-9b07-490aba66465c' and ring is null
  and exists (select 1 from public.user_rings where user_id = profiles.id and ring = 'creator');
update public.profiles p set ring = 'founding' where p.ring is null
  and exists (select 1 from public.user_rings r where r.user_id = p.id and r.ring = 'founding');
