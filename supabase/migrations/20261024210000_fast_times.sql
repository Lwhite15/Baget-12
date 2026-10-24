-- Fast Times (Australian skate and sneaker store) for sneakers. Prices are in AUD; finds show dollars with the
-- store's own price alongside.
insert into public.stores (domain, category, name, kind) values
  ('fasttimes.com.au', 'sneakers', 'Fast Times', 'boutique')
on conflict (domain, category) do nothing;
