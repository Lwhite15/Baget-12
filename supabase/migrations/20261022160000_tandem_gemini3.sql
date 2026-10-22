-- Gemini 3 grounding: 5,000 free searches a month (shared across Gemini 3 models), then $14 per 1,000 searches.
create or replace function public.gemini_grounded_month()
returns int language sql stable security definer set search_path = public as $$
  select coalesce(sum(searches), 0)::int from public.claude_usage
   where fn = 'sweep (tandem)' and model like '%(grounded)%'
     and created_at >= (date_trunc('month', now() at time zone 'America/Los_Angeles') at time zone 'America/Los_Angeles')
$$;
revoke all on function public.gemini_grounded_month() from public, anon, authenticated;
grant execute on function public.gemini_grounded_month() to service_role;

-- Current Gemini list prices (per 1M tokens): 3.1 Flash-Lite $0.25/$1.50, 3.5 Flash-Lite $0.30/$2.50,
-- 3.8 Flash $0.75/$3.75 (through 2026). Grounded searches stay inside the free allowance; Serper ~$0.001 each.
create or replace function public.claude_cost(model text, inp integer, outp integer, cw integer, cr integer, searches integer)
returns numeric language sql immutable set search_path to 'public' as $$
  select case
    when model ilike '%gemini%' then
      (case when model ilike '%3.1-flash-lite%' then inp * 0.25 + outp * 1.50
            when model ilike '%flash-lite%' then inp * 0.30 + outp * 2.50
            else inp * 0.75 + outp * 3.75 end) / 1e6
      + case when model ilike '%(serper)%' then searches * 0.001 else 0 end
    else (case when model ilike '%haiku%'
               then (inp * 0.10 + cw * 0.125 + cr * 0.01 + outp * 0.50) / 1e6
               else (inp * 2.00 + cw * 2.50  + cr * 0.10 + outp * 10.0) / 1e6 end
          * case when model ilike '%(batch)%' then 0.5 else 1 end)
         + searches * 0.01
  end
$$;
