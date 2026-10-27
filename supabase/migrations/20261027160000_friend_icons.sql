-- Friends see each other's icon (the emoji, color or photo you picked in Settings) next to your name.

-- Each friend's icon (profiles.settings.avatar: style, emoji, color, photoID), for everyone you're connected with.
create or replace function public.friend_icons()
returns table (friend_id uuid, icon jsonb) language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.settings -> 'avatar', '{}'::jsonb)
    from public.friendships f
    join public.profiles p on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
   where auth.uid() in (f.requester, f.addressee)
$$;
revoke all on function public.friend_icons() from public, anon;
grant execute on function public.friend_icons() to authenticated;

-- Icon photos live in <uid>/avatars/. Friends (accepted) can read them; nothing else in someone's folder.
create or replace function public.is_friend_of(other text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.friendships f
                  where f.status = 'accepted'
                    and ((f.requester = auth.uid() and f.addressee::text = other)
                      or (f.addressee = auth.uid() and f.requester::text = other)))
$$;
revoke all on function public.is_friend_of(text) from public, anon;
grant execute on function public.is_friend_of(text) to authenticated;

drop policy if exists "friends read icon photos" on storage.objects;
create policy "friends read icon photos" on storage.objects for select to authenticated
  using (bucket_id = 'taste-photos' and (storage.foldername(name))[2] = 'avatars'
         and public.is_friend_of((storage.foldername(name))[1]));

-- The feedback-screenshot read policy looked at app_admins directly, which signed-in people can't read, so any
-- storage read that had to check it failed. Ask a function that can.
create or replace function public.is_app_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.app_admins where user_id = auth.uid())
$$;
revoke all on function public.is_app_admin() from public, anon;
grant execute on function public.is_app_admin() to authenticated;
drop policy if exists feedback_files_read on storage.objects;
create policy feedback_files_read on storage.objects for select to authenticated
  using (bucket_id = 'feedback' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_app_admin()));
