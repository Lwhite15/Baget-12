-- Privacy: For You and the setup taste check only show products your own scouts found, plus Baget's house catalog
-- (gathered by Baget's own account). Nothing another person's scouts found, and no counts across people.
--   * listing_seen: which account's scouts came across which product (every product a sweep returns, find or not).
--   * The house account hunts every category once a day so new users always have something to rate and browse.

create table if not exists public.listing_seen (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  listing_id uuid not null references public.listings (id) on delete cascade,
  seen_at    timestamptz not null default now(),
  primary key (user_id, listing_id)
);
create index if not exists listing_seen_listing_idx on public.listing_seen (listing_id);
alter table public.listing_seen enable row level security;
revoke all on public.listing_seen from anon, authenticated;
grant select on public.listing_seen to authenticated;
drop policy if exists listing_seen_own on public.listing_seen;
create policy listing_seen_own on public.listing_seen for select to authenticated using (user_id = auth.uid());

-- Everything already in someone's Finds counts as seen by them.
insert into public.listing_seen (user_id, listing_id, seen_at)
select user_id, listing_id, min(created_at) from public.finds group by user_id, listing_id
on conflict do nothing;

-- The house catalog: Baget's own account (also the App Review demo) covers every category, once a day.
do $$
declare house constant uuid := '0a99e1e0-5eed-4d3e-8a00-00000000d3e0';
begin
  if exists (select 1 from public.profiles where id = house) then
    update public.profiles set settings = coalesce(settings, '{}'::jsonb) || '{"sweepMinutes": 1440}'::jsonb where id = house;
    insert into public.agents (user_id, name, mission_category, keywords, traits, makers, voice)
    select house, v.name, v.cat, v.kw, v.tr, v.mk, 'chill'
      from (values
        ('Streetwear Desk', 'apparel', '{hoodie,"graphic tee",jacket}'::text[], '{streetwear,oversized}'::text[], '{Supreme,Stussy,"Fear of God"}'::text[]),
        ('Car Lot', 'cars', '{"porsche 911","bmw m3"}'::text[], '{manual,"low miles"}'::text[], '{Porsche,BMW}'::text[]),
        ('Home Finds', 'furniture', '{"lounge chair",credenza}'::text[], '{"mid-century",walnut}'::text[], '{"Herman Miller",Hay}'::text[]),
        ('Accessory Scout', 'accessories', '{sunglasses,"crossbody bag"}'::text[], '{leather,minimal}'::text[], '{"Ray-Ban",Bottega}'::text[]),
        ('Collector', 'collectibles', '{"art toy",lego}'::text[], '{"limited edition"}'::text[], '{KAWS,Bearbrick}'::text[])
      ) as v(name, cat, kw, tr, mk)
     where not exists (select 1 from public.agents a where a.user_id = house and a.mission_category = v.cat);
  end if;
end $$;

-- Setup taste check: the house catalog in the categories you picked (plus anything your own scouts already found).
create or replace function public.taste_quiz(p_categories text[] default '{}', p_limit int default 10)
returns setof jsonb language sql stable security definer set search_path = public as $$
  with pool as (
    select l.*, row_number() over (partition by lower(l.brand) order by l.last_seen_at desc) as brand_rank
      from public.listings l
     where l.id in (select listing_id from public.listing_seen
                     where user_id = auth.uid() or user_id = '0a99e1e0-5eed-4d3e-8a00-00000000d3e0')
       and l.image_url is not null and l.url is not null
       and l.last_seen_at > now() - interval '120 days'
       and (cardinality(coalesce(p_categories, '{}')) = 0 or l.category = any(p_categories))
  )
  select to_jsonb(p) - 'brand_rank'
    from pool p
   where p.brand_rank = 1
   order by abs(hashtext(p.id::text || current_date::text)) % 1000
   limit greatest(1, least(coalesce(p_limit, 10), 10))
$$;
revoke all on function public.taste_quiz(text[], int) from public, anon;
grant execute on function public.taste_quiz(text[], int) to authenticated;

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
  -- Only products your own scouts came across, plus Baget's house catalog (its own account, never a real person's).
  pool as (
    select listing_id from public.listing_seen where user_id = uid or user_id = '0a99e1e0-5eed-4d3e-8a00-00000000d3e0'
  ),
  cand as (
    select l.id, l.brand, l.category, l.title, l.price, l.market, l.first_seen_at, 0 as pop_n,
           fe.feats,
           (select coalesce(sum(t.w), 0) from taste t where t.f = any(fe.feats)) as fs,
           (select count(*) from kw where l.title ilike '%' || kw.k || '%') as kh,
           (select kw.k from kw where l.title ilike '%' || kw.k || '%' limit 1) as top_k,
           (select t.f from taste t where t.w > 0.75 and t.f = any(fe.feats) order by t.w desc limit 1) as top_f
      from public.listings l
      cross join lateral (
        select array['b:' || lower(l.brand), 'c:' || l.category] || coalesce(array(select 't:' || lower(x) from unnest(l.traits) x), '{}') as feats
      ) fe
     where l.id in (select listing_id from pool)
       and l.image_url is not null and l.url is not null
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
