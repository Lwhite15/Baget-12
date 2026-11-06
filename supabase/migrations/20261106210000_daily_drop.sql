-- The daily drop: each morning every scout brings its 3 best finds; Today shows just those.
alter table public.finds add column if not exists drop_on date;
create index if not exists finds_drop_idx on public.finds (user_id, drop_on) where drop_on is not null;

/** Picks each active scout's 3 best open finds (one per product) for p_date. Safe to call twice: a day's drop is made once. */
create or replace function public.make_drop(p_user uuid, p_date date)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  select count(*) into n from public.finds where user_id = p_user and drop_on = p_date;
  if n > 0 then return n; end if;
  with cand as (
    select f.id, f.agent_id, f.score, f.created_at,
           lower(regexp_replace(l.title, '[^a-zA-Z0-9]+', '', 'g')) as tkey
      from public.finds f
      join public.listings l on l.id = f.listing_id
      join public.agents a on a.id = f.agent_id
     where f.user_id = p_user and f.status = 'open' and f.drop_on is null
       and f.created_at > now() - interval '14 days'
       and l.image_url is not null
       and not coalesce(a.paused, false)
       and not (coalesce(l.tags, '{}') && array['intel', 'search'])
  ),
  one_each as (select distinct on (tkey) * from cand order by tkey, score desc, created_at desc),
  ranked as (select id, row_number() over (partition by agent_id order by score desc, created_at desc) as r from one_each)
  update public.finds set drop_on = p_date where id in (select id from ranked where r <= 3);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.make_drop(uuid, date) from public, anon, authenticated;

/** The signed-in person's latest drop. Makes today's once their drop time has passed (default 9 AM local),
 *  or right away for someone who has never had one. */
create or replace function public.my_drop()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  p public.profiles;
  loc timestamp;
  hr integer;
  latest date;
begin
  if me is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select * into p from public.profiles where id = me;
  begin
    loc := now() at time zone coalesce(nullif(p.tz, ''), 'America/New_York');
  exception when others then
    loc := now() at time zone 'America/New_York';
  end;
  hr := least(23, greatest(0, coalesce(nullif(p.settings ->> 'dropHour', '')::integer, 9)));
  select max(drop_on) into latest from public.finds where user_id = me and drop_on is not null;
  if latest is null or (latest < loc::date and extract(hour from loc) >= hr) then
    perform public.make_drop(me, loc::date);
    select max(drop_on) into latest from public.finds where user_id = me and drop_on is not null;
  end if;
  return jsonb_build_object(
    'date', latest,
    'hour', hr,
    'ids', coalesce((select jsonb_agg(id order by score desc) from public.finds where user_id = me and drop_on = latest), '[]'::jsonb));
end $$;
revoke all on function public.my_drop() from public, anon;
grant execute on function public.my_drop() to authenticated;

/** For the products on someone's Today: which friends liked them (if those friends share their taste)
 *  or bought them (if they share purchases). Matches the same listing or the same product title. */
create or replace function public.friend_signals(p_listings uuid[])
returns table (listing_id uuid, names text[], bought boolean)
language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'sign in first' using errcode = '42501'; end if;
  return query
  with pals as (
    select case when fr.requester = me then fr.addressee else fr.requester end as id
      from public.friendships fr
     where fr.status = 'accepted' and (fr.requester = me or fr.addressee = me)
  ),
  theirs as (
    select f.user_id, f.status, l.id as lid, lower(l.title) as t,
           coalesce(nullif(split_part(pr.display_name, ' ', 1), ''), '@' || pr.handle) as who,
           coalesce(pr.share_purchases, false) as sp
      from public.finds f
      join pals on pals.id = f.user_id
      join public.profiles pr on pr.id = f.user_id
      join public.listings l on l.id = f.listing_id
     where coalesce(pr.share_taste, true)
       and (f.status = 'liked' or (f.status = 'acquired' and coalesce(pr.share_purchases, false)))
       and not exists (select 1 from public.user_blocks b
                        where (b.blocker = me and b.blocked = f.user_id) or (b.blocker = f.user_id and b.blocked = me))
  ),
  mine as (select l.id, lower(l.title) as t from public.listings l where l.id = any(p_listings[1:60]))
  select m.id, (array_agg(distinct th.who))[1:3], bool_or(th.status = 'acquired')
    from mine m join theirs th on th.lid = m.id or th.t = m.t
   group by m.id;
end $$;
revoke all on function public.friend_signals(uuid[]) from public, anon;
grant execute on function public.friend_signals(uuid[]) to authenticated;
