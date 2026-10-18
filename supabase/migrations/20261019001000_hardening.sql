-- Pre-launch hardening from the database advisor.

-- A trigger function has no business being callable through the API.
revoke all on function public.notify_feedback() from public, anon, authenticated;

-- Pin search_path on the remaining helpers.
do $$
declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname in ('hunt_start', 'in_hunt_window', 'claude_cost', 'touch_updated_at') loop
    execute format('alter function %s set search_path = public', f);
  end loop;
end $$;

-- Row security: evaluate auth.uid() once per query instead of once per row (same rules, much faster on big tables).
do $$
declare p record; q text; c text; stmt text;
begin
  for p in select * from pg_policies where schemaname = 'public' loop
    q := p.qual; c := p.with_check;
    if (coalesce(q, '') || coalesce(c, '')) !~ 'auth\.uid\(\)' then continue; end if;
    if (coalesce(q, '') || coalesce(c, '')) ~* 'select\s+auth\.uid\(\)' then continue; end if;   -- already done
    q := regexp_replace(q, 'auth\.uid\(\)', '(select auth.uid())', 'g');
    c := regexp_replace(c, 'auth\.uid\(\)', '(select auth.uid())', 'g');
    stmt := format('alter policy %I on %I.%I', p.policyname, p.schemaname, p.tablename);
    if q is not null then stmt := stmt || format(' using (%s)', q); end if;
    if c is not null then stmt := stmt || format(' with check (%s)', c); end if;
    execute stmt;
  end loop;
end $$;

-- Indexes for the foreign keys the advisor flagged (deletes and joins stay fast as tables grow).
create index if not exists buy_clicks_listing_idx on public.buy_clicks (listing_id);
create index if not exists buy_clicks_user_idx on public.buy_clicks (user_id);
create index if not exists device_tokens_user_idx on public.device_tokens (user_id);
create index if not exists feed_reactions_listing_idx on public.feed_reactions (listing_id);
create index if not exists feedback_user_idx on public.feedback (user_id);
create index if not exists finds_agent_idx on public.finds (agent_id);
create index if not exists finds_listing_idx on public.finds (listing_id);
create index if not exists friendships_addressee_idx on public.friendships (addressee);
create index if not exists friendships_requester_idx on public.friendships (requester);
create index if not exists notes_agent_idx on public.notes (agent_id);
create index if not exists notes_find_idx on public.notes (find_id);
create index if not exists notes_friend_idx on public.notes (friend_id);
create index if not exists purchases_agent_idx on public.purchases (agent_id);
create index if not exists purchases_listing_idx on public.purchases (listing_id);
create index if not exists share_replies_from_idx on public.share_replies (from_user);
create index if not exists share_replies_share_idx on public.share_replies (share_id);
create index if not exists shares_from_idx on public.shares (from_user);
create index if not exists shares_listing_idx on public.shares (listing_id);
create index if not exists suggestions_from_idx on public.suggestions (from_user);
create index if not exists suggestions_listing_idx on public.suggestions (listing_id);
create index if not exists suggestions_share_idx on public.suggestions (share_id);
create index if not exists sweep_runs_agent_idx on public.sweep_runs (agent_id);
create index if not exists sweep_runs_user_time_idx on public.sweep_runs (user_id, created_at desc);
create index if not exists taste_photos_user_idx on public.taste_photos (user_id);

-- Descriptions the stricter matcher dropped (long marketplace titles get shortened when echoed): try again.
update public.listings set about_checked_at = null where about is null and about_checked_at is not null;
