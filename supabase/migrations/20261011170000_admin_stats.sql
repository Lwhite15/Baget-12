-- Owner stats: a private dashboard in the app for admins only.
--   * claude_usage: one row per Claude call (tokens, cache, searches) so spend can be shown per day.
--   * app_admins: who may open the dashboard. Nobody can read or change it through the API.
--   * admin_stats(): every number on the dashboard, refused for anyone not in app_admins.

create table if not exists public.claude_usage (
  id            bigint generated always as identity primary key,
  fn            text not null default 'other' check (char_length(fn) <= 40),
  model         text not null default '' check (char_length(model) <= 60),
  input_tokens  int not null default 0,
  output_tokens int not null default 0,
  cache_write_tokens int not null default 0,
  cache_read_tokens  int not null default 0,
  searches      int not null default 0,
  created_at    timestamptz not null default now()
);
create index if not exists claude_usage_time_idx on public.claude_usage (created_at desc);
alter table public.claude_usage enable row level security;
revoke all on public.claude_usage from anon, authenticated;

create table if not exists public.app_admins (
  user_id    uuid primary key references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.app_admins enable row level security;
revoke all on public.app_admins from anon, authenticated;

create or replace function public.am_i_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_admins where user_id = auth.uid())
$$;
revoke all on function public.am_i_admin() from public, anon;
grant execute on function public.am_i_admin() to authenticated;

-- Dollar cost of a usage row (list prices per million tokens; web search $10 per 1,000).
create or replace function public.claude_cost(model text, inp int, outp int, cw int, cr int, searches int)
returns numeric language sql immutable as $$
  select case when model ilike '%haiku%'
              then (inp * 0.10 + cw * 0.125 + cr * 0.01 + outp * 0.50) / 1e6
              else (inp * 2.00 + cw * 2.50  + cr * 0.10 + outp * 10.0) / 1e6 end
         + searches * 0.01
$$;

create or replace function public.admin_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  demo constant uuid := '0a99e1e0-5eed-4d3e-8a00-00000000d3e0';
  result jsonb;
