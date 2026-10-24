-- The first Taste Cards were written without what each person hunts: write them again.
update public.profiles set taste_card_at = null where taste_card is not null and jsonb_array_length(coalesce(taste_card -> 'hunts', '[]')) = 0;
