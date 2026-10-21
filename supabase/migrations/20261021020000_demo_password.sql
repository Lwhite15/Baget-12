-- The App Review demo account's password is set from a workflow that also puts it straight into App Store Connect, so
-- it's never typed or shown anywhere. Takes a bcrypt hash only. Only ever for the demo account.
create or replace function public.set_demo_password(p_hash text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if p_hash !~ '^\$2[aby]\$\d\d\$[./A-Za-z0-9]{53}$' then raise exception 'bcrypt hash required'; end if;
  update auth.users set encrypted_password = p_hash, updated_at = now() where id = '0a99e1e0-5eed-4d3e-8a00-00000000d3e0';
  return found;
end $$;
revoke all on function public.set_demo_password(text) from public, anon, authenticated;
grant execute on function public.set_demo_password(text) to service_role;
