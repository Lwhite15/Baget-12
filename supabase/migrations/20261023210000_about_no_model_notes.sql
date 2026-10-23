-- Product descriptions that included the model's notes to itself ("Price and sizes not shown in the snippet…") are
-- cleared and written again by the nightly description pass, which now filters those notes out.
update public.listings
   set about = null, about_checked_at = null
 where about ~* '(snippet|search results?|not (shown|listed|provided|mentioned|specified) in|\m(i|we) (could not|couldn''t|can''t|cannot|was unable to)|unable to (confirm|verify|find))';
