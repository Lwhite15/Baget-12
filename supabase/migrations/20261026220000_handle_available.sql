-- Usernames are unique (profiles.handle is unique and always lowercase). This lets Settings say whether one is free
-- while you type, before you save it.
create or replace function public.handle_available(p_handle text)
returns text language sql stable security definer set search_path = public as $$
  select case
    when h !~ '^[a-z0-9._]{3,24}$' then 'invalid'
    when exists (select 1 from public.profiles where handle = h and id = auth.uid()) then 'yours'
    when exists (select 1 from public.profiles where handle = h) then 'taken'
    else 'available' end
    from (select lower(trim(both '@' from trim(coalesce(p_handle, '')))) as h) x
$$;
revoke all on function public.handle_available(text) from public, anon;
grant execute on function public.handle_available(text) to authenticated;
