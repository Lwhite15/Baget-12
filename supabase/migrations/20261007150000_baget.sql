-- Baget backend
--
-- Security model
--   * Every table has row level security. A signed-in user reads and writes only their own rows,
--     plus what friends deliberately share with them. Anonymous visitors get nothing except
--     the write-only metrics table.
--   * Listings (real products the sweeps found) are readable by any signed-in user and writable
--     only by the server.
--   * Anything that touches more than one user (friend requests, shares, device tokens) goes
--     through a function that checks the caller, instead of open table access.
--   * Server jobs run as service_role inside edge functions; scheduler calls carry a shared secret.

create extension if not exists pgcrypto with schema extensions;

do $$
begin
  -- Scheduling and outbound HTTP for push. Present on Supabase; skipped where unavailable.
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net with schema extensions;
  end if;
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
  end if;
end $$;

-- ─── Profiles ──────────────────────────────────────────────────────────────────

create table public.profiles (
  id              uuid primary key references auth.users (id) on delete cascade,
  handle          text not null unique check (handle ~ '^[a-z0-9._]{3,24}$'),
  display_name    text not null default '' check (char_length(display_name) <= 60),
  tz              text not null default 'America/New_York' check (char_length(tz) <= 64),
  share_taste     boolean not null default true,
  share_purchases boolean not null default false,
  -- sweepMinutes, quietHours, groups, liveTabs: the app's settings, kept in one place
  settings        jsonb not null default '{}'::jsonb check (pg_column_size(settings) <= 16384),
  created_at      timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  base text;
  candidate text;
  tries int := 0;
begin
  base := lower(regexp_replace(
    coalesce(nullif(new.raw_user_meta_data ->> 'full_name', ''), split_part(coalesce(new.email, ''), '@', 1), ''),
    '[^a-zA-Z0-9]', '', 'g'));
  if length(base) < 3 then base := 'baget' || base; end if;
  base := left(base, 16);
  candidate := base;
  while exists (select 1 from public.profiles where handle = candidate) and tries < 25 loop
    tries := tries + 1;
    candidate := base || (floor(random() * 90000) + 10000)::int::text;
  end loop;
  insert into public.profiles (id, handle, display_name)
  values (new.id, candidate, left(coalesce(new.raw_user_meta_data ->> 'full_name', ''), 60));
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─── Agents and taste photos ───────────────────────────────────────────────────

create table public.agents (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  name             text not null check (char_length(name) between 1 and 40),
  mission_category text check (mission_category in ('sneakers','apparel','fragrance','watches','cars','furniture','accessories','collectibles')),
  mission_custom   text check (char_length(mission_custom) between 1 and 80),
  keywords         text[] not null default '{}' check (cardinality(keywords) <= 20),
  traits           text[] not null default '{}' check (cardinality(traits) <= 40),
  makers           text[] not null default '{}' check (cardinality(makers) <= 20),
  creators         text[] not null default '{}' check (cardinality(creators) <= 20),
  size             text not null default '' check (char_length(size) <= 40),
  max_per_item     numeric not null default 0 check (max_per_item >= 0),
  monthly_limit    numeric not null default 0 check (monthly_limit >= 0),
  mode             text not null default 'ask' check (mode in ('alert','ask','auto')),
  voice            text not null default 'chill' check (voice in ('hype','chill','straight')),
  learned          jsonb not null default '{}'::jsonb check (pg_column_size(learned) <= 8192),
  price_note       numeric not null default 0 check (price_note >= 0),
  last_swept_at    timestamptz,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint one_mission check ((mission_category is null) <> (mission_custom is null))
);
create index agents_user_idx on public.agents (user_id);

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;

create trigger agents_touch before update on public.agents
  for each row execute function public.touch_updated_at();

-- Each sweep costs real money, so a squad tops out at 12 agents.
create or replace function public.limit_agents()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from public.agents where user_id = new.user_id) >= 12 then
    raise exception 'agent_limit' using hint = 'A squad can have up to 12 agents.';
  end if;
  return new;
