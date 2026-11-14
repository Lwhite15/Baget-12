-- When a store's own page last said this product is in stock. The app only says "Buy" when this is recent;
-- otherwise it says "Check at <store>", so a sold-out page Baget couldn't read never looks buyable.
alter table public.listings add column if not exists stock_seen_at timestamptz;

-- One-size "in stock" lists that are just the size on the scout that found them were the scout filling in the
-- person's size, not the store page. Clear them so the app stops saying "in your size" for them.
update public.listings l set sizes_in_stock = null
where array_length(l.sizes_in_stock, 1) = 1
  and coalesce(l.url, '') !~* '://([a-z0-9-]+\.)*(ebay|mercari|grailed|poshmark|depop|vinted|therealreal|vestiairecollective)\.'
  and exists (
    select 1 from public.finds f join public.agents a on a.id = f.agent_id
    where f.listing_id = l.id and a.size <> ''
      and lower(regexp_replace(a.size, '[^0-9a-zA-Z.]+', '', 'g')) = lower(regexp_replace(l.sizes_in_stock[1], '[^0-9a-zA-Z.]+', '', 'g'))
  );
