-- People no longer set spending limits or see a monthly total. Agents hunt without caps.
-- Purchases are still recorded in public.purchases (and metrics.monthly_spend) when someone taps "I bought it".
update public.agents set max_per_item = 0, monthly_limit = 0 where max_per_item <> 0 or monthly_limit <> 0;
comment on column public.agents.max_per_item is 'Unused since spending limits were removed; kept at 0.';
comment on column public.agents.monthly_limit is 'Unused since spending limits were removed; kept at 0.';
comment on table public.purchases is 'Purchases people confirm with "I bought it". Logged for metrics; not shown as a spending total in the app.';
