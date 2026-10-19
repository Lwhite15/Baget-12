-- The screenshots account's password is reset every run: set the new bcrypt hash directly (updating an existing user
-- through the admin API doesn't change it). Only ever for the screenshots account.
create or replace function public.set_shots_password(p_hash text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if p_hash !~ '^\$2[aby]\$\d\d\$[./A-Za-z0-9]{53}$' then raise exception 'bcrypt hash required'; end if;
  update auth.users set encrypted_password = p_hash, updated_at = now() where id = '0a99e1e0-5eed-4d3e-8a00-0000000054a7';
  return found;
end $$;
revoke all on function public.set_shots_password(text) from public, anon, authenticated;
grant execute on function public.set_shots_password(text) to service_role;
