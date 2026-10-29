-- Lost Tribe Perfumes (indie fragrance house, Shopify) added to fragrance; its whole catalog is read.
insert into public.stores (domain, category, name, kind, source, shopify) values
  ('losttribeperfumes.com', 'fragrance', 'Lost Tribe Perfumes', 'brand', 'seed', true)
on conflict (domain, category) do update set kind = 'brand', source = 'seed', shopify = true;
