-- Scouts are built around what you're into ("interest", the default: hunts wide and keeps going) or one specific thing
-- ("specific": a grail, a size, a price; when it's bought, the scout offers to keep going on the wider interest).
alter table public.agents add column if not exists focus text not null default 'interest';
alter table public.agents drop constraint if exists agents_focus_check;
alter table public.agents add constraint agents_focus_check check (focus in ('interest', 'specific'));