end $$;
create trigger agents_limit before insert on public.agents
  for each row execute function public.limit_agents();

create table public.taste_photos (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  agent_id     uuid not null references public.agents (id) on delete cascade,
  storage_path text not null check (char_length(storage_path) <= 200),
  tags         text[] not null default '{}' check (cardinality(tags) <= 12),
  summary      text not null default '' check (char_length(summary) <= 400),
  created_at   timestamptz not null default now()
);
create index taste_photos_agent_idx on public.taste_photos (agent_id);

-- ─── Listings: real products found by sweeps (shared, server-written) ─────────

create table public.listings (
  id             uuid primary key default gen_random_uuid(),
  fingerprint    text not null unique,
  title          text not null check (char_length(title) <= 200),
  brand          text not null default '',
  category       text not null default 'other',
  sku            text not null default '',
  price          numeric,
  market         numeric,
  currency       text not null default 'USD',
  source         text not null default '',
  url            text check (url is null or url ~ '^https?://'),
  image_url      text check (image_url is null or image_url ~ '^https?://'),
  drop_at        timestamptz,
  sold_out       boolean not null default false,
  creator        text,
  traits         text[] not null default '{}',
  tags           text[] not null default '{}',
  sizes_in_stock text[],
  first_seen_at  timestamptz not null default now(),
  last_seen_at   timestamptz not null default now()
);
create index listings_seen_idx on public.listings (last_seen_at desc);
create index listings_category_idx on public.listings (category);

-- ─── Finds, purchases, notifications ───────────────────────────────────────────

create table public.finds (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  agent_id    uuid references public.agents (id) on delete set null,
  listing_id  uuid not null references public.listings (id) on delete cascade,
  score       int not null default 50 check (score between 0 and 100),
  why         text[] not null default '{}' check (cardinality(why) <= 10),
  status      text not null default 'open' check (status in ('open','passed','acquired')),
  pass_reason text check (char_length(pass_reason) <= 40),
  watching    boolean not null default false,
  created_at  timestamptz not null default now(),
  unique (user_id, listing_id)
);
create index finds_user_idx on public.finds (user_id, created_at desc);

create table public.purchases (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  listing_id   uuid references public.listings (id) on delete set null,
  agent_id     uuid references public.agents (id) on delete set null,
  agent_name   text not null default '' check (char_length(agent_name) <= 40),
  title        text not null check (char_length(title) <= 200),
  amount       numeric not null check (amount >= 0 and amount < 10000000),
  category     text not null default 'other',
  purchased_at timestamptz not null default now()
);
create index purchases_user_idx on public.purchases (user_id, purchased_at desc);

create table public.notes (
  id               uuid primary key default gen_random_uuid(),
  user_id          uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  agent_id         uuid references public.agents (id) on delete set null,
  friend_id        uuid references public.profiles (id) on delete set null,
  sender_name      text not null default '',
  kind             text not null check (kind in ('release','available','steal','watch','restock','bought','budget','learned','friend')),
  body             text not null check (char_length(body) <= 500),
  find_id          uuid references public.finds (id) on delete set null,
  read             boolean not null default false,
  held_for_morning boolean not null default false,
  pushed_at        timestamptz,
  created_at       timestamptz not null default now()
);
create index notes_user_idx on public.notes (user_id, created_at desc);
create index notes_held_idx on public.notes (held_for_morning) where held_for_morning and pushed_at is null;

create table public.device_tokens (
  token       text primary key check (token ~ '^[0-9a-f]{32,200}$'),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  environment text not null default 'production' check (environment in ('production','sandbox')),
  updated_at  timestamptz not null default now()
);

-- ─── Friends, shares, suggestions ──────────────────────────────────────────────

create table public.friendships (
  id         uuid primary key default gen_random_uuid(),
  requester  uuid not null references public.profiles (id) on delete cascade,
  addressee  uuid not null references public.profiles (id) on delete cascade,
  status     text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  check (requester <> addressee)
);
create unique index friendships_pair_idx on public.friendships (least(requester, addressee), greatest(requester, addressee));

