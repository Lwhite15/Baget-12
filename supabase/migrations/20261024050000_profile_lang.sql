-- Settings Baget's server keeps for you (who you shop for) survive the app saving its own settings, which replaces the
-- whole settings object. The app now also sends its language ("lang"), so scouts write to you in it.
create or replace function public.keep_server_settings() returns trigger language plpgsql as $$
begin
  if old.settings ? 'department' and not (coalesce(new.settings, '{}'::jsonb) ? 'department') then
    new.settings := coalesce(new.settings, '{}'::jsonb) || jsonb_build_object('department', old.settings -> 'department');
  end if;
  return new;
end $$;
drop trigger if exists keep_server_settings on public.profiles;
create trigger keep_server_settings before update of settings on public.profiles
  for each row execute function public.keep_server_settings();
