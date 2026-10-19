-- Background writing (product descriptions, brand blurbs) goes through Anthropic's batch processing at about half price.
create table if not exists public.claude_batches (
  id          text primary key,
  kind        text not null,
  items       jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  finished_at timestamptz
);
alter table public.claude_batches enable row level security;
revoke all on public.claude_batches from anon, authenticated;
grant select, insert, update on public.claude_batches to service_role;

-- Batch calls cost half; they're logged with "(batch)" after the model name.
create or replace function public.claude_cost(model text, inp int, outp int, cw int, cr int, searches int)
returns numeric language sql immutable set search_path = public as $$
  select (case when model ilike '%haiku%'
               then (inp * 0.10 + cw * 0.125 + cr * 0.01 + outp * 0.50) / 1e6
               else (inp * 2.00 + cw * 2.50  + cr * 0.10 + outp * 10.0) / 1e6 end
          * case when model ilike '%(batch)%' then 0.5 else 1 end)
         + searches * 0.01
$$;
