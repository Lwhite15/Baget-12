-- The profile screen: allow its two metrics events alongside the existing ones.
drop policy if exists "app inserts events" on public.events;
create policy "app inserts events" on public.events
  for insert to anon
  with check (
    name in (
      'app_opened','live_section_viewed','custom_section_added','spending_viewed','background_simulated',
      'agent_deployed','agent_retired','agent_setting_changed','agent_learned','taste_photo_added','sweep_run','signed_in','chat_sent',
      'find_created','story_sent_to_agent','checkout_opened','purchase_confirmed','auto_purchased',
      'find_watched','find_passed','notification_sent','notification_opened',
      'friend_invited','item_shared','suggestion_sent','suggestion_accepted','suggestion_passed',
      'avatar_changed','profile_opened'
    )
    and pg_column_size(props) <= 4096
    and coalesce(char_length(app_version), 0) <= 32
    and occurred_at between now() - interval '30 days' and now() + interval '1 day'
  );
