-- Tandem hunts: grounded Gemini hunts so far today (Google's free allowance resets at midnight Pacific), and costs:
-- grounded hunts stay inside the free allowance (tokens only); Flash-Lite hunts pay Baget's own search (~$0.001 each).
create or replace function public.gemini_grounded_today()
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from public.claude_usage
   where fn = 'sweep (tandem)' and model like '%(grounded)%'
     and created_at >= (date_trunc('day', now() at time zone 'America/Los_Angeles') at time zone 'America/Los_Angeles')
$$;
revoke all on function public.gemini_grounded_today() from public, anon, authenticated;
grant execute on function public.gemini_grounded_today() to service_role;
create index if not exists claude_usage_fn_time on public.claude_usage (fn, created_at);

create or replace function public.claude_cost(model text, inp integer, outp integer, cw integer, cr integer, searches integer)
returns numeric language sql immutable set search_path to 'public' as $$
  select case
    when model ilike '%gemini%lite%' then (inp * 0.10 + outp * 0.40) / 1e6 + searches * 0.001
    when model ilike '%gemini%' then (inp * 0.30 + outp * 2.50) / 1e6
    else (case when model ilike '%haiku%'
               then (inp * 0.10 + cw * 0.125 + cr * 0.01 + outp * 0.50) / 1e6
               else (inp * 2.00 + cw * 2.50  + cr * 0.10 + outp * 10.0) / 1e6 end
          * case when model ilike '%(batch)%' then 0.5 else 1 end)
         + searches * 0.01
  end
$$;
