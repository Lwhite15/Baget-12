-- A scout with nothing in today's drop (its first finds landed after the drop was made, or it was just added)
-- gets its 3 best added the same day, instead of waiting for tomorrow.
create or replace function public.make_drop(p_user uuid, p_date date)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
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
       -- only scouts that have nothing in this day's drop yet
       and not exists (select 1 from public.finds d where d.user_id = p_user and d.agent_id = f.agent_id and d.drop_on = p_date)
  ),
  one_each as (select distinct on (tkey) * from cand order by tkey, score desc, created_at desc),
  ranked as (select id, row_number() over (partition by agent_id order by score desc, created_at desc) as r from one_each)
  update public.finds set drop_on = p_date where id in (select id from ranked where r <= 3);
  select count(*) into n from public.finds where user_id = p_user and drop_on = p_date;
  return n;
end $$;
revoke all on function public.make_drop(uuid, date) from public, anon, authenticated;

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
  -- Make today's once the drop time has passed (or right away the first time); top up today's for scouts missing from it.
  if latest is null or latest = loc::date or (latest < loc::date and extract(hour from loc) >= hr) then
    perform public.make_drop(me, case when latest is null or extract(hour from loc) >= hr then loc::date else latest end);
    select max(drop_on) into latest from public.finds where user_id = me and drop_on is not null;
  end if;
  return jsonb_build_object(
    'date', latest,
    'hour', hr,
    'ids', coalesce((select jsonb_agg(id order by score desc) from public.finds where user_id = me and drop_on = latest), '[]'::jsonb));
end $$;
revoke all on function public.my_drop() from public, anon;
grant execute on function public.my_drop() to authenticated;
