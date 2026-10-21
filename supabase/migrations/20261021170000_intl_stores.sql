-- Stores outside the US stay in: their catalogs are read in the store's own currency, converted to US dollars for
-- everything Baget does (budgets, deals, sorting), and the store's own price is kept to show next to it.
alter table public.listings add column if not exists orig_price numeric, add column if not exists orig_currency text;
alter table public.stores add column if not exists currency text;

-- US dollars per one unit of a currency, refreshed daily from the European Central Bank's reference rates.
create table if not exists public.fx_rates (
  currency   text primary key check (currency ~ '^[A-Z]{3}$'),
  usd        numeric not null check (usd > 0),
  updated_at timestamptz not null default now()
);
alter table public.fx_rates enable row level security;
revoke all on public.fx_rates from anon, authenticated;
grant all on public.fx_rates to service_role;

-- Stores skipped earlier for charging in another currency get another look.
update public.stores set shopify = null, last_feed_at = null where shopify = false;