create table public.shares (
  id            uuid primary key default gen_random_uuid(),
  from_user     uuid not null references public.profiles (id) on delete cascade,
  listing_id    uuid not null references public.listings (id) on delete cascade,
  to_users      uuid[] not null check (cardinality(to_users) between 1 and 20),
  note          text not null default '' check (char_length(note) <= 280),
  is_suggestion boolean not null default false,
  created_at    timestamptz not null default now()
);

create table public.suggestions (
  id         uuid primary key default gen_random_uuid(),
  share_id   uuid references public.shares (id) on delete cascade,
  from_user  uuid not null references public.profiles (id) on delete cascade,
  to_user    uuid not null references public.profiles (id) on delete cascade,
  listing_id uuid not null references public.listings (id) on delete cascade,
  note       text not null default '',
  status     text not null default 'new' check (status in ('new','sent','passed')),
  created_at timestamptz not null default now()
);
create index suggestions_to_idx on public.suggestions (to_user, created_at desc);

create table public.share_replies (
  id         uuid primary key default gen_random_uuid(),
  share_id   uuid not null references public.shares (id) on delete cascade,
  from_user  uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  body       text not null check (char_length(body) between 1 and 280),
  created_at timestamptz not null default now()
);

-- ─── Sweep log (cost control) ──────────────────────────────────────────────────

create table public.sweep_runs (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles (id) on delete cascade,
  agent_id   uuid references public.agents (id) on delete set null,
  trigger    text not null default 'scheduled' check (trigger in ('scheduled','manual')),
  searches   int not null default 0,
  listings   int not null default 0,
  finds      int not null default 0,
  input_tokens  int not null default 0,
  output_tokens int not null default 0,
  error      text,
  created_at timestamptz not null default now()
);
create index sweep_runs_user_day_idx on public.sweep_runs (user_id, created_at desc);

-- ─── Helpers ───────────────────────────────────────────────────────────────────

create or replace function public.are_friends(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.friendships
    where status = 'accepted'
      and ((requester = a and addressee = b) or (requester = b and addressee = a))
  )
$$;

create or replace function public.display_label(p uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(display_name, ''), '@' || handle) from public.profiles where id = p
$$;

-- ─── Row level security ────────────────────────────────────────────────────────

alter table public.profiles      enable row level security;
alter table public.agents        enable row level security;
alter table public.taste_photos  enable row level security;
alter table public.listings      enable row level security;
alter table public.finds         enable row level security;
alter table public.purchases     enable row level security;
alter table public.notes         enable row level security;
alter table public.device_tokens enable row level security;
alter table public.friendships   enable row level security;
alter table public.shares        enable row level security;
alter table public.suggestions   enable row level security;
alter table public.share_replies enable row level security;
alter table public.sweep_runs    enable row level security;

-- Start from nothing, then grant exactly what the app needs.
revoke all on public.profiles, public.agents, public.taste_photos, public.listings, public.finds,
  public.purchases, public.notes, public.device_tokens, public.friendships, public.shares,
  public.suggestions, public.share_replies, public.sweep_runs from anon, authenticated;

grant select on public.profiles to authenticated;
grant update (handle, display_name, tz, share_taste, share_purchases, settings) on public.profiles to authenticated;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.are_friends(auth.uid(), id)
         or exists (select 1 from public.friendships f
                    where (f.requester = auth.uid() and f.addressee = profiles.id)
                       or (f.addressee = auth.uid() and f.requester = profiles.id)));
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

grant select, insert, delete on public.agents to authenticated;
grant update (name, keywords, traits, makers, creators, size, max_per_item, monthly_limit, mode, voice, learned, price_note)
  on public.agents to authenticated;
create policy agents_own on public.agents for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert, delete on public.taste_photos to authenticated;
create policy taste_photos_own on public.taste_photos for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid()
              and exists (select 1 from public.agents a where a.id = agent_id and a.user_id = auth.uid())
              and storage_path like auth.uid()::text || '/%');

