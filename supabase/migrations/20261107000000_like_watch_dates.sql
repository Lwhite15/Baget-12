-- Liking something hands it to your scout to watch; watchers hear when a release date is announced or moves.

-- 1. A like is also a watch (price drops, restocks, release dates).
create or replace function public.finds_like_watches()
returns trigger language plpgsql as $$
begin
  if new.status = 'liked' and (tg_op = 'INSERT' or old.status is distinct from 'liked') then
    new.watching := true;
  end if;
  return new;
end $$;
drop trigger if exists finds_like_watches on public.finds;
create trigger finds_like_watches before insert or update of status on public.finds
  for each row execute function public.finds_like_watches();

-- Existing likes start being watched too.
update public.finds set watching = true where status = 'liked' and not watching;

-- 2. "Dated": a release date was announced or moved, for things you watch.
alter table public.notes drop constraint if exists notes_kind_check;
alter table public.notes add constraint notes_kind_check
  check (kind in ('release','available','steal','watch','restock','bought','budget','learned','friend','digest','drop','feedback','reminder','dated'));

create or replace function public.safe_tz(p text)
returns text language sql stable as $$
  select case when exists (select 1 from pg_timezone_names where name = p) then p else 'America/New_York' end
$$;

create or replace function public.listing_date_changed()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.drop_at is null or new.drop_at < now() then return new; end if;
  if old.drop_at is not null and abs(extract(epoch from (new.drop_at - old.drop_at))) < 3600 then return new; end if;
  insert into public.notes (user_id, agent_id, sender_name, kind, body, find_id)
  select f.user_id, f.agent_id, coalesce(a.name, 'Baget'), 'dated',
         left(case when old.drop_at is null
                   then 'Release date is out: the ' || new.title || ' drops ' || d.txt || '.'
                   else 'Heads up: the ' || new.title || ' moved to ' || d.txt || '.' end, 480),
         f.id
    from public.finds f
    join public.profiles p on p.id = f.user_id
    left join public.agents a on a.id = f.agent_id
    cross join lateral (
      select to_char(new.drop_at at time zone public.safe_tz(p.tz), 'Dy, Mon FMDD') ||
             case when to_char(new.drop_at at time zone public.safe_tz(p.tz), 'HH24:MI') = '00:00' then ''
                  else ' at ' || to_char(new.drop_at at time zone public.safe_tz(p.tz), 'FMHH12:MI AM') end as txt
    ) d
   where f.listing_id = new.id and f.watching and f.status in ('open', 'liked');
  return new;
end $$;
drop trigger if exists listings_date_changed on public.listings;
create trigger listings_date_changed after update of drop_at on public.listings
  for each row when (new.drop_at is distinct from old.drop_at) execute function public.listing_date_changed();

-- 3. Restock texts reach liked finds too (they're watched now), not only open ones.
create or replace function public.upsert_listings(p_user uuid, p_listings jsonb)
returns table (fingerprint text, id uuid, already_found boolean)
language plpgsql security definer set search_path = public as $$
declare
  l jsonb;
  lid uuid;
  was_sold_out boolean;
  now_sold_out boolean;
begin
  for l in select * from jsonb_array_elements(case when jsonb_typeof(p_listings) = 'array' then p_listings else '[]'::jsonb end) loop
    now_sold_out := coalesce((l ->> 'sold_out')::boolean, false);
    select x.id, x.sold_out into lid, was_sold_out from public.listings x where x.fingerprint = l ->> 'fingerprint';
    if lid is null then
      insert into public.listings (fingerprint, title, brand, category, sku, price, market, currency, source, url, image_url,
                                   drop_at, sold_out, creator, traits, tags, sizes_in_stock, about, brand_about)
      values (l ->> 'fingerprint', left(l ->> 'title', 200), coalesce(l ->> 'brand', ''), coalesce(l ->> 'category', 'other'),
              coalesce(l ->> 'sku', ''), (l ->> 'price')::numeric, (l ->> 'market')::numeric, coalesce(l ->> 'currency', 'USD'),
              coalesce(l ->> 'source', ''), l ->> 'url', l ->> 'image_url', (l ->> 'drop_at')::timestamptz, now_sold_out,
              l ->> 'creator',
              coalesce(public.jsonb_texts(l -> 'traits'), '{}'),
              coalesce(public.jsonb_texts(l -> 'tags'), '{}'),
              public.jsonb_texts(l -> 'sizes_in_stock'),
              nullif(left(l ->> 'about', 400), ''),
              (select b.blurb from public.brand_blurbs b where b.key = lower(trim(l ->> 'brand'))))
      returning listings.id into lid;
    else
      update public.listings x set
        price = coalesce((l ->> 'price')::numeric, x.price),
        market = coalesce((l ->> 'market')::numeric, x.market),
        sold_out = now_sold_out,
        url = coalesce(l ->> 'url', x.url),
        image_url = coalesce(l ->> 'image_url', x.image_url),
        drop_at = coalesce((l ->> 'drop_at')::timestamptz, x.drop_at),
        -- a newly seen date brings its confirmed / rumored label with it
        tags = case when (l ->> 'drop_at') is not null
                    then array(select distinct t from unnest(array_remove(array_remove(x.tags, 'confirmed'), 'rumored')
                                                         || coalesce(public.jsonb_texts(l -> 'tags'), '{}')) t
                                where t in ('confirmed', 'rumored') or t = any(x.tags))
                    else x.tags end,
        sizes_in_stock = coalesce(public.jsonb_texts(l -> 'sizes_in_stock'), x.sizes_in_stock),
        about = coalesce(x.about, nullif(left(l ->> 'about', 400), '')),
        last_seen_at = now()
      where x.id = lid;
      if was_sold_out and not now_sold_out then
        insert into public.notes (user_id, agent_id, sender_name, kind, body, find_id)
        select f.user_id, f.agent_id, coalesce(a.name, 'Baget'), 'restock',
               case coalesce(a.voice, 'chill')
                 when 'hype' then 'IT''S BACK. The ' || x.title || ' just restocked at ' || x.source || '. Want me to grab it before it''s gone again?'
                 when 'straight' then 'Restock: ' || x.title || ' at ' || x.source || '. Tap to review.'
                 else 'Good news, the ' || x.title || ' is back in stock at ' || x.source || '. Want it?'
               end,
               f.id
          from public.finds f
          join public.listings x on x.id = f.listing_id
          left join public.agents a on a.id = f.agent_id
         where f.listing_id = lid and f.watching and f.status in ('open', 'liked');
      end if;
    end if;
    fingerprint := l ->> 'fingerprint';
    id := lid;
    already_found := exists (select 1 from public.finds f where f.user_id = p_user and f.listing_id = lid);
    return next;
  end loop;
end $$;
