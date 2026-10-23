-- App metrics: accept any well-formed event name. A fixed list meant every new event the app learned (reminder_set)
-- was rejected, and the app throws away a rejected batch along with the good events in it.
drop policy if exists "app inserts events" on public.events;
create policy "app inserts events" on public.events
  for insert to anon
  with check (
    name ~ '^[a-z][a-z0-9_]{1,39}$'
    and pg_column_size(props) <= 4096
    and coalesce(char_length(app_version), 0) <= 32
    and occurred_at between now() - interval '30 days' and now() + interval '1 day'
  );