grant select on public.listings to authenticated;
create policy listings_read on public.listings for select to authenticated using (true);

grant select, insert, delete on public.finds to authenticated;
grant update (status, pass_reason, watching, why, agent_id) on public.finds to authenticated;
create policy finds_own on public.finds for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid()
              and (agent_id is null or exists (select 1 from public.agents a where a.id = agent_id and a.user_id = auth.uid())));

grant select, insert, delete on public.purchases to authenticated;
create policy purchases_own on public.purchases for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid()
              and (agent_id is null or exists (select 1 from public.agents a where a.id = agent_id and a.user_id = auth.uid())));

grant select, delete on public.notes to authenticated;
grant insert (id, agent_id, kind, body, sender_name) on public.notes to authenticated;
grant update (read) on public.notes to authenticated;
create policy notes_read on public.notes for select to authenticated using (user_id = auth.uid());
create policy notes_mark on public.notes for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notes_delete on public.notes for delete to authenticated using (user_id = auth.uid());
-- The app may only leave itself "learned" notes; everything else comes from the server.
create policy notes_self on public.notes for insert to authenticated
  with check (user_id = auth.uid() and kind = 'learned'
              and (agent_id is null or exists (select 1 from public.agents a where a.id = agent_id and a.user_id = auth.uid())));

grant select, delete on public.friendships to authenticated;
create policy friendships_mine on public.friendships for select to authenticated
  using (auth.uid() in (requester, addressee));
create policy friendships_unfriend on public.friendships for delete to authenticated
  using (auth.uid() in (requester, addressee));

grant select on public.shares to authenticated;
create policy shares_visible on public.shares for select to authenticated
  using (from_user = auth.uid() or auth.uid() = any (to_users));

grant select on public.suggestions to authenticated;
grant update (status) on public.suggestions to authenticated;
create policy suggestions_visible on public.suggestions for select to authenticated
  using (from_user = auth.uid() or to_user = auth.uid());
create policy suggestions_respond on public.suggestions for update to authenticated
  using (to_user = auth.uid()) with check (to_user = auth.uid());

grant select on public.share_replies to authenticated;
grant insert (share_id, body) on public.share_replies to authenticated;
create policy replies_visible on public.share_replies for select to authenticated
  using (exists (select 1 from public.shares s where s.id = share_id and (s.from_user = auth.uid() or auth.uid() = any (s.to_users))));
create policy replies_write on public.share_replies for insert to authenticated
  with check (from_user = auth.uid()
              and exists (select 1 from public.shares s where s.id = share_id and (s.from_user = auth.uid() or auth.uid() = any (s.to_users))));

grant select on public.sweep_runs to authenticated;
create policy sweep_runs_own on public.sweep_runs for select to authenticated using (user_id = auth.uid());

-- device_tokens: no direct access at all; use register_device().

-- ─── Functions the app calls ───────────────────────────────────────────────────

create or replace function public.register_device(p_token text, p_env text default 'production')
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in'; end if;
  insert into public.device_tokens (token, user_id, environment, updated_at)
  values (lower(p_token), auth.uid(), coalesce(p_env, 'production'), now())
  on conflict (token) do update set user_id = excluded.user_id, environment = excluded.environment, updated_at = now();
end $$;

create or replace function public.unregister_device(p_token text)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from public.device_tokens where token = lower(p_token) and user_id = auth.uid();
end $$;

