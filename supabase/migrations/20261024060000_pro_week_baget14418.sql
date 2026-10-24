-- One week of complimentary Pro for @baget14418, from when this runs. Ends on its own; an App Store purchase or trial
-- taken later replaces it.
update public.profiles
   set plan = 'pro', pro_until = now() + interval '7 days'
 where handle = 'baget14418' and plan = 'free';
