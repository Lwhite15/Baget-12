-- Fewer, better finds. Testers were getting ~10 finds and ~15 inbox notes a day and acting on 8% of them; the rest piled
-- up (150+ unopened for some). Now:
--   * Each scout adds at most 5 finds a day (8 on Pro), strongest first.
--   * Only a scout's 2 strongest finds per hunt (score 60+, at most 4 a day) become a note in the inbox; the rest just
--     land in Finds.
--   * Finds nobody touched for 7 days are archived (not counted as a pass), unless they're watched, liked, have a
--     reminder, or are a release still to come. Their inbox notes are marked read.

create or replace function public.record_finds(p_agent uuid, p_finds jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare
  ag public.agents;
  f jsonb;
  fid uuid;
  n int := 0;
  cap int;
  today int;
  noted int := 0;
  notes_today int;
begin
  select * into ag from public.agents where id = p_agent;
  if not found then return 0; end if;
  cap := case when public.is_pro(ag.user_id) then 8 else 5 end;
  select count(*) into today from public.finds where agent_id = ag.id and created_at > now() - interval '24 hours';
  select count(*) into notes_today from public.notes
   where agent_id = ag.id and find_id is not null and created_at > now() - interval '24 hours';
  for f in select x from jsonb_array_elements(case when jsonb_typeof(p_finds) = 'array' then p_finds else '[]'::jsonb end) x
            order by coalesce((x ->> 'score')::int, 0) desc loop
    exit when today + n >= cap;
    insert into public.finds (user_id, agent_id, listing_id, score, why)
    values (ag.user_id, ag.id, (f ->> 'listing_id')::uuid, (f ->> 'score')::int,
            coalesce(public.jsonb_texts(f -> 'why'), '{}'))
    on conflict (user_id, listing_id) do nothing
    returning finds.id into fid;
    if fid is not null then
      n := n + 1;
      if f ? 'note' and noted < 2 and notes_today + noted < 4 and coalesce((f ->> 'score')::int, 0) >= 60 then
        insert into public.notes (user_id, agent_id, sender_name, kind, body, find_id, held_for_morning)
        values (ag.user_id, ag.id, ag.name, f -> 'note' ->> 'kind', left(f -> 'note' ->> 'body', 500), fid,
                coalesce((f -> 'note' ->> 'held')::boolean, false));
        noted := noted + 1;
      end if;
    end if;
    fid := null;
  end loop;
  update public.agents set last_swept_at = now() where id = ag.id;
  return n;
end $$;
revoke all on function public.record_finds(uuid, jsonb) from public, anon, authenticated;
grant execute on function public.record_finds(uuid, jsonb) to service_role;

create or replace function public.archive_stale_finds(p_days int default 7)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with stale as (
    update public.finds f set status = 'removed'
      from public.listings l
     where l.id = f.listing_id and f.status = 'open' and not coalesce(f.watching, false)
       and f.created_at < now() - make_interval(days => greatest(p_days, 1))
       and not (l.drop_at is not null and l.drop_at > now())
       and not exists (select 1 from public.release_reminders r where r.user_id = f.user_id and r.listing_id = f.listing_id)
    returning f.id
  ), seen as (
    update public.notes set read = true where find_id in (select id from stale) and not read returning 1
  )
  select count(*) into n from stale;
  return n;
end $$;
revoke all on function public.archive_stale_finds(int) from public, anon, authenticated;
grant execute on function public.archive_stale_finds(int) to service_role;

select public.archive_stale_finds(7);
