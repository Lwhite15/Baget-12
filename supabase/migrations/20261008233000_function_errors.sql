-- Server-side error log for diagnosing what people hit (e.g. "Something went wrong (502)").
-- Only the server writes and reads it; no access for the app.
create table if not exists public.function_errors (
  id         bigint generated always as identity primary key,
  fn         text not null,
  status     int not null,
  message    text not null,
  created_at timestamptz not null default now()
);
alter table public.function_errors enable row level security;
revoke all on public.function_errors from anon, authenticated;
create index if not exists function_errors_recent on public.function_errors (created_at desc);
