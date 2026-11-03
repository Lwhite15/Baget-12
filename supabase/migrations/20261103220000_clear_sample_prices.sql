-- Store catalogs priced some fragrances by their sample vial ($7 next to a $395 bottle). The reader now skips sample
-- sizes; until each store's next read fills in the real price, these show "Price at store" instead of a wrong one.
update public.listings set price = null
 where 'catalog' = any(tags) and category = 'fragrance' and price is not null and price < 20;
