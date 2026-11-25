-- Fragrance finds priced from a sample or decant on the same page ($5-15 next to a $200+ bottle). The page reader used
-- the cheapest size; it now uses the full size. Clear these prices so the app says "Check at <store>" until the next
-- page check sets the real one, instead of showing a fake "great deal".
update listings
set price = null, page_checked_at = null, stock_seen_at = null
where category = 'fragrance'
  and price is not null
  and low_price is not null
  and price < low_price * 0.25;
