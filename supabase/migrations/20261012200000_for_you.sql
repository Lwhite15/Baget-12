-- "For You": a personal feed on the Today screen that is never empty.
--
-- How it ranks (no AI call, so it's instant and free, and works even when no sweep found anything new):
--   1. Taste profile. Every signal becomes weighted features: brand (b:), category (c:) and trait (t:).
--        agent briefs (makers, traits, mission)          +2 / +1.5 / +2
--        what agents learned from your likes and passes   that weight
--        finds: liked +3, bought +4, watching +2, open +0.5, passed "not my style" -3, other passes and removals -0.5
--        For You: like +3, buy tap +4, open +0.5, "not for me" -2.5
--      Reactions fade with a 30-day half-life-ish decay, so taste can change.
--   2. Candidates. Every product any Baget agent has found with a photo and a store link (the shared catalog),
--      minus anything already in your Finds and anything you said "not for me" to.
--   3. Score = taste match + 3 per keyword in the title + popularity (people liking it) + freshness
--      + a small deal bonus - over your price note + a daily shuffle, so the feed changes every day.
--   4. Variety: repeats of the same brand or category are pushed down, and every 5th slot is "something new
--      to try" from outside your usual taste, so it keeps learning instead of narrowing.
--   5. If the catalog runs short, your own open and liked finds fill the rest. So there's always something.

create table if not exists public.feed_reactions (
  user_id    uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  listing_id uuid not null references public.listings (id) on delete cascade,
  action     text not null check (action in ('like','dismiss','open','buy')),
  created_at timestamptz not null default now(),
  primary key (user_id, listing_id, action)
);
alter table public.feed_reactions enable row level security;
revoke all on public.feed_reactions from anon, authenticated;
grant select, insert, delete on public.feed_reactions to authenticated;
drop policy if exists feed_reactions_own on public.feed_reactions;
create policy feed_reactions_own on public.feed_reactions for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Your weighted taste features (shared by for_you and taste_top).
create or replace function public.taste_features(uid uuid)
returns table (f text, w float8) language sql stable security definer set search_path = public as $$
  with ag as (select * from public.agents where user_id = uid),
  fr as (
    select l.brand, l.category, l.traits,
           (case when f.status = 'liked' then 3 when f.status = 'acquired' then 4
                 when f.status = 'passed' and coalesce(f.pass_reason, '') like '%style%' then -3
                 when f.status in ('passed', 'removed') then -0.5 else 0.5 end
            + case when f.watching then 2 else 0 end)
           * exp(-extract(epoch from now() - f.created_at) / 86400.0 / 30) as w0
      from public.finds f join public.listings l on l.id = f.listing_id
     where f.user_id = uid
    union all
    select l.brand, l.category, l.traits,
           (case r.action when 'like' then 3 when 'buy' then 4 when 'open' then 0.5 else -2.5 end)
           * exp(-extract(epoch from now() - r.created_at) / 86400.0 / 30)
      from public.feed_reactions r join public.listings l on l.id = r.listing_id
     where r.user_id = uid
  ),
  sig as (
    select 'b:' || lower(m) as f, 2.0::float8 as w from ag, unnest(ag.makers) m
    union all select 't:' || lower(t), 1.5 from ag, unnest(ag.traits) t
    union all select 'c:' || ag.mission_category, 2.0 from ag where ag.mission_category is not null
    union all select p || lower(e.key), greatest(-6, least(6, (e.value #>> '{}')::float8))
      from ag, jsonb_each(ag.learned) e, unnest(array['b:', 't:']) p
     where jsonb_typeof(e.value) = 'number' and e.key not like '\_\_%'
    union all select 'b:' || lower(fr.brand), fr.w0 from fr where fr.brand <> ''
    union all select 'c:' || fr.category, fr.w0 * 0.5 from fr
    union all select 't:' || lower(t), fr.w0 * 0.6 from fr, unnest(fr.traits) t
  )
  select f, sum(w) from sig where f is not null and length(f) > 2 group by f
$$;
revoke all on function public.taste_features(uuid) from public, anon, authenticated;

-- The strongest likes and dislikes, for the "what Baget's learned" strip.
create or replace function public.taste_top(p_limit int default 8)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('feature', f, 'weight', round(w::numeric, 1)) order by abs(w) desc), '[]'::jsonb)
    from (select * from public.taste_features(auth.uid()) where abs(w) >= 1 order by abs(w) desc limit greatest(1, least(p_limit, 20))) t
$$;
revoke all on function public.taste_top(int) from public, anon;
grant execute on function public.taste_top(int) to authenticated;

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
    select m.id, m.r + (m.r - 1) / 4 as pos, 'match' as kind, m.top_k, m.top_f, m.pop_n, m.brand, m.category, m.adj from main m
    union all
    select e.id, e.r * 5, 'explore', e.top_k, e.top_f, e.pop_n, e.brand, e.category, e.adj from explore e
  ),
  yours as (
    select f.listing_id as id, 1000 + row_number() over (order by (f.status = 'liked') desc, f.score desc, f.created_at desc) as pos,
           f.id as find_id
      from public.finds f join public.listings l on l.id = f.listing_id
     where f.user_id = uid and f.status in ('open', 'liked') and l.image_url is not null
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
    select y.id, y.pos, 'yours', y.find_id, 'From your finds' from yours y
  )
  select jsonb_build_object('listing', to_jsonb(l), 'reason', f.reason, 'kind', f.kind, 'find_id', f.find_id)
    from (select * from feed order by pos limit lim) f
    join public.listings l on l.id = f.id
   order by f.pos;
end $$;
revoke all on function public.for_you(int) from public, anon;
grant execute on function public.for_you(int) to authenticated;