begin
  if not exists (select 1 from public.app_admins where user_id = auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  with
  people as (select id, created_at from public.profiles where id <> demo),
  installs as (select install_id, min(occurred_at) first_seen, max(occurred_at) last_seen from public.events group by install_id),
  days as (select generate_series((now() at time zone 'America/New_York')::date - 13, (now() at time zone 'America/New_York')::date, '1 day')::date d),
  use_day as (
    select (created_at at time zone 'America/New_York')::date d,
           sum(public.claude_cost(model, input_tokens, output_tokens, cache_write_tokens, cache_read_tokens, searches)) cost,
           sum(case when model ilike '%haiku%' then cache_read_tokens * 0.009 - cache_write_tokens * 0.025
                    else cache_read_tokens * 1.9 - cache_write_tokens * 0.5 end) / 1e6 saved
      from public.claude_usage where created_at > now() - interval '30 days' group by 1)
  select jsonb_build_object(
    'generated_at', now(),
    'users', jsonb_build_object(
      'total',   (select count(*) from people),
      'today',   (select count(*) from people where created_at > date_trunc('day', now() at time zone 'America/New_York') at time zone 'America/New_York'),
      'week',    (select count(*) from people where created_at > now() - interval '7 days'),
      'month',   (select count(*) from people where created_at > now() - interval '30 days')),
    'active', jsonb_build_object(
      'day',   (select count(distinct install_id) from public.events where occurred_at > now() - interval '1 day'),
      'week',  (select count(distinct install_id) from public.events where occurred_at > now() - interval '7 days'),
      'month', (select count(distinct install_id) from public.events where occurred_at > now() - interval '30 days')),
    'retention', jsonb_build_object(
      'day1_base', (select count(*) from installs where first_seen < now() - interval '1 day'),
      'day1',      (select count(*) from installs where first_seen < now() - interval '1 day' and last_seen > first_seen + interval '1 day'),
      'day7_base', (select count(*) from installs where first_seen < now() - interval '7 days'),
      'day7',      (select count(*) from installs where first_seen < now() - interval '7 days' and last_seen > first_seen + interval '7 days')),
    'daily', (select jsonb_agg(jsonb_build_object(
        'day', days.d,
        'signups', (select count(*) from people where (created_at at time zone 'America/New_York')::date = days.d),
        'active',  (select count(distinct install_id) from public.events where (occurred_at at time zone 'America/New_York')::date = days.d),
        'cost',    coalesce((select round(cost, 4) from use_day where use_day.d = days.d), 0)) order by days.d) from days),
    'agents', jsonb_build_object(
      'total', (select count(*) from public.agents where user_id <> demo),
      'on',    (select count(*) from public.agents where user_id <> demo and not paused),
      'with_agents', (select count(distinct user_id) from public.agents where user_id <> demo)),
    'finds', jsonb_build_object(
      'total',  (select count(*) from public.finds where user_id <> demo),
      'week',   (select count(*) from public.finds where user_id <> demo and created_at > now() - interval '7 days'),
      'liked',  (select count(*) from public.finds where user_id <> demo and status = 'liked'),
      'passed', (select count(*) from public.finds where user_id <> demo and status = 'passed'),
      'bought', (select count(*) from public.finds where user_id <> demo and status = 'acquired')),
    'shopping', jsonb_build_object(
      'buy_taps_week', (select count(*) from public.events where name = 'checkout_opened' and occurred_at > now() - interval '7 days'),
      'purchases',     (select count(*) from public.purchases where user_id <> demo),
      'purchase_total',(select coalesce(sum(amount), 0) from public.purchases where user_id <> demo)),
    'engagement', jsonb_build_object(
      'chats_week',  (select count(*) from public.events where name = 'chat_sent' and occurred_at > now() - interval '7 days'),
      'swipes_week', (select count(*) from public.events where name in ('swipe','find_liked','find_passed') and occurred_at > now() - interval '7 days'),
      'texts_week',  (select count(*) from public.notes where user_id <> demo and pushed_at > now() - interval '7 days' and not push_skipped),
      'quiet_week',  (select count(*) from public.notes where user_id <> demo and pushed_at > now() - interval '7 days' and push_skipped),
      'opened_week', (select count(*) from public.events where name = 'notification_opened' and occurred_at > now() - interval '7 days')),
    'claude', jsonb_build_object(
      'today', coalesce((select round(cost, 2) from use_day where d = (now() at time zone 'America/New_York')::date), 0),
      'week',  coalesce((select round(sum(cost), 2) from use_day where d > (now() at time zone 'America/New_York')::date - 7), 0),
      'month', coalesce((select round(sum(cost), 2) from use_day), 0),
      'cache_saved_week', coalesce((select round(sum(saved), 2) from use_day where d > (now() at time zone 'America/New_York')::date - 7), 0),
      'calls_week', (select count(*) from public.claude_usage where created_at > now() - interval '7 days'),
      'by_feature', (select coalesce(jsonb_object_agg(fn, c), '{}'::jsonb) from (
          select fn, round(sum(public.claude_cost(model, input_tokens, output_tokens, cache_write_tokens, cache_read_tokens, searches)), 2) c
            from public.claude_usage where created_at > now() - interval '7 days' group by fn) f),
      'sweeps_day', (select count(*) from public.sweep_runs where created_at > now() - interval '1 day'),
      'failed_day', (select count(*) from public.sweep_runs where created_at > now() - interval '1 day' and error is not null),
      'last_error', (select left(error, 160) from public.sweep_runs where error is not null and created_at > now() - interval '1 day' order by created_at desc limit 1))
  ) into result;
  return result;
end $$;
revoke all on function public.admin_stats() from public, anon;
grant execute on function public.admin_stats() to authenticated;
