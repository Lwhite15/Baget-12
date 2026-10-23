-- Marc-Antoine Barrois (US store) for fragrance.
insert into public.stores (domain, category, name, kind) values
  ('us.marcantoinebarrois.com', 'fragrance', 'Marc-Antoine Barrois', 'brand')
on conflict (domain, category) do nothing;
