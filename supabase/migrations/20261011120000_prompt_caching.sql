-- Prompt caching: record how much of each sweep's input was written to / read from Claude's cache.
alter table public.sweep_runs add column if not exists cache_write_tokens int not null default 0;
alter table public.sweep_runs add column if not exists cache_read_tokens int not null default 0;
