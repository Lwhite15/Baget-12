-- Cabela's, Bass Pro Shops and DICK'S Sporting Goods: clothing, shoes and boots, accessories, and outdoor/sports gear.
insert into public.stores (domain, category, name, kind, source)
select d.domain, c.category, d.name, 'retailer', 'seed'
  from (values ('cabelas.com', 'Cabela''s'), ('basspro.com', 'Bass Pro Shops'), ('dickssportinggoods.com', 'DICK''S Sporting Goods')) as d(domain, name)
  cross join (values ('apparel'), ('sneakers'), ('accessories'), ('other')) as c(category)
on conflict (domain, category) do update set name = excluded.name, kind = 'retailer', source = 'seed';
