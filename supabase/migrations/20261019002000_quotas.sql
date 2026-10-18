-- Per-account limits on the features that call Claude on demand (chat, reading a photo, building scouts), so a script
-- or a stuck client can't run up the bill. Generous: normal use never gets near them. Server only.
create table if not exists public.api_hits (
  user_id uuid not null references public.profiles (id) on delete cascade,
  fn      text not null,
  at      timestamptz not null default now()
);
create index if not exists api_hits_user_fn_at on public.api_hits (user_id, fn, at desc);
alter table public.api_hits enable row level security;
revoke all on public.api_hits from anon, authenticated;

create or replace function public.take_quota(p_user uuid, p_fn text, p_per_hour int, p_per_day int)
returns text language plpgsql security definer set search_path = public as $$
declare h int; d int;
begin
  perform pg_advisory_xact_lock(hashtext(p_user::text || p_fn));
  select count(*) filter (where at > now() - interval '1 hour'), count(*) into h, d
    from public.api_hits where user_id = p_user and fn = p_fn and at > now() - interval '24 hours';
  if h >= p_per_hour then return 'hour'; end if;
  if d >= p_per_day then return 'day'; end if;
  insert into public.api_hits (user_id, fn) values (p_user, p_fn);
  delete from public.api_hits where user_id = p_user and fn = p_fn and at < now() - interval '2 days';
  return 'ok';
end $$;
revoke all on function public.take_quota(uuid, text, int, int) from public, anon, authenticated;
grant execute on function public.take_quota(uuid, text, int, int) to service_role;
grant select, insert, delete on public.api_hits to service_role;
