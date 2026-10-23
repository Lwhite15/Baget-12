-- Setup's taste check leads with the brands you just picked (up to 2 of each, half the deck), then the rest of the
-- category for range. It also draws on the store catalogs Baget reads itself, so picked brands are there to show.
drop function if exists public.taste_quiz(text[], int);
create or replace function public.taste_quiz(p_categories text[] default '{}', p_limit int default 10, p_brands text[] default '{}')
returns setof jsonb language sql stable security definer set search_path = public as $$
  with lim as (select greatest(1, least(coalesce(p_limit, 10), 10)) as n),
  want as (select distinct public.brand_key(b) as b from unnest(coalesce(p_brands, '{}')) b where btrim(b) <> ''),
  pool as (
    select l.*, public.brand_key(l.brand) as bk
      from public.listings l
     where (l.id in (select listing_id from public.listing_seen
                      where user_id = auth.uid() or user_id = '0a99e1e0-5eed-4d3e-8a00-00000000d3e0')
            or 'catalog' = any(l.tags))
       and l.image_url is not null and l.url is not null
       and not (l.tags && array['intel', 'search'])
       and l.last_seen_at > now() - interval '120 days'
       and (cardinality(coalesce(p_categories, '{}')) = 0 or l.category = any(p_categories))
  ),
  ranked as (
    select p.*, (p.bk in (select b from want)) as picked,
           row_number() over (partition by p.bk order by abs(hashtext(p.id::text || current_date::text))) as brand_rank
      from pool p
  ),
  mine as (   -- the picked brands, two each, taking turns
    select r.*, row_number() over (order by r.brand_rank, abs(hashtext(r.bk || current_date::text))) as o
      from ranked r where r.picked and r.brand_rank <= 2
  ),
  rest as (
    select r.*, row_number() over (order by abs(hashtext(r.id::text || current_date::text))) as o
      from ranked r where not r.picked and r.brand_rank = 1
  ),
  deck as (
    select m.*, 0 as part from mine m where m.o <= ceil((select n from lim) / 2.0)
    union all
    select x.*, 1 from rest x
  )
  select to_jsonb(d) - 'bk' - 'picked' - 'brand_rank' - 'o' - 'part'
    from deck d
   order by d.part, d.o
   limit (select n from lim)
$$;
revoke all on function public.taste_quiz(text[], int, text[]) from public, anon;
grant execute on function public.taste_quiz(text[], int, text[]) to authenticated;
