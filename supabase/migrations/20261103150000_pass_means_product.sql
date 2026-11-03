-- Passing on a product passes on it everywhere: the same item from another store doesn't come back (testers saw a
-- passed product return from a different vendor). One product = same brand and nearly the same title words.

create or replace function public.product_words(t text) returns text[]
language sql immutable set search_path = public as $$
  -- Model numbers count, however short ("90" vs "95", "58" vs "54"); filler words don't.
  select coalesce(array_agg(distinct w), '{}') from regexp_split_to_table(lower(coalesce(t, '')), '[^a-z0-9]+') w
   where (length(w) > 2 or w ~ '[0-9]')
     and w not in ('the', 'and', 'for', 'with', 'new', 'men', 'mens', 'women', 'womens', 'unisex', 'size', 'shoe', 'shoes',
                   'sneaker', 'sneakers', 'eau', 'parfum', 'toilette', 'edp', 'edt', 'spray')
$$;

create or replace function public.same_product(a text, b text) returns boolean
language sql immutable set search_path = public as $$
  with x as (select public.product_words(a) as wa, public.product_words(b) as wb),
       o as (select cardinality(wa) as na, cardinality(wb) as nb,
                    (select count(*) from unnest(wa) w where w = any(wb)) as hit from x)
  select na > 0 and nb > 0
     and least(hit::numeric / na, hit::numeric / nb) >= 0.7
     and greatest(hit::numeric / na, hit::numeric / nb) >= 0.85
     -- Different model numbers are different products.
     and not exists (select 1 from x, unnest(x.wa) w where w ~ '[0-9]' and not w = any(x.wb)
                     and exists (select 1 from unnest(x.wb) v where v ~ '[0-9]' and not v = any(x.wa)))
    from o
$$;

