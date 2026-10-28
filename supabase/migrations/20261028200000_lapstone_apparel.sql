-- Lapstone & Hammer (Philadelphia boutique) was in sneakers only; now in clothing too. Its whole Shopify catalog,
-- new arrivals included, is read for both.
insert into public.stores (domain, category, name, kind, source, shopify) values
  ('lapstoneandhammer.com', 'apparel', 'Lapstone & Hammer', 'boutique', 'seed', true)
on conflict (domain, category) do update set kind = 'boutique', source = 'seed';
