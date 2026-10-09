-- "How often Baget texts you": notes that aren't texted (by your setting) are marked skipped, still in the inbox.
alter table public.notes add column if not exists push_skipped boolean not null default false;
