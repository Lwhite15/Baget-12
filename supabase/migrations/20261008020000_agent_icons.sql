-- Each agent can have its own icon: an emoji or initials on a colored tile, or a photo.
-- Same shape as the person's icon in profiles.settings: {"style","emoji","color","photoID"}.
alter table public.agents add column if not exists icon jsonb not null default '{}'::jsonb
  check (jsonb_typeof(icon) = 'object' and pg_column_size(icon) <= 1024);
grant update (icon) on public.agents to authenticated;
