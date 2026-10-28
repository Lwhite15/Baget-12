-- Many more finds. A scout's Finds should keep filling with new options that fit what they asked for, not the same
-- handful: each scout can now add up to 30 finds a day (60 on Pro). Texts stay rare: still only a hunt's 2 strongest
-- finds (score 60+, at most 4 a day) become a note. Untouched finds still archive after 7 days.
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
  cap := case when public.is_pro(ag.user_id) then 60 else 30 end;
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
