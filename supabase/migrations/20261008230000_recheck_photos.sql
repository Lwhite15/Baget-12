-- The photo check never got to answer (its reply budget was used up by thinking), so every listing
-- was marked checked with no photo. Check them all again.
update public.listings set image_checked_at = null where image_url is null;