-- Friend request by handle. Accepts automatically if they already asked you.
create or replace function public.request_friend(p_handle text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  them uuid;
  existing public.friendships;
begin
  if me is null then raise exception 'not_signed_in'; end if;
  select id into them from public.profiles where handle = lower(trim(both '@' from trim(p_handle)));
  if them is null then return jsonb_build_object('status', 'not_found'); end if;
  if them = me then return jsonb_build_object('status', 'self'); end if;
  select * into existing from public.friendships
   where least(requester, addressee) = least(me, them) and greatest(requester, addressee) = greatest(me, them);
  if found then
    if existing.status = 'pending' and existing.addressee = me then
      update public.friendships set status = 'accepted' where id = existing.id;
      return jsonb_build_object('status', 'accepted', 'id', existing.id);
    end if;
    return jsonb_build_object('status', 'exists', 'id', existing.id);
  end if;
  insert into public.friendships (requester, addressee) values (me, them) returning id into existing.id;
  return jsonb_build_object('status', 'requested', 'id', existing.id);
end $$;

create or replace function public.respond_friend(p_id uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_accept then
    update public.friendships set status = 'accepted'
     where id = p_id and addressee = auth.uid() and status = 'pending';
  else
    delete from public.friendships where id = p_id and addressee = auth.uid() and status = 'pending';
  end if;
end $$;

-- Your friends and pending requests, with their taste if they share it.
create or replace function public.my_friends()
returns table (friendship_id uuid, friend_id uuid, handle text, display_name text, status text,
               direction text, hunts text[], likes text[])
language sql stable security definer set search_path = public as $$
  select f.id,
         p.id,
         p.handle,
         p.display_name,
         f.status,
         case when f.status = 'accepted' then 'friends'
              when f.requester = auth.uid() then 'outgoing' else 'incoming' end,
         case when f.status = 'accepted' and p.share_taste then
           coalesce((select array_agg(distinct a.mission_category) from public.agents a
                      where a.user_id = p.id and a.mission_category is not null), '{}')
         else '{}' end,
         case when f.status = 'accepted' and p.share_taste then
           coalesce((select array_agg(t) from (
              select distinct t from public.agents a, unnest(a.traits) t where a.user_id = p.id limit 12) x), '{}')
         else '{}' end
    from public.friendships f
    join public.profiles p on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
   where auth.uid() in (f.requester, f.addressee)
   order by f.status, p.handle
$$;

-- Share a listing with friends. Every recipient gets it in "Suggested by friends".
create or replace function public.share_listing(p_listing uuid, p_to uuid[], p_note text default '', p_is_suggestion boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  sid uuid;
  t uuid;
begin
  if me is null then raise exception 'not_signed_in'; end if;
  if p_to is null or cardinality(p_to) = 0 then raise exception 'no_recipients'; end if;
  if not exists (select 1 from public.listings where id = p_listing) then raise exception 'listing_not_found'; end if;
  foreach t in array p_to loop
    if not public.are_friends(me, t) then raise exception 'not_friends'; end if;
  end loop;
  insert into public.shares (from_user, listing_id, to_users, note, is_suggestion)
  values (me, p_listing, p_to, left(coalesce(p_note, ''), 280), coalesce(p_is_suggestion, false))
  returning id into sid;
  insert into public.suggestions (share_id, from_user, to_user, listing_id, note)
  select sid, me, u, p_listing, left(coalesce(p_note, ''), 280) from unnest(p_to) u;
  return sid;
end $$;

revoke all on function public.register_device(text, text), public.unregister_device(text),
  public.request_friend(text), public.respond_friend(uuid, boolean), public.my_friends(),
  public.share_listing(uuid, uuid[], text, boolean) from public, anon;
grant execute on function public.register_device(text, text), public.unregister_device(text),
  public.request_friend(text), public.respond_friend(uuid, boolean), public.my_friends(),
  public.share_listing(uuid, uuid[], text, boolean) to authenticated;
revoke all on function public.are_friends(uuid, uuid), public.display_label(uuid) from public, anon;
grant execute on function public.are_friends(uuid, uuid), public.display_label(uuid) to authenticated;

-- ─── Friend activity becomes notifications ─────────────────────────────────────

create or replace function public.notify_friend_activity()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  title text;
  owner uuid;
  rcpts uuid[];
begin
  if tg_table_name = 'friendships' then
    if tg_op = 'INSERT' and new.status = 'pending' then
      insert into public.notes (user_id, friend_id, sender_name, kind, body)
      values (new.addressee, new.requester, public.display_label(new.requester), 'friend',
              public.display_label(new.requester) || ' wants to be friends on Baget.');
    elsif tg_op = 'UPDATE' and old.status = 'pending' and new.status = 'accepted' then
      insert into public.notes (user_id, friend_id, sender_name, kind, body)
      values (new.requester, new.addressee, public.display_label(new.addressee), 'friend',
              public.display_label(new.addressee) || ' accepted your friend request. You can now swap suggestions.');
    end if;
  elsif tg_table_name = 'suggestions' then
    select l.title into title from public.listings l where l.id = new.listing_id;
    insert into public.notes (user_id, friend_id, sender_name, kind, body)
    values (new.to_user, new.from_user, public.display_label(new.from_user), 'friend',
            left(public.display_label(new.from_user) || ' thinks you''d like the ' || coalesce(title, 'this')
                 || case when new.note <> '' then ': “' || new.note || '”' else '.' end, 500));
  elsif tg_table_name = 'share_replies' then
    select s.from_user, s.to_users into owner, rcpts from public.shares s where s.id = new.share_id;
    if new.from_user = owner then
      insert into public.notes (user_id, friend_id, sender_name, kind, body)
      select u, owner, public.display_label(owner), 'friend', left(public.display_label(owner) || ': ' || new.body, 500)
        from unnest(rcpts) u;
    else
      insert into public.notes (user_id, friend_id, sender_name, kind, body)
      values (owner, new.from_user, public.display_label(new.from_user), 'friend',
              left(public.display_label(new.from_user) || ': ' || new.body, 500));
    end if;
  end if;
  return new;
end $$;

create trigger friendships_notify after insert or update on public.friendships
  for each row execute function public.notify_friend_activity();
create trigger suggestions_notify after insert on public.suggestions
  for each row execute function public.notify_friend_activity();
create trigger replies_notify after insert on public.share_replies
  for each row execute function public.notify_friend_activity();

-- ─── Push: every new notification is handed to the push function ──────────────

create or replace function public.dispatch_push()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_url text;
  v_secret text;
begin
  if new.held_for_morning then return new; end if;
  begin
    execute 'select decrypted_secret from vault.decrypted_secrets where name = ''baget_project_url''' into v_url;
    execute 'select decrypted_secret from vault.decrypted_secrets where name = ''baget_cron_secret''' into v_secret;
    if v_url is not null and v_secret is not null then
      execute 'select net.http_post(url := $1, body := $2, headers := $3)'
        using v_url || '/functions/v1/push',
              jsonb_build_object('note_id', new.id),
              jsonb_build_object('Content-Type', 'application/json', 'x-baget-secret', v_secret);
    end if;
  exception when others then
    -- Push is best effort. It must never block saving the notification.
    null;
  end;
  return new;
end $$;

create trigger notes_push after insert on public.notes
  for each row execute function public.dispatch_push();

-- ─── Server-only functions (called by edge functions as service_role) ──────────

-- Agents due for a sweep, with their owner's timezone and settings.
create or replace function public.sweep_candidates(p_limit int default 20, p_daily_cap int default 12,
                                                   p_user uuid default null, p_agent uuid default null)
returns setof jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object('tz', p.tz, 'settings', p.settings, 'handle', p.handle,
           'runs_today', (select count(*) from public.sweep_runs r where r.user_id = a.user_id and r.created_at > now() - interval '24 hours'))
    from public.agents a
    join public.profiles p on p.id = a.user_id
   where (p_user is null or a.user_id = p_user)
     and (p_agent is null or a.id = p_agent)
     and (select count(*) from public.sweep_runs r where r.user_id = a.user_id and r.created_at > now() - interval '24 hours') < p_daily_cap
     and (
       -- manual sweeps: at most one per agent every 10 minutes
       (p_user is not null and coalesce(a.last_swept_at, 'epoch') < now() - interval '10 minutes')
       or
       -- scheduled sweeps: on each owner's chosen interval, never more than hourly
       (p_user is null and coalesce(a.last_swept_at, 'epoch') <
          now() - make_interval(mins => greatest(60, coalesce((p.settings ->> 'sweepMinutes')::int, 360))))
     )
   order by a.last_swept_at nulls first
   limit p_limit
$$;

-- Saves what a sweep found. Detects restocks of items people are watching.
create or replace function public.upsert_listings(p_user uuid, p_listings jsonb)
returns table (fingerprint text, id uuid, already_found boolean)
language plpgsql security definer set search_path = public as $$
declare
  l jsonb;
  lid uuid;
  was_sold_out boolean;
  now_sold_out boolean;
begin
  for l in select * from jsonb_array_elements(p_listings) loop
    now_sold_out := coalesce((l ->> 'sold_out')::boolean, false);
    select x.id, x.sold_out into lid, was_sold_out from public.listings x where x.fingerprint = l ->> 'fingerprint';
    if lid is null then
      insert into public.listings (fingerprint, title, brand, category, sku, price, market, currency, source, url, image_url,
                                   drop_at, sold_out, creator, traits, tags, sizes_in_stock)
      values (l ->> 'fingerprint', left(l ->> 'title', 200), coalesce(l ->> 'brand', ''), coalesce(l ->> 'category', 'other'),
              coalesce(l ->> 'sku', ''), (l ->> 'price')::numeric, (l ->> 'market')::numeric, coalesce(l ->> 'currency', 'USD'),
              coalesce(l ->> 'source', ''), l ->> 'url', l ->> 'image_url', (l ->> 'drop_at')::timestamptz, now_sold_out,
              l ->> 'creator',
              coalesce((select array_agg(v) from jsonb_array_elements_text(l -> 'traits') v), '{}'),
              coalesce((select array_agg(v) from jsonb_array_elements_text(l -> 'tags') v), '{}'),
              (select array_agg(v) from jsonb_array_elements_text(l -> 'sizes_in_stock') v))
      returning listings.id into lid;
    else
      update public.listings x set
        price = coalesce((l ->> 'price')::numeric, x.price),
        market = coalesce((l ->> 'market')::numeric, x.market),
        sold_out = now_sold_out,
        url = coalesce(l ->> 'url', x.url),
        image_url = coalesce(l ->> 'image_url', x.image_url),
        drop_at = coalesce((l ->> 'drop_at')::timestamptz, x.drop_at),
        sizes_in_stock = coalesce((select array_agg(v) from jsonb_array_elements_text(l -> 'sizes_in_stock') v), x.sizes_in_stock),
        last_seen_at = now()
      where x.id = lid;
      if was_sold_out and not now_sold_out then
        insert into public.notes (user_id, agent_id, sender_name, kind, body, find_id)
        select f.user_id, f.agent_id, coalesce(a.name, 'Baget'), 'restock',
               case coalesce(a.voice, 'chill')
                 when 'hype' then 'IT''S BACK. The ' || x.title || ' just restocked at ' || x.source || '. Want me to grab it before it''s gone again?'
                 when 'straight' then 'Restock: ' || x.title || ' at ' || x.source || '. Tap to review.'
                 else 'Good news, the ' || x.title || ' is back in stock at ' || x.source || '. Want it?'
               end,
               f.id
          from public.finds f
          join public.listings x on x.id = f.listing_id
          left join public.agents a on a.id = f.agent_id
         where f.listing_id = lid and f.watching and f.status = 'open';
      end if;
    end if;
    fingerprint := l ->> 'fingerprint';
    id := lid;
    already_found := exists (select 1 from public.finds f where f.user_id = p_user and f.listing_id = lid);
    return next;
  end loop;
end $$;

-- Records new finds for an agent, each with its friend-style notification.
create or replace function public.record_finds(p_agent uuid, p_finds jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare
  ag public.agents;
  f jsonb;
  fid uuid;
  n int := 0;
begin
  select * into ag from public.agents where id = p_agent;
  if not found then return 0; end if;
  for f in select * from jsonb_array_elements(p_finds) loop
    insert into public.finds (user_id, agent_id, listing_id, score, why)
    values (ag.user_id, ag.id, (f ->> 'listing_id')::uuid, (f ->> 'score')::int,
            coalesce((select array_agg(v) from jsonb_array_elements_text(f -> 'why') v), '{}'))
    on conflict (user_id, listing_id) do nothing
    returning finds.id into fid;
    if fid is not null then
      n := n + 1;
      if f ? 'note' then
        insert into public.notes (user_id, agent_id, sender_name, kind, body, find_id, held_for_morning)
        values (ag.user_id, ag.id, ag.name, f -> 'note' ->> 'kind', left(f -> 'note' ->> 'body', 500), fid,
                coalesce((f -> 'note' ->> 'held')::boolean, false));
      end if;
    end if;
    fid := null;
  end loop;
  update public.agents set last_swept_at = now() where id = ag.id;
  return n;
end $$;

-- Held notifications whose owner is now past 8am local time.
create or replace function public.release_held_notes()
returns setof uuid language sql security definer set search_path = public as $$
  update public.notes n set held_for_morning = false
    from public.profiles p
   where p.id = n.user_id and n.held_for_morning and n.pushed_at is null
     and extract(hour from now() at time zone p.tz) between 8 and 21
  returning n.id
$$;

-- Points the scheduler at this project. Called once by the setup function after deploy.
create or replace function public.configure_scheduler(p_url text, p_secret text)
returns text language plpgsql security definer set search_path = public as $$
declare
  sid uuid;
begin
  select id into sid from vault.secrets where name = 'baget_project_url';
  if sid is null then perform vault.create_secret(p_url, 'baget_project_url');
  else perform vault.update_secret(sid, p_url); end if;
  sid := null;
  select id into sid from vault.secrets where name = 'baget_cron_secret';
  if sid is null then perform vault.create_secret(p_secret, 'baget_cron_secret');
  else perform vault.update_secret(sid, p_secret); end if;

  perform cron.unschedule(jobid) from cron.job where jobname in ('baget-sweep', 'baget-release');
  perform cron.schedule('baget-sweep', '*/15 * * * *', $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'baget_project_url') || '/functions/v1/sweep',
      body := '{"mode":"scheduled"}'::jsonb,
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-baget-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'baget_cron_secret')),
      timeout_milliseconds := 150000)
  $job$);
  perform cron.schedule('baget-release', '2 * * * *', $job$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'baget_project_url') || '/functions/v1/push',
      body := '{"release":true}'::jsonb,
      headers := jsonb_build_object('Content-Type', 'application/json',
        'x-baget-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'baget_cron_secret')))
  $job$);
  return 'scheduled';
end $$;

revoke all on function public.sweep_candidates(int, int, uuid, uuid), public.upsert_listings(uuid, jsonb),
  public.record_finds(uuid, jsonb), public.release_held_notes(), public.configure_scheduler(text, text),
  public.handle_new_user(), public.limit_agents(), public.notify_friend_activity(), public.dispatch_push()
  from public, anon, authenticated;
grant execute on function public.sweep_candidates(int, int, uuid, uuid), public.upsert_listings(uuid, jsonb),
  public.record_finds(uuid, jsonb), public.release_held_notes(), public.configure_scheduler(text, text)
  to service_role;

-- ─── Taste photo storage ───────────────────────────────────────────────────────

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('taste-photos', 'taste-photos', false, 2097152, array['image/jpeg'])
on conflict (id) do nothing;

create policy taste_photo_files_read on storage.objects for select to authenticated
  using (bucket_id = 'taste-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy taste_photo_files_write on storage.objects for insert to authenticated
  with check (bucket_id = 'taste-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy taste_photo_files_delete on storage.objects for delete to authenticated
  using (bucket_id = 'taste-photos' and (storage.foldername(name))[1] = auth.uid()::text);
