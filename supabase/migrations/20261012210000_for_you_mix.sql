-- For You, round two: your own unacted finds (liked first) now take every third slot instead of only
-- filling in at the end, so a feed is mostly things that fit you even before the shared catalog grows.
-- Fresh matches from the catalog still lead, and every 5th slot is still something new to try.
create or replace function public.for_you(p_limit int default 24)
returns setof jsonb language plpgsql stable security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  lim int := greatest(1, least(coalesce(p_limit, 24), 60));
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  return query
  with
  taste as (select * from public.taste_features(uid)),
  kw as (select distinct lower(k) as k from public.agents a, unnest(a.keywords) k where a.user_id = uid and length(k) >= 3),
  cap as (select max(price_note) as p from public.agents where user_id = uid and price_note > 0),
  hidden as (
    select listing_id from public.finds where user_id = uid
    union select listing_id from public.feed_reactions where user_id = uid and action in ('dismiss', 'like')
  ),
  pop as (
    select listing_id, count(distinct user_id) as n from (
      select listing_id, user_id from public.finds where status in ('liked', 'acquired')
      union all select listing_id, user_id from public.feed_reactions where action in ('like', 'buy')) z
    group by listing_id
  ),
  cand as (
    select l.id, l.brand, l.category, l.title, l.price, l.market, l.first_seen_at, coalesce(p.n, 0) as pop_n,
           fe.feats,
           (select coalesce(sum(t.w), 0) from taste t where t.f = any(fe.feats)) as fs,
           (select count(*) from kw where l.title ilike '%' || kw.k || '%') as kh,
           (select kw.k from kw where l.title ilike '%' || kw.k || '%' limit 1) as top_k,
           (select t.f from taste t where t.w > 0.75 and t.f = any(fe.feats) order by t.w desc limit 1) as top_f
      from public.listings l
      left join pop p on p.listing_id = l.id
      cross join lateral (
        select array['b:' || lower(l.brand), 'c:' || l.category] || coalesce(array(select 't:' || lower(x) from unnest(l.traits) x), '{}') as feats
      ) fe
     where l.image_url is not null and l.url is not null
       and l.last_seen_at > now() - interval '90 days'
       and not exists (select 1 from hidden h where h.listing_id = l.id)
  ),
  scored as (
    select c.*,
           c.fs + 3 * c.kh
           + 1.5 * ln(1 + c.pop_n)
           + 1.5 * exp(-extract(epoch from now() - c.first_seen_at) / 86400.0 / 14)
           + case when c.market is not null and c.price is not null and c.market > c.price * 1.15 then 1 else 0 end
           - case when (select p from cap) is not null and c.price > (select p from cap) then 2 else 0 end
           + (abs(hashtext(c.id::text || current_date::text)) % 100) / 100.0 as score,
           (c.fs > 0.75 or c.kh > 0) as matched
      from cand c
  ),
  varied as (
    select s.*,
           s.score - 1.5 * (row_number() over (partition by lower(s.brand) order by s.score desc) - 1)
                   - 0.4 * (row_number() over (partition by s.category order by s.score desc) - 1) as adj
      from scored s
     where s.fs > -2   -- clearly not your thing stays out, even as exploration
  ),
  main as (select v.*, row_number() over (order by v.adj desc) as r from varied v where v.matched),
  explore as (select v.*, row_number() over (order by v.adj desc) as r from varied v where not v.matched),
  picked as (
    select m.id, m.r + (m.r - 1) / 4 + 0.1 as pos, 'match' as kind, m.top_k, m.top_f, m.pop_n, m.brand, m.category, m.adj from main m
    union all
    select e.id, e.r * 5 + 0.2, 'explore', e.top_k, e.top_f, e.pop_n, e.brand, e.category, e.adj from explore e
  ),
  -- Your own finds you haven't acted on fill every third slot (not the 5 strongest new ones: Today's Drop shows those).
  top_new as (
    select id from public.finds where user_id = uid and status = 'open' order by score desc, created_at desc limit 5
  ),
  yours as (
    select y.id, y.r * 3 as pos, y.find_id from (
      select f.listing_id as id, f.id as find_id,
             row_number() over (order by (f.status = 'liked') desc, f.score desc, f.created_at desc) as r
        from public.finds f join public.listings l on l.id = f.listing_id
       where f.user_id = uid and f.status in ('open', 'liked') and l.image_url is not null
         and f.id not in (select id from top_new)) y
  ),
  feed as (
    select p.id, p.pos, p.kind, null::uuid as find_id,
           case when p.top_k is not null then 'Matches "' || p.top_k || '"'
                when p.top_f like 'b:%' and p.brand <> '' then 'Because you like ' || p.brand
                when p.top_f like 't:%' then 'More ' || substr(p.top_f, 3)
                when p.top_f like 'c:%' then 'For your ' || p.category || ' taste'
                when p.kind = 'explore' and p.pop_n > 0 then 'Popular on Baget'
                else 'Something new to try' end as reason
      from picked p
    union all
    select y.id, y.pos + 0.3, 'yours', y.find_id, 'From your finds' from yours y
  )
  select jsonb_build_object('listing', to_jsonb(l), 'reason', f.reason, 'kind', f.kind, 'find_id', f.find_id)
    from (select * from feed order by pos limit lim) f
    join public.listings l on l.id = f.id
   order by f.pos;
end $$;
revoke all on function public.for_you(int) from public, anon;
grant execute on function public.for_you(int) to authenticated;
