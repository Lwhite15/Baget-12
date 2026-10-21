-- Android: phones register Firebase (FCM) tokens alongside iPhone (APNs) tokens.
-- APNs tokens are lowercase hex; FCM tokens are longer, mixed case, with ':' '_' '-'. Each row says which kind it is.

alter table public.device_tokens add column if not exists platform text not null default 'ios'
  check (platform in ('ios', 'android'));

alter table public.device_tokens drop constraint if exists device_tokens_token_check;
alter table public.device_tokens add constraint device_tokens_token_check check (
  (platform = 'ios' and token ~ '^[0-9a-f]{32,200}$')
  or (platform = 'android' and token ~ '^[A-Za-z0-9_:-]+$' and char_length(token) between 20 and 4096)
);

-- Same function, one more (optional) argument; iPhone builds keep calling it with two.
drop function if exists public.register_device(text, text);
create or replace function public.register_device(p_token text, p_env text default 'production', p_platform text default 'ios')
returns void language plpgsql security definer set search_path = public as $$
declare
  plat text := case when p_platform = 'android' then 'android' else 'ios' end;
  tok  text := case when p_platform = 'android' then p_token else lower(p_token) end;   -- FCM tokens are case-sensitive
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  insert into public.device_tokens (token, user_id, environment, platform, updated_at)
  values (tok, auth.uid(), coalesce(p_env, 'production'), plat, now())
  on conflict (token) do update set user_id = excluded.user_id, environment = excluded.environment, platform = excluded.platform, updated_at = now();
end $$;

create or replace function public.unregister_device(p_token text)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.device_tokens where (token = p_token or token = lower(p_token)) and user_id = auth.uid();
end $$;

revoke all on function public.register_device(text, text, text) from public, anon;
grant execute on function public.register_device(text, text, text) to authenticated;
revoke all on function public.unregister_device(text) from public, anon;
grant execute on function public.unregister_device(text) to authenticated;

-- Google Play purchases. A purchase token identifies a subscription (Apple's original transaction id plays this role on iPhone).
-- Server-only: no grants, so the app (and friends who can see a profile) never see the tokens.
create table if not exists public.play_subscriptions (
  purchase_token text primary key check (char_length(purchase_token) between 10 and 1000),
  user_id        uuid not null references public.profiles (id) on delete cascade,
  product_id     text not null check (char_length(product_id) <= 100),
  expires_at     timestamptz,
  state          text not null default '' check (char_length(state) <= 60),
  updated_at     timestamptz not null default now()
);
create index if not exists play_subscriptions_user_idx on public.play_subscriptions (user_id);
alter table public.play_subscriptions enable row level security;
revoke all on public.play_subscriptions from anon, authenticated;
