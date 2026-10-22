-- Tandem hunts: the second scout's picks per hunt, and its cost on the stats screen.
alter table public.sweep_runs add column if not exists tandem int not null default 0;

create or replace function public.claude_cost(model text, inp integer, outp integer, cw integer, cr integer, searches integer)
returns numeric language sql immutable set search_path to 'public' as $$
  select case
    -- Gemini 2.5 Flash list prices; a grounded prompt is counted at Google's paid search-grounding rate (no free tier assumed).
    when model ilike '%gemini%' then (inp * 0.30 + outp * 2.50) / 1e6 + case when searches > 0 then 0.035 else 0 end
    else (case when model ilike '%haiku%'
               then (inp * 0.10 + cw * 0.125 + cr * 0.01 + outp * 0.50) / 1e6
               else (inp * 2.00 + cw * 2.50  + cr * 0.10 + outp * 10.0) / 1e6 end
          * case when model ilike '%(batch)%' then 0.5 else 1 end)
         + searches * 0.01
  end
$$;
