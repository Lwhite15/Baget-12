-- Product photos are now verified (Claude checks each one shows the exact product). Clear the unverified
-- ones from the first version so nothing wrong shows; scheduled sweeps re-check them a few at a time.
update public.listings set image_url = null, image_checked_at = null where image_url is not null or image_checked_at is not null;

-- upsert_listings keeps an existing photo when a sweep finds none (coalesce). A sweep's photo is verified,
-- so a re-found listing takes the new one, and an old one is kept only when the sweep had nothing.
