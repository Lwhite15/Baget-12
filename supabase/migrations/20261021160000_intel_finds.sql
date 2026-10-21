-- Intel and search pages: scouts keep droplists, release calendars, news and reference pages ("intel") and dealer
-- results pages ("search") as labeled finds instead of dropping them. For You stays products only.
create or replace function public.for_you(p_limit int default 24)
returns setof jsonb language plpgsql stable security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  lim int := greatest(1, least(coalesce(p_limit, 24), 60));
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  return query
  with
  taste as materialized (select f, sum(w) as w from public.taste_features(uid) group by f),
  kw as (select distinct lower(k) as k from public.agents a, unnest(a.keywords) k where a.user_id = uid and length(k) >= 3),
  cap as (select max(price_note) as p from public.agents where user_id = uid and price_note > 0),
  hidden as (
    select listing_id from public.finds where user_id = uid
    union select listing_id from public.feed_reactions where user_id = uid and action in ('dismiss', 'like')
  ),
  -- Only products your own scouts came across, plus Baget's house catalog (its own account, never a real person's).
  pool as (
    select listing_id from public.listing_seen where user_id = uid or user_id = '0a99e1e0-5eed-4d3e-8a00-00000000d3e0'
  ),
  -- Same scoring as before, computed as joins (one pass over the taste signals) instead of a scan per product.
  base as (
    select l.id, l.brand, l.category, l.title, l.price, l.market, l.first_seen_at,
           array['b:' || lower(l.brand), 'c:' || l.category] || coalesce(array(select 't:' || lower(x) from unnest(l.traits) x), '{}') as feats
      from public.listings l
     where l.id in (select listing_id from pool)
       and l.image_url is not null and l.url is not null
       and not (l.tags && array['intel', 'search'])
       and l.last_seen_at > now() - interval '90 days'
       and not exists (select 1 from hidden h where h.listing_id = l.id)
  ),
  tf as (
    select b.id, sum(t.w) as fs, (array_agg(t.f order by t.w desc) filter (where t.w > 0.75))[1] as top_f
      from base b cross join lateral (select distinct x from unnest(b.feats) x) as bf(f) join taste t on t.f = bf.f
     group by b.id
  ),
  kh as (
    select b.id, count(*) as kh, min(kw.k) as top_k
      from base b join kw on b.title ilike '%' || kw.k || '%'
     group by b.id
  ),
  cand as (
    select b.id, b.brand, b.category, b.title, b.price, b.market, b.first_seen_at, 0 as pop_n, b.feats,
           coalesce(tf.fs, 0) as fs, coalesce(kh.kh, 0) as kh, kh.top_k, tf.top_f
      from base b left join tf on tf.id = b.id left join kh on kh.id = b.id
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
    select f.id from public.finds f join public.listings l on l.id = f.listing_id
     where f.user_id = uid and f.status = 'open' and not (l.tags && array['intel', 'search']) order by f.score desc, f.created_at desc limit 5
  ),
  yours as (
    select y.id, y.r * 3 as pos, y.find_id from (
      select f.listing_id as id, f.id as find_id,
             row_number() over (order by (f.status = 'liked') desc, f.score desc, f.created_at desc) as r
        from public.finds f join public.listings l on l.id = f.listing_id
       where f.user_id = uid and f.status in ('open', 'liked') and l.image_url is not null and not (l.tags && array['intel', 'search'])
         and f.id not in (select id from top_new)) y
  ),
  feed as (
    select p.id, p.pos, p.kind, null::uuid as find_id,
           case when p.top_k is not null then 'Matches "' || p.top_k || '"'
                when p.top_f like 'b:%' and p.brand <> '' then 'Because you like ' || p.brand
                when p.top_f like 't:%' then 'More ' || substr(p.top_f, 3)
                when p.top_f like 'c:%' then 'For your ' || p.category || ' taste'
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
