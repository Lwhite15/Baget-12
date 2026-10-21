-- Release reminders: on an upcoming find, the person picks when to be reminded (at the drop, some minutes/hours/days
-- before, or an exact time). Reminders tied to the drop follow it if the release date moves.
alter table public.notes drop constraint if exists notes_kind_check;
alter table public.notes add constraint notes_kind_check
  check (kind in ('release','available','steal','watch','restock','bought','budget','learned','friend','digest','drop','feedback','reminder'));

create table if not exists public.release_reminders (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  listing_id     uuid not null references public.listings (id) on delete cascade,
  find_id        uuid references public.finds (id) on delete cascade,
  offset_minutes int check (offset_minutes is null or offset_minutes between 0 and 43200),   -- before the drop; null = exact time
  remind_at      timestamptz not null,
  sent_at        timestamptz,
  created_at     timestamptz not null default now(),
  unique (user_id, listing_id)
);
create index if not exists release_reminders_due on public.release_reminders (remind_at) where sent_at is null;
create index if not exists release_reminders_listing on public.release_reminders (listing_id);
create index if not exists release_reminders_find on public.release_reminders (find_id);
alter table public.release_reminders enable row level security;
revoke all on public.release_reminders from anon, authenticated;
grant select, insert, update, delete on public.release_reminders to authenticated;
grant select, insert, update, delete on public.release_reminders to service_role;
drop policy if exists release_reminders_own on public.release_reminders;
create policy release_reminders_own on public.release_reminders for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Sets (or replaces) your reminder for an upcoming product. Give offset_minutes for "N minutes before the drop", or
-- remind_at for an exact time. Returns when it will go off.
create or replace function public.set_release_reminder(p_listing uuid, p_find uuid default null, p_offset_minutes int default null, p_remind_at timestamptz default null)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); drop_at timestamptz; at timestamptz;
begin
  if uid is null then raise exception 'sign in first' using errcode = '42501'; end if;
  select l.drop_at into drop_at from public.listings l where l.id = p_listing;
  if p_offset_minutes is not null then
    if drop_at is null then raise exception 'no release date for this product yet' using errcode = '22023'; end if;
    at := drop_at - make_interval(mins => greatest(0, least(p_offset_minutes, 43200)));
  else
    at := p_remind_at;
  end if;
  if at is null then raise exception 'pick when to be reminded' using errcode = '22023'; end if;
  if at < now() - interval '1 minute' then raise exception 'that time has already passed' using errcode = '22023'; end if;
  insert into public.release_reminders (user_id, listing_id, find_id, offset_minutes, remind_at)
    values (uid, p_listing, p_find, case when p_offset_minutes is null then null else greatest(0, least(p_offset_minutes, 43200)) end, at)
  on conflict (user_id, listing_id) do update
    set find_id = excluded.find_id, offset_minutes = excluded.offset_minutes, remind_at = excluded.remind_at, sent_at = null;
  return at;
end $$;
revoke all on function public.set_release_reminder(uuid, uuid, int, timestamptz) from public, anon;
grant execute on function public.set_release_reminder(uuid, uuid, int, timestamptz) to authenticated;

-- A release date that moves takes its "before the drop" reminders with it.
create or replace function public.follow_drop_date()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.drop_at is distinct from old.drop_at and new.drop_at is not null then
    update public.release_reminders
       set remind_at = new.drop_at - make_interval(mins => offset_minutes), sent_at = null
     where listing_id = new.id and offset_minutes is not null and (sent_at is null or new.drop_at > now());
  end if;
  return new;
end $$;
drop trigger if exists listings_follow_drop on public.listings;
create trigger listings_follow_drop after update of drop_at on public.listings
  for each row execute function public.follow_drop_date();

-- Sends every reminder that's due (called every 5 minutes by the scheduler). Each becomes a text that always goes out.
create or replace function public.send_release_reminders()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with due as (
    update public.release_reminders r set sent_at = now()
     where r.sent_at is null and r.remind_at <= now()
    returning r.*
  ), ins as (
    insert into public.notes (user_id, agent_id, sender_name, kind, body, find_id)
    select d.user_id, f.agent_id, coalesce(a.name, 'Baget'), 'reminder',
           left(case
             when l.drop_at is null or l.drop_at <= now() + interval '2 minutes'
               then 'It''s time: the ' || l.title || ' is releasing now at ' || coalesce(nullif(l.source, ''), 'the store') || '. Go get it.'
             else 'Reminder: the ' || l.title || ' releases ' ||
                  to_char(l.drop_at at time zone (case when exists (select 1 from pg_timezone_names z where z.name = p.tz) then p.tz else 'America/New_York' end), 'FMDay, Mon FMDD "at" FMHH12:MI AM') ||
                  ' at ' || coalesce(nullif(l.source, ''), 'the store') || '.'
           end, 480),
           d.find_id
      from due d
      join public.listings l on l.id = d.listing_id
      join public.profiles p on p.id = d.user_id
      left join public.finds f on f.id = d.find_id
      left join public.agents a on a.id = f.agent_id
    returning 1
  )
  select count(*) into n from ins;
  return n;
end $$;
revoke all on function public.send_release_reminders() from public, anon, authenticated;
grant execute on function public.send_release_reminders() to service_role;
