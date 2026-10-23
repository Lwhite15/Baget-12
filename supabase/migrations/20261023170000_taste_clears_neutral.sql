-- Clearing Finds isn't a verdict. Tapping Clear removed hundreds of finds at once, and each counted as a small dislike,
-- so the whole category someone hunts ended up looking disliked and For You had nothing to suggest.
--   * Removed finds and passes for reasons other than style ("too pricey", "have one", "not now") are neutral.
--   * Disliking products never makes a category look disliked: categories only learn from what you like.
--   * No single brand, trait or category can sink below -6, so a run of passes can't bury everything.
create or replace function public.taste_features(uid uuid)
returns table (f text, w float8) language sql stable security definer set search_path = public as $$
  with ag as (select * from public.agents where user_id = uid),
  fr as (
    select l.brand, l.category, l.traits,
           (case when f.status = 'liked' then 3 when f.status = 'acquired' then 4
                 when f.status = 'passed' and coalesce(f.pass_reason, '') like '%style%' then -3
                 when f.status in ('passed', 'removed') then 0 else 0.5 end
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
    union all select 'b:' || lower(fr.brand), fr.w0 from fr where fr.brand <> '' and fr.w0 <> 0
    union all select 'c:' || fr.category, fr.w0 * 0.5 from fr where fr.w0 > 0
    union all select 't:' || lower(t), fr.w0 * 0.6 from fr, unnest(fr.traits) t where fr.w0 <> 0
  )
  select f, greatest(-6, sum(w)) from sig where f is not null and length(f) > 2 group by f
$$;
revoke all on function public.taste_features(uuid) from public, anon, authenticated;
