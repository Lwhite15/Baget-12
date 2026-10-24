-- COJP Gallery (Japanese labels like Kapital) for clothing.
insert into public.stores (domain, category, name, kind) values
  ('cojpgallery.com', 'apparel', 'COJP Gallery', 'boutique')
on conflict (domain, category) do nothing;
