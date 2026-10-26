-- Birthdays with friends: who has one coming up (Friends tab), and a heads-up note a week before and on the day.
-- A birthday is something you choose to add (Settings), so every accepted friend sees it when it's coming up.
-- Gift ideas for their taste still need both of you sharing taste (friend_profile's gifts).

-- A month-day in a given year (Feb 29 falls on Feb 28 in other years).
create or replace function public.mmdd_on(mmdd text, y int) returns date language sql immutable as $$
  -- Days past the end of the month (Feb 29 in other years, "04-31") fall on the month's last day.
  select make_date(y, m, 1) + (least(d, extract(day from make_date(y, m, 1) + interval '1 month' - interval '1 day')::int) - 1)
    from (select substr(mmdd, 1, 2)::int as m, substr(mmdd, 4, 2)::int as d) x
$$;
-- The next time a month-day comes around, on or after `today`.
create or replace function public.next_birthday(mmdd text, today date) returns date language sql immutable as $$
  select case when d >= today then d else public.mmdd_on(mmdd, extract(year from today)::int + 1) end
    from (select public.mmdd_on(mmdd, extract(year from today)::int) as d) x
$$;

-- Friends whose birthday is within the next p_days days (today counts), soonest first.
create or replace function public.upcoming_birthdays(p_days int default 21)
returns table (friend_id uuid, name text, handle text, birthday text, days int, shares boolean)
language sql stable security definer set search_path = public as $$
  with me as (select p.id, p.share_taste, (now() at time zone coalesce(p.tz, 'America/New_York'))::date as today
                from public.profiles p where p.id = auth.uid())
  select p.id, p.display_name, p.handle, p.birthday,
         (public.next_birthday(p.birthday, me.today) - me.today)::int,
         coalesce(p.share_taste, false) and coalesce(me.share_taste, false)
    from me
    join public.friendships f on me.id in (f.requester, f.addressee) and f.status = 'accepted'
    join public.profiles p on p.id = case when f.requester = me.id then f.addressee else f.requester end
   where p.birthday is not null
     and public.next_birthday(p.birthday, me.today) - me.today <= greatest(0, least(p_days, 60))
   order by 5, 2
$$;
revoke all on function public.upcoming_birthdays(int) from public, anon;
grant execute on function public.upcoming_birthdays(int) to authenticated;

-- Heads-up notes: 7 days before ("in a week") and on the day. Once each per friend per birthday.
create or replace function public.birthday_nudges()
returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; r record;
begin
  for r in
    select me.id as uid, p.id as fid, coalesce(nullif(p.display_name, ''), '@' || p.handle) as who,
           public.next_birthday(p.birthday, (now() at time zone me.tz)::date) - (now() at time zone me.tz)::date as days,
           coalesce(p.share_taste, false) and coalesce(me.share_taste, false) as shares
      from public.friendships f
      join public.profiles me on me.id in (f.requester, f.addressee)
      join public.profiles p on p.id = case when f.requester = me.id then f.addressee else f.requester end
     where f.status = 'accepted' and p.birthday is not null
  loop
    continue when r.days not in (0, 7);
    continue when exists (select 1 from public.notes x where x.user_id = r.uid and x.friend_id = r.fid and x.kind = 'friend'
                            and x.body like '%birthday%' and x.created_at > now() - interval '5 days'
                            and (r.days = 7 or x.body like '%today%'));
    insert into public.notes (user_id, friend_id, sender_name, kind, body)
    values (r.uid, r.fid, 'Baget', 'friend',
            case when r.days = 0 then 'It''s ' || r.who || '''s birthday today 🎂 Send them some love.'
                 when r.shares then r.who || '''s birthday is in a week 🎁 Your scouts picked a few gifts for their taste. Open Friends to see them.'
                 else r.who || '''s birthday is in a week 🎁 Open Friends to send them something.' end);
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.birthday_nudges() from public, anon, authenticated;
grant execute on function public.birthday_nudges() to service_role;
