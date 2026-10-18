-- Deep hunts also open product pages: count those per run.
alter table public.sweep_runs add column if not exists fetches int not null default 0;
