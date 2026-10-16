-- Tester feedback from inside the app: a bug, an idea or something they love, with an optional screenshot.
-- Each one texts the owner (admins) right away, and shows on the Stats screen.

create table if not exists public.feedback (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  kind        text not null default 'other' check (kind in ('bug', 'idea', 'love', 'other')),
  body        text not null check (char_length(body) between 1 and 2000),
  app_version text not null default '' check (char_length(app_version) <= 32),
  device      text not null default '' check (char_length(device) <= 64),
  screen      text not null default '' check (char_length(screen) <= 40),
  photo_path  text check (photo_path is null or char_length(photo_path) <= 200),
  status      text not null default 'new' check (status in ('new', 'seen', 'done')),
  created_at  timestamptz not null default now()
);
create index if not exists feedback_time_idx on public.feedback (created_at desc);
alter table public.feedback enable row level security;
revoke all on public.feedback from anon, authenticated;
grant insert (kind, body, app_version, device, screen, photo_path) on public.feedback to authenticated;
grant select on public.feedback to authenticated;
drop policy if exists feedback_insert_own on public.feedback;
create policy feedback_insert_own on public.feedback for insert to authenticated with check (user_id = auth.uid());
drop policy if exists feedback_read_own on public.feedback;
create policy feedback_read_own on public.feedback for select to authenticated using (user_id = auth.uid());

-- Screenshots: private; each person writes to their own folder, admins can read all.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('feedback', 'feedback', false, 3145728, array['image/jpeg'])
on conflict (id) do nothing;
drop policy if exists feedback_files_write on storage.objects;
create policy feedback_files_write on storage.objects for insert to authenticated
  with check (bucket_id = 'feedback' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists feedback_files_read on storage.objects;
create policy feedback_files_read on storage.objects for select to authenticated
  using (bucket_id = 'feedback' and ((storage.foldername(name))[1] = auth.uid()::text
         or exists (select 1 from public.app_admins where user_id = auth.uid())));

-- Notes: a "feedback" kind, always texted.
alter table public.notes drop constraint if exists notes_kind_check;
alter table public.notes add constraint notes_kind_check
  check (kind in ('release','available','steal','watch','restock','bought','budget','learned','friend','digest','drop','feedback'));

create or replace function public.notify_feedback()
returns trigger language plpgsql security definer set search_path = public as $$
declare who text;
begin
  select coalesce(nullif(display_name, ''), '@' || handle) into who from public.profiles where id = new.user_id;
  insert into public.notes (user_id, sender_name, kind, body)
  select a.user_id, 'Tester feedback', 'feedback',
         left((case new.kind when 'bug' then '🐞 ' when 'idea' then '💡 ' when 'love' then '❤️ ' else '' end)
              || coalesce(who, 'Someone') || ': ' || new.body, 480)
    from public.app_admins a
   where a.user_id <> new.user_id;
  return new;
end $$;
drop trigger if exists feedback_notify on public.feedback;
create trigger feedback_notify after insert on public.feedback for each row execute function public.notify_feedback();

-- Admins: everything, newest first, with who sent it.
create or replace function public.admin_feedback(p_limit int default 50)
returns setof jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from public.app_admins where user_id = auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return query
    select to_jsonb(f) || jsonb_build_object('who', coalesce(nullif(p.display_name, ''), '@' || p.handle))
      from public.feedback f join public.profiles p on p.id = f.user_id
     order by f.created_at desc
     limit greatest(1, least(coalesce(p_limit, 50), 200));
end $$;
revoke all on function public.admin_feedback(int) from public, anon;
grant execute on function public.admin_feedback(int) to authenticated;

create or replace function public.admin_mark_feedback(p_id uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.app_admins where user_id = auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  update public.feedback set status = p_status where id = p_id and p_status in ('new', 'seen', 'done');
end $$;
revoke all on function public.admin_mark_feedback(uuid, text) from public, anon;
grant execute on function public.admin_mark_feedback(uuid, text) to authenticated;
