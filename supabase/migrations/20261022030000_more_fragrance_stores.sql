-- Indie fragrance houses Larry added to the map.
insert into public.stores (domain, category, name, kind) values
  ('jinxsmells.com', 'fragrance', 'Jinx Smells', 'brand'),
  ('toskovat.com', 'fragrance', 'Toskovat''', 'brand'),
  ('folkwinds.com', 'fragrance', 'Folkwinds', 'brand'),
  ('ataraxiaperfumery.com', 'fragrance', 'Ataraxia Perfumery', 'brand')
on conflict (domain, category) do nothing;
