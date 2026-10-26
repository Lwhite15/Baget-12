-- Grailed in every category's rotation (it was only in apparel, sneakers and accessories, plus a learned fragrance entry).
insert into public.stores (domain, category, name, kind, source)
select 'grailed.com', c.category, 'Grailed', 'resale', 'seed'
  from (values ('sneakers'), ('apparel'), ('fragrance'), ('watches'), ('cars'), ('furniture'), ('accessories'), ('collectibles'), ('other')) as c(category)
on conflict (domain, category) do update set name = 'Grailed', kind = 'resale', source = 'seed';
