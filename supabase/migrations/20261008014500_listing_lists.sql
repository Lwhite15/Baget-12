-- Fix: a listing with no sizes (fragrance, furniture, cars...) arrives with "sizes_in_stock": null.
-- jsonb_array_elements_text() on a JSON null fails with "cannot extract elements from a scalar",
-- which rejected those listings in sweeps and in chat. Read list fields through a helper that
-- treats anything that isn't a JSON array as "no list".

create or replace function public.jsonb_texts(j jsonb)
returns text[] language sql immutable set search_path = public as $$
  select case when jsonb_typeof(j) = 'array'
              then nullif(array(select v from jsonb_array_elements_text(j) v where v is not null), '{}')
              else null end
$$;
revoke all on function public.jsonb_texts(jsonb) from public, anon, authenticated;

-- Saves what a sweep found. Detects restocks of items people are watching.
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
                                   drop_at, sold_out, creator, traits, tags, sizes_in_stock)
      values (l ->> 'fingerprint', left(l ->> 'title', 200), coalesce(l ->> 'brand', ''), coalesce(l ->> 'category', 'other'),
              coalesce(l ->> 'sku', ''), (l ->> 'price')::numeric, (l ->> 'market')::numeric, coalesce(l ->> 'currency', 'USD'),
              coalesce(l ->> 'source', ''), l ->> 'url', l ->> 'image_url', (l ->> 'drop_at')::timestamptz, now_sold_out,
              l ->> 'creator',
              coalesce(public.jsonb_texts(l -> 'traits'), '{}'),
              coalesce(public.jsonb_texts(l -> 'tags'), '{}'),
              public.jsonb_texts(l -> 'sizes_in_stock'))
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

-- Records new finds for an agent, each with its friend-style notification.
create or replace function public.record_finds(p_agent uuid, p_finds jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare
  ag public.agents;
  f jsonb;
  fid uuid;
  n int := 0;
begin
  select * into ag from public.agents where id = p_agent;
  if not found then return 0; end if;
  for f in select * from jsonb_array_elements(case when jsonb_typeof(p_finds) = 'array' then p_finds else '[]'::jsonb end) loop
    insert into public.finds (user_id, agent_id, listing_id, score, why)
    values (ag.user_id, ag.id, (f ->> 'listing_id')::uuid, (f ->> 'score')::int,
            coalesce(public.jsonb_texts(f -> 'why'), '{}'))
    on conflict (user_id, listing_id) do nothing
    returning finds.id into fid;
    if fid is not null then
      n := n + 1;
      if f ? 'note' then
        insert into public.notes (user_id, agent_id, sender_name, kind, body, find_id, held_for_morning)
        values (ag.user_id, ag.id, ag.name, f -> 'note' ->> 'kind', left(f -> 'note' ->> 'body', 500), fid,
                coalesce((f -> 'note' ->> 'held')::boolean, false));
      end if;
    end if;
    fid := null;
  end loop;
  update public.agents set last_swept_at = now() where id = ag.id;
  return n;
end $$;