-- New finds: never the same product as one they already have (any store, any status).
create or replace function public.record_finds(p_agent uuid, p_finds jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare
  ag public.agents;
  f jsonb;
  fid uuid;
  n int := 0;
  cap int;
  today int;
  noted int := 0;
  notes_today int;
begin
  select * into ag from public.agents where id = p_agent;
  if not found then return 0; end if;
  cap := case when public.is_pro(ag.user_id) then 60 else 30 end;
  select count(*) into today from public.finds where agent_id = ag.id and created_at > now() - interval '24 hours';
  select count(*) into notes_today from public.notes
   where agent_id = ag.id and find_id is not null and created_at > now() - interval '24 hours';
  for f in select x from jsonb_array_elements(case when jsonb_typeof(p_finds) = 'array' then p_finds else '[]'::jsonb end) x
            order by coalesce((x ->> 'score')::int, 0) desc loop
    exit when today + n >= cap;
    -- The same product from another store counts as already shown (passed, liked or still open): skip it.
    continue when exists (
      select 1 from public.finds x join public.listings lx on lx.id = x.listing_id, public.listings ln
       where ln.id = (f ->> 'listing_id')::uuid and x.user_id = ag.user_id and x.listing_id <> ln.id
         and public.brand_key(lx.brand) = public.brand_key(ln.brand) and public.same_product(lx.title, ln.title));
    insert into public.finds (user_id, agent_id, listing_id, score, why)
    values (ag.user_id, ag.id, (f ->> 'listing_id')::uuid, (f ->> 'score')::int,
            coalesce(public.jsonb_texts(f -> 'why'), '{}'))
    on conflict (user_id, listing_id) do nothing
    returning finds.id into fid;
    if fid is not null then
      n := n + 1;
      if f ? 'note' and noted < 2 and notes_today + noted < 4 and coalesce((f ->> 'score')::int, 0) >= 60 then
        insert into public.notes (user_id, agent_id, sender_name, kind, body, find_id, held_for_morning)
        values (ag.user_id, ag.id, ag.name, f -> 'note' ->> 'kind', left(f -> 'note' ->> 'body', 500), fid,
                coalesce((f -> 'note' ->> 'held')::boolean, false));
        noted := noted + 1;
      end if;
    end if;
    fid := null;
  end loop;
  update public.agents set last_swept_at = now() where id = ag.id;
  return n;
end $$;

-- Passing on a find also passes its open twins from other stores.
create or replace function public.pass_twins() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'passed' and old.status is distinct from new.status and pg_trigger_depth() = 1 then
    update public.finds x set status = new.status, pass_reason = coalesce(new.pass_reason, 'same product')
      from public.listings lx, public.listings ln
     where x.user_id = new.user_id and x.id <> new.id and x.status = 'open'
       and lx.id = x.listing_id and ln.id = new.listing_id
       and public.brand_key(lx.brand) = public.brand_key(ln.brand) and public.same_product(lx.title, ln.title);
  end if;
  return new;
end $$;
drop trigger if exists finds_pass_twins on public.finds;
create trigger finds_pass_twins after update of status on public.finds for each row execute function public.pass_twins();

-- For You: not the same product from another store once passed.
create or replace function public.for_you(p_limit int default 24)
returns setof jsonb language plpgsql stable security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  lim int := greatest(1, least(coalesce(p_limit, 24), 200));
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  if not exists (select 1 from public.agents a where a.user_id = uid) then return; end if;
  return query
  with
  taste as materialized (select f, sum(w) as w from public.taste_features(uid) group by f),
  kw as (select distinct lower(k) as k from public.agents a, unnest(a.keywords) k where a.user_id = uid and length(k) >= 3),
  cap as (select max(price_note) as p from public.agents where user_id = uid and price_note > 0),
  -- What they hunt: their scouts' categories, plus the categories a typed-in mission's finds actually landed in
  -- (a vinyl scout's records), never every category just because one scout has a custom mission.
  cats as (
    select distinct a.mission_category as c from public.agents a where a.user_id = uid and a.mission_category is not null
    union
    select distinct l.category from public.finds f join public.agents a on a.id = f.agent_id join public.listings l on l.id = f.listing_id
     where f.user_id = uid and a.mission_category is null and l.category is not null
  ),
  -- Neighbors a discovery can come from, only when it shares something they like. Never unrelated (no cars for a perfume person).
  near as (
    select distinct n.c from cats join (values
      ('sneakers', 'apparel'), ('sneakers', 'accessories'), ('apparel', 'sneakers'), ('apparel', 'accessories'),
      ('accessories', 'apparel'), ('accessories', 'watches'), ('watches', 'accessories'),
      ('furniture', 'collectibles'), ('collectibles', 'furniture'),
      ('fragrance', 'accessories'), ('fragrance', 'watches')) as n(f, c) on n.f = cats.c
     where n.c not in (select c from cats)
  ),
  -- Brands they already know: anything their scouts showed them or they reacted to.
  known as (
    select distinct public.brand_key(l.brand) as b from public.finds f join public.listings l on l.id = f.listing_id where f.user_id = uid and l.brand <> ''
    union select distinct public.brand_key(l.brand) from public.feed_reactions r join public.listings l on l.id = r.listing_id where r.user_id = uid and l.brand <> ''
  ),
  anycat as (select false as v),
  hidden as (
    select listing_id from public.finds where user_id = uid
    union select listing_id from public.feed_reactions where user_id = uid and action in ('dismiss', 'like')
  ),
  -- Only products your own scouts came across, plus Baget's house catalog (its own account, never a real person's).
  pool as (
    select listing_id from public.listing_seen where user_id = uid or user_id = '0a99e1e0-5eed-4d3e-8a00-00000000d3e0'
    -- Store catalogs Baget reads itself (public store listings, not anyone's scouts), in what they hunt or its neighbors.
    union
    select l.id from public.listings l
     where 'catalog' = any(l.tags) and l.last_seen_at > now() - interval '30 days'
       and (l.category in (select c from cats) or l.category in (select c from near) or (select v from anycat))
  ),
  base as (
    select l.id, l.brand, l.category, l.title, l.price, l.market, l.first_seen_at, l.traits,
           array['b:' || public.brand_key(l.brand), 'c:' || l.category] || coalesce(array(select 't:' || lower(x) from unnest(l.traits) x), '{}') as feats
      from public.listings l
     where l.id in (select listing_id from pool)
       and l.image_url is not null and l.url is not null
       and not (l.tags && array['intel', 'search'])
       and l.last_seen_at > now() - interval '90 days'
       and (l.category in (select c from cats) or l.category in (select c from near) or (select v from anycat))
       and not exists (select 1 from hidden h where h.listing_id = l.id)
       -- Nor the same product from another store, once they've passed on it or cleared it.
       and not exists (select 1 from public.finds px join public.listings pl on pl.id = px.listing_id
                        where px.user_id = uid and px.status in ('passed', 'removed')
                          and public.brand_key(pl.brand) = public.brand_key(l.brand) and public.same_product(pl.title, l.title))
       and not public.wrong_dept(l.title || ' ' || array_to_string(l.traits, ' '),
                                 (select settings ->> 'department' from public.profiles where id = uid), l.category)
  ),
  -- The finds that seed "comparable": liked ones first, then the newest.
  seeds as (
    select l.id, l.category, public.brand_key(l.brand) as b, l.traits, l.price, l.title
      from public.finds f join public.listings l on l.id = f.listing_id
     where f.user_id = uid and f.status in ('open', 'liked', 'acquired') and not (l.tags && array['intel', 'search'])
     order by (f.status <> 'open') desc, f.created_at desc
     limit 25
  ),
  sim_all as (
    select b.id, s.title as seed,
           (case when s.b <> '' and public.brand_key(b.brand) = s.b then 2 else 0 end)
           + (select count(*) from unnest(b.traits) x where lower(x) in (select lower(y) from unnest(s.traits) y))
           + (case when s.price > 0 and b.price between s.price * 0.6 and s.price * 1.6 then 1 else 0 end) as pts
      from base b join seeds s on s.category = b.category
     where (b.category in (select c from cats) or (select v from anycat))
       and public.title_overlap(s.title, b.title) < 0.6 and public.title_overlap(b.title, s.title) < 0.6
  ),
  sim as (
    select distinct on (id) id, seed, pts from sim_all where pts >= 2 order by id, pts desc
  ),
  sim_titled as (select s.*, l.title, public.brand_key(l.brand) as brand,
                        row_number() over (partition by public.brand_key(l.brand) order by s.pts desc, s.id) as rb
                   from sim s join public.listings l on l.id = s.id),
  -- One of each product: the same item from two stores shows once.
  sim_ranked as (
    -- At most 2 from any one brand, spread out: brand's best first, then the next brand's best.
    select s.id, s.seed, s.pts, row_number() over (order by s.rb, s.pts desc, s.id) as r from sim_titled s
     where s.rb <= 2 and not exists (select 1 from sim_titled o where (o.pts > s.pts or (o.pts = s.pts and o.id < s.id))
                         and public.title_overlap(s.title, o.title) >= 0.6)
  ),
  sim_kept as (select * from sim_ranked where r <= ceil(lim / 4.0) + 2),
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
           (b.category in (select c from cats) or (select v from anycat)) as own,
           (public.brand_key(b.brand) not in (select b from known) and b.brand <> '') as new_brand,
           coalesce(tf.fs, 0) as fs, coalesce(kh.kh, 0) as kh, kh.top_k, tf.top_f
      from base b left join tf on tf.id = b.id left join kh on kh.id = b.id
     where b.id not in (select id from sim_kept)
  ),
  scored as (
    select c.*,
           c.fs + 3 * c.kh
           + 1.5 * exp(-extract(epoch from now() - c.first_seen_at) / 86400.0 / 14)
           + case when c.market is not null and c.price is not null and c.market > c.price * 1.15 then 1 else 0 end
           - case when (select p from cap) is not null and c.price > (select p from cap) then 2 else 0 end
           + (abs(hashtext(c.id::text || current_date::text)) % 100) / 100.0 as score,
           (c.fs > 0.75 or c.kh > 0) as matched
      from cand c
  ),
  varied as (
    select s.*,
           s.score - 1.5 * (row_number() over (partition by public.brand_key(s.brand) order by s.score desc) - 1)
                   - 0.4 * (row_number() over (partition by s.category order by s.score desc) - 1) as adj
      from scored s
     where s.fs > -2
  ),
  -- Taste matches: at most two from any one brand, so one house can't take over the row.
  main as (select m.*, row_number() over (order by m.adj desc) as r from (
             select v.*, row_number() over (partition by public.brand_key(v.brand) order by v.adj desc) as mb
               from varied v where v.matched and v.own and not v.new_brand) m where m.mb <= 2),
  -- Discover: brands they've never come across. In their categories, ranked by how much they share with their taste;
  -- from a neighboring category only when it shares a detail they like. One per brand.
  disc_all as (
    select v.*, row_number() over (partition by public.brand_key(v.brand) order by v.adj desc) as rb
      from varied v
     where (v.own and v.new_brand)
        -- From a neighboring category: shares a detail they like, or comes from a brand they like.
        or (not v.own and (v.top_f like 't:%' or v.top_f like 'b:%') and v.fs > 0.75)
  ),
  explore as (select d.*, row_number() over (order by d.own desc, d.adj desc) as r from disc_all d where d.rb = 1),
  -- Your scout finds lead. With plenty of finds, the 5 strongest new ones are left to Today's Drop.
  top_new as (
    select f.id from public.finds f join public.listings l on l.id = f.listing_id
     where f.user_id = uid and f.status = 'open' and not (l.tags && array['intel', 'search'])
       and (select count(*) from public.finds x where x.user_id = uid and x.status in ('open', 'liked')) > 12
     order by f.score desc, f.created_at desc limit 5
  ),
  yours as (
    select y.id, y.r, y.find_id from (
      select f.listing_id as id, f.id as find_id,
             row_number() over (order by (f.status = 'liked') desc, f.score desc, f.created_at desc) as r
        from public.finds f join public.listings l on l.id = f.listing_id
       where f.user_id = uid and f.status in ('open', 'liked') and l.image_url is not null and not (l.tags && array['intel', 'search'])
         and f.id not in (select id from top_new)) y
  ),
  feed as (
    select y.id, y.r * 4 - 3.0 as pos, 'yours' as kind, y.find_id, 'From your scouts' as reason from yours y
    union all
    select s.id, s.r * 4 - 2.0, 'similar', null::uuid, 'Like your ' || left(s.seed, 40) || case when length(s.seed) > 40 then '…' else '' end
      from sim_kept s
    union all
    select m.id, m.r * 4 - 1.0, 'match', null::uuid,
           case when m.top_k is not null then 'Matches "' || m.top_k || '"'
                when m.top_f like 'b:%' and m.brand <> '' then 'Because you like ' || m.brand
                when m.top_f like 't:%' then 'More ' || substr(m.top_f, 3)
                else 'For your ' || m.category || ' taste' end
      from main m
    union all
    select e.id, e.r * 4 + 0.0, 'explore', null::uuid,
           case when not e.own and e.top_f like 'b:%' then 'From ' || e.brand || ', a house you love'
                when e.top_f like 't:%' then 'New to you · ' || substr(e.top_f, 3) || ', like you love'
                when not e.own then 'Discover · goes with your ' || (select string_agg(c, ' & ') from cats)
                else 'New to you · ' || e.brand end
      from explore e
  )
  select jsonb_build_object('listing', to_jsonb(l), 'reason', f.reason, 'kind', f.kind, 'find_id', f.find_id)
    from (select * from feed order by pos limit lim) f
    join public.listings l on l.id = f.id
   order by f.pos;
end $$;
