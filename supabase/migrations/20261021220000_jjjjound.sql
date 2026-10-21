-- JJJJound for both clothes and shoes (it sells both; it was on the map for clothes only).
insert into public.stores (domain, category, name, kind, shopify, currency)
values ('jjjjound.com', 'sneakers', 'JJJJound', 'brand', true, 'USD'),
       ('jjjjound.com', 'apparel', 'JJJJound', 'brand', true, 'USD')
on conflict (domain, category) do nothing;
