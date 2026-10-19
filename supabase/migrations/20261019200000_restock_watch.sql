-- Watching a sold-out find checks the store's page for a restock (at most hourly per product).
alter table public.listings add column if not exists stock_checked_at timestamptz;
