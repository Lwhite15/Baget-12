-- End @baget14418's complimentary Pro week early (Larry's call). Only the comp week: a later App Store purchase or
-- trial (which would run past Oct 31) is left alone.
update public.profiles
   set plan = 'free', pro_until = null
 where handle = 'baget14418' and plan = 'pro' and pro_until <= '2026-10-31T04:00:00Z';
