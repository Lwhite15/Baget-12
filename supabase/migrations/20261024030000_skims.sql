-- SKIMS for clothing.
insert into public.stores (domain, category, name, kind) values
  ('skims.com', 'apparel', 'SKIMS', 'brand')
on conflict (domain, category) do nothing;
