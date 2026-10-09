-- UX overhaul (all additive, so the red-30 build keeps working against this database).

-- 1. Deal verdicts: what other stores charge for the same product (Google Shopping), and the lowest.
alter table public.listings add column if not exists offers jsonb not null default '[]'::jsonb
  check (jsonb_typeof(offers) = 'array' and pg_column_size(offers) <= 4096);
alter table public.listings add column if not exists low_price numeric;
alter table public.listings add column if not exists low_store text check (char_length(low_store) <= 80);
alter table public.listings add column if not exists offers_checked_at timestamptz;

-- 2. Watching a find: the price when you started watching, so a drop can be spotted.
alter table public.finds add column if not exists watch_price numeric;
grant update (watch_price) on public.finds to authenticated;

-- 3. New notification kinds: the morning digest ("Today's Drop") and price drops on watched finds.
do $$
declare c record;
begin
  for c in select conname from pg_constraint
           where conrelid = 'public.notes'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%kind%release%'
  loop
    execute format('alter table public.notes drop constraint %I', c.conname);
  end loop;
end $$;
alter table public.notes add constraint notes_kind_check
  check (kind in ('release','available','steal','watch','restock','bought','budget','learned','friend','digest','drop'));

-- 4. One digest per person per day.
alter table public.profiles add column if not exists last_digest_on date;

-- Metrics events for the new screens.
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
      'avatar_changed','profile_opened',
      'hunt_started','onboarding_done','swipe','ask_about','taste_removed','today_viewed'
    )
    and pg_column_size(props) <= 4096
    and coalesce(char_length(app_version), 0) <= 32
    and occurred_at between now() - interval '30 days' and now() + interval '1 day'
  );
