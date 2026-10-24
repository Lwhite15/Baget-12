-- Hypebeast and NikeTalk in every category's rotation. Neither sells anything, so what scouts bring back from them is
-- intel (news, release info, forum talk) and lands under Intel, never as a product to buy.
insert into public.source_blocks (domain, reason) values ('niketalk.com', 'forum')
on conflict (domain) do nothing;

insert into public.stores (domain, category, name, kind)
select d.domain, c.category, d.name, 'news'
  from (values ('hypebeast.com', 'Hypebeast'), ('niketalk.com', 'NikeTalk')) as d(domain, name)
  cross join (values ('sneakers'), ('apparel'), ('fragrance'), ('watches'), ('cars'), ('furniture'), ('accessories'), ('collectibles')) as c(category)
on conflict (domain, category) do nothing;
