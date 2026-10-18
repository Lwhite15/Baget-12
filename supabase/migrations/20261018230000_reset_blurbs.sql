-- The first batch of brand blurbs and filled-in descriptions could land on the wrong item when the model skipped one
-- in a list (Creed got The Row's blurb). The writer now matches every answer by id and name; start these over.
truncate public.brand_blurbs;
update public.listings set brand_about = null where brand_about is not null;
update public.listings set about = null, about_checked_at = null where about_checked_at is not null;
