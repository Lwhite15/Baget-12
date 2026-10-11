-- Removing a find hides it without teaching the agent anything (unlike Pass). The row stays so the agent
-- remembers it already showed you that item and never brings it back.
alter table public.finds drop constraint if exists finds_status_check;
alter table public.finds add constraint finds_status_check check (status in ('open','liked','passed','acquired','removed'));
