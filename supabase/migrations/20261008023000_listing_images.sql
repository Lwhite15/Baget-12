-- Product photos: listings found before photo lookup existed get one try each from the scheduled sweep.
alter table public.listings add column if not exists image_checked_at timestamptz;
create index if not exists listings_image_backfill on public.listings (last_seen_at desc)
  where image_url is null and image_checked_at is null;
