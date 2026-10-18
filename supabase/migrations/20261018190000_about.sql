-- Plain-language descriptions: what a product is and, for fragrance, what it smells like. Written by the scout that
-- found it (or filled in later), for people who don't already know the brand.
alter table public.listings add column if not exists about text check (about is null or char_length(about) <= 400);
alter table public.listings add column if not exists about_checked_at timestamptz;

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
                                   drop_at, sold_out, creator, traits, tags, sizes_in_stock, about)
      values (l ->> 'fingerprint', left(l ->> 'title', 200), coalesce(l ->> 'brand', ''), coalesce(l ->> 'category', 'other'),
              coalesce(l ->> 'sku', ''), (l ->> 'price')::numeric, (l ->> 'market')::numeric, coalesce(l ->> 'currency', 'USD'),
              coalesce(l ->> 'source', ''), l ->> 'url', l ->> 'image_url', (l ->> 'drop_at')::timestamptz, now_sold_out,
              l ->> 'creator',
              coalesce(public.jsonb_texts(l -> 'traits'), '{}'),
              coalesce(public.jsonb_texts(l -> 'tags'), '{}'),
              public.jsonb_texts(l -> 'sizes_in_stock'),
              nullif(left(l ->> 'about', 400), ''))
      returning listings.id into lid;
    else
      update public.listings x set
        price = coalesce((l ->> 'price')::numeric, x.price),
        market = coalesce((l ->> 'market')::numeric, x.market),
        sold_out = now_sold_out,
        url = coalesce(l ->> 'url', x.url),
        image_url = coalesce(l ->> 'image_url', x.image_url),
        drop_at = coalesce((l ->> 'drop_at')::timestamptz, x.drop_at),
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
         where f.listing_id = lid and f.watching and f.status = 'open';
      end if;
    end if;
    fingerprint := l ->> 'fingerprint';
    id := lid;
    already_found := exists (select 1 from public.finds f where f.user_id = p_user and f.listing_id = lid);
    return next;
  end loop;
end $$;
