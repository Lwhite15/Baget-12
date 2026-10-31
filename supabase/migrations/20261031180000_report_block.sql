-- Reporting and blocking (App Store guideline 1.2: apps where people send each other content must let them report
-- and block). A block ends the friendship, removes what they sent you, and stops them finding, adding or sending you
-- anything, both ways. Reports go to the team, who review them within 24 hours.

create table if not exists public.user_blocks (
  blocker    uuid not null references public.profiles (id) on delete cascade,
  blocked    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked),
  check (blocker <> blocked)
);
alter table public.user_blocks enable row level security;
drop policy if exists user_blocks_own on public.user_blocks;
create policy user_blocks_own on public.user_blocks for select to authenticated using (blocker = auth.uid());

create table if not exists public.user_reports (
  id            uuid primary key default gen_random_uuid(),
  reporter      uuid not null references public.profiles (id) on delete cascade,
  reported      uuid not null references public.profiles (id) on delete cascade,
  reason        text not null check (reason in ('spam', 'inappropriate', 'harassment', 'other')),
  detail        text not null default '' check (char_length(detail) <= 500),
  suggestion_id uuid references public.suggestions (id) on delete set null,
  status        text not null default 'open' check (status in ('open', 'reviewed')),
  created_at    timestamptz not null default now()
);
alter table public.user_reports enable row level security;
drop policy if exists user_reports_admin on public.user_reports;
create policy user_reports_admin on public.user_reports for select to authenticated using (public.is_app_admin());

create or replace function public.is_blocked(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_blocks where (blocker = a and blocked = b) or (blocker = b and blocked = a))
$$;
revoke all on function public.is_blocked(uuid, uuid) from public, anon, authenticated;

create or replace function public.block_user(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not_signed_in'; end if;
  if p_user is null or p_user = me then raise exception 'bad_user'; end if;
  insert into public.user_blocks (blocker, blocked) values (me, p_user) on conflict do nothing;
  delete from public.friendships where least(requester, addressee) = least(me, p_user) and greatest(requester, addressee) = greatest(me, p_user);
  delete from public.suggestions where (from_user = p_user and to_user = me) or (from_user = me and to_user = p_user);
end $$;

create or replace function public.unblock_user(p_user uuid) returns void
language sql security definer set search_path = public as $$
  delete from public.user_blocks where blocker = auth.uid() and blocked = p_user
$$;

create or replace function public.my_blocks()
returns table (user_id uuid, handle text, display_name text, blocked_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p.id, p.handle, p.display_name, b.created_at from public.user_blocks b join public.profiles p on p.id = b.blocked
   where b.blocker = auth.uid() order by b.created_at desc
$$;

create or replace function public.report_user(p_user uuid, p_reason text, p_detail text default '', p_suggestion uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not_signed_in'; end if;
  if p_user is null or p_user = me then raise exception 'bad_user'; end if;
  if (select count(*) from public.user_reports where reporter = me and created_at > now() - interval '1 day') >= 20 then
    raise exception 'too_many_reports';
  end if;
  insert into public.user_reports (reporter, reported, reason, detail, suggestion_id)
  values (me, p_user, p_reason, left(coalesce(p_detail, ''), 500),
          (select id from public.suggestions where id = p_suggestion and to_user = me));
end $$;

revoke all on function public.block_user(uuid), public.unblock_user(uuid), public.my_blocks(), public.report_user(uuid, text, text, uuid) from public, anon;
grant execute on function public.block_user(uuid), public.unblock_user(uuid), public.my_blocks(), public.report_user(uuid, text, text, uuid) to authenticated;

-- Blocked either way: they can't be found by handle (looks like no such person), friended, or sent anything.
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
  if public.is_blocked(me, them) then return jsonb_build_object('status', 'not_found'); end if;
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

create or replace function public.no_blocked_contact() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'friendships' then
    if public.is_blocked(new.requester, new.addressee) then raise exception 'blocked'; end if;
  else
    if public.is_blocked(new.from_user, new.to_user) then return null; end if;
  end if;
  return new;
end $$;
drop trigger if exists friendships_no_blocked on public.friendships;
create trigger friendships_no_blocked before insert on public.friendships for each row execute function public.no_blocked_contact();
drop trigger if exists suggestions_no_blocked on public.suggestions;
create trigger suggestions_no_blocked before insert on public.suggestions for each row execute function public.no_blocked_contact();

-- Each report texts the team right away (the "feedback" kind is always texted), so it's reviewed within 24 hours.
create or replace function public.notify_report() returns trigger
language plpgsql security definer set search_path = public as $$
declare who text;
begin
  select '@' || handle into who from public.profiles where id = new.reported;
  insert into public.notes (user_id, sender_name, kind, body)
  select a.user_id, 'Report', 'feedback',
         left('🚩 ' || coalesce(who, 'Someone') || ' reported for ' || new.reason
              || case when new.detail <> '' then ': ' || new.detail else '' end, 480)
    from public.app_admins a
   where a.user_id <> new.reporter;
  return new;
end $$;
drop trigger if exists user_reports_notify on public.user_reports;
create trigger user_reports_notify after insert on public.user_reports for each row execute function public.notify_report();
