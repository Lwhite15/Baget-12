-- 1. Likes: a find can be liked (the agent leans into it) as well as passed or bought.
do $$
declare c record;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.finds'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%status%'
  loop
    execute format('alter table public.finds drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.finds add constraint finds_status_check check (status in ('open','liked','passed','acquired'));

-- 2. Agents have no spending limits at all.
alter table public.agents drop column if exists max_per_item;
alter table public.agents drop column if exists monthly_limit;

-- 3. Metrics events for likes.
drop policy if exists "app inserts events" on public.events;
create policy "app inserts events" on public.events
  for insert to anon
  with check (
    name in (
      'app_opened','live_section_viewed','custom_section_added','spending_viewed','background_simulated',
      'agent_deployed','agent_retired','agent_setting_changed','agent_learned','taste_photo_added','sweep_run','signed_in','chat_sent',
      'find_created','story_sent_to_agent','checkout_opened','purchase_confirmed','auto_purchased',
      'find_watched','find_passed','find_liked','find_unliked','notification_sent','notification_opened',
      'friend_invited','item_shared','suggestion_sent','suggestion_accepted','suggestion_passed',
      'avatar_changed','profile_opened'
    )
    and pg_column_size(props) <= 4096
    and coalesce(char_length(app_version), 0) <= 32
    and occurred_at between now() - interval '30 days' and now() + interval '1 day'
  );

-- How people react to finds, by category.
create or replace view metrics.find_reactions as
select props->>'category' as category,
       count(*) filter (where name = 'find_liked')          as liked,
       count(*) filter (where name = 'find_unliked')        as unliked,
       count(*) filter (where name = 'find_passed')         as passed,
       count(*) filter (where name = 'purchase_confirmed')  as bought
  from public.events
 where name in ('find_liked','find_unliked','find_passed','purchase_confirmed')
 group by 1;
revoke all on metrics.find_reactions from anon, authenticated;
