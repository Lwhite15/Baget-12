-- Verified product photos are stored in our own public bucket, so the app can always load them
-- (stores block apps from loading their images directly). Only the server writes here.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-photos', 'product-photos', true, 4194304, array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

-- Photos are now found through image search. Re-check every listing that has none.
update public.listings set image_checked_at = null where image_url is null;
