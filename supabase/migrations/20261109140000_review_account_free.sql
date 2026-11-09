-- App Review couldn't find the Pro purchase (Guideline 2.1(b)): the review demo account had complimentary Pro,
-- which disables the Pro row in Settings and hides every "Go Pro" prompt. Put it on Free so the paywall is reachable.
update public.profiles set plan = 'free', pro_until = null
where id = '0a99e1e0-5eed-4d3e-8a00-00000000d3e0' and plan = 'comp';
