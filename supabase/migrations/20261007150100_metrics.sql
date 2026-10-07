-- Baget metrics backend (Supabase / Postgres)
-- Applied automatically by the deploy pipeline. Safe to re-run.
--
-- Security model
--   * The app sends events with the public "anon" key. It can INSERT events and nothing else:
--     it cannot read, change or delete any event, including its own.
--   * Inserts are checked: known event names only, bounded size, sane timestamps.
--   * Metric views live in the "metrics" schema, which is not exposed through the API.
--     Read them in the SQL editor, or from a dashboard tool using a private database login.
--   * Events carry a random install ID. No names, emails, handles or device identifiers.

-- ─── Raw events ────────────────────────────────────────────────────────────────

create table if not exists public.events (
  id           uuid primary key,
  install_id   uuid not null,
  session_id   uuid not null,
  name         text not null,
  occurred_at  timestamptz not null,
  received_at  timestamptz not null default now(),
  app_version  text,
  props        jsonb not null default '{}'::jsonb
);

create index if not exists events_name_time_idx    on public.events (name, occurred_at);
create index if not exists events_install_time_idx on public.events (install_id, occurred_at);

alter table public.events enable row level security;

-- Remove any broad default grants, then allow exactly one thing: inserting events.
revoke all on public.events from anon, authenticated;
grant insert on public.events to anon;

drop policy if exists "app inserts events" on public.events;
create policy "app inserts events" on public.events
  for insert to anon
  with check (
    name in (
      'app_opened','live_section_viewed','custom_section_added','spending_viewed','background_simulated',
      'agent_deployed','agent_retired','agent_setting_changed','agent_learned','taste_photo_added','sweep_run','signed_in','chat_sent',
      'find_created','story_sent_to_agent','checkout_opened','purchase_confirmed','auto_purchased',
      'find_watched','find_passed','notification_sent','notification_opened',
      'friend_invited','item_shared','suggestion_sent','suggestion_accepted','suggestion_passed'
    )
    and pg_column_size(props) <= 4096
    and coalesce(char_length(app_version), 0) <= 32
    and occurred_at between now() - interval '30 days' and now() + interval '1 day'
  );

-- ─── Metric views (private schema) ─────────────────────────────────────────────

create schema if not exists metrics;
revoke all on schema metrics from anon, authenticated;

-- 1. Spending each month: what users bought through Baget (confirmed + auto-buy).
create or replace view metrics.monthly_spend as
select
  date_trunc('month', occurred_at)::date                         as month,
  count(*)                                                       as purchases,
  count(distinct install_id)                                     as buyers,
  round(sum((props->>'amount')::numeric), 2)                     as total_spend,
  round(avg((props->>'amount')::numeric), 2)                     as avg_order,
  count(*) filter (where name = 'auto_purchased')                as auto_buys
from public.events
where name in ('purchase_confirmed', 'auto_purchased')
group by 1
order by 1 desc;

-- 2. Spending each month by category.
create or replace view metrics.spend_by_category as
select
  date_trunc('month', occurred_at)::date     as month,
  props->>'category'                         as category,
  count(*)                                   as purchases,
  round(sum((props->>'amount')::numeric), 2) as total_spend
from public.events
where name in ('purchase_confirmed', 'auto_purchased')
group by 1, 2
order by 1 desc, total_spend desc;

-- 3. Finds funnel by category: found -> checkout opened -> bought, and how many get passed.
create or replace view metrics.find_funnel as
with c as (
  select
    props->>'category' as category,
    count(*) filter (where name = 'find_created')                               as finds,
    count(*) filter (where name = 'checkout_opened')                            as checkouts,
    count(*) filter (where name in ('purchase_confirmed','auto_purchased'))     as purchases,
    count(*) filter (where name = 'find_watched')                               as watched,
    count(*) filter (where name = 'find_passed')                                as passed
  from public.events
  where name in ('find_created','checkout_opened','purchase_confirmed','auto_purchased','find_watched','find_passed')
  group by 1
)
select *,
  round(100.0 * checkouts / nullif(finds, 0), 1) as pct_finds_opened,
  round(100.0 * purchases / nullif(finds, 0), 1) as pct_finds_bought,
  round(100.0 * passed    / nullif(finds, 0), 1) as pct_finds_passed
from c
order by finds desc;

-- 4. Agent hit rate by mission: how good each kind of agent is at picking things people want.
create or replace view metrics.agent_hit_rate as
with f as (
  select props->>'mission' as mission,
         count(*)                                                   as finds,
         round(avg((props->>'score')::numeric), 1)                  as avg_match_score,
         count(*) filter (where (props->>'fromLearning')::boolean)  as finds_from_learning,
         count(*) filter (where (props->>'background')::boolean)    as found_in_background
  from public.events where name = 'find_created' group by 1
), b as (
  select props->>'category' as mission, count(*) as purchases
  from public.events where name in ('purchase_confirmed','auto_purchased') group by 1
), p as (
  select props->>'category' as mission, count(*) as passes
  from public.events where name = 'find_passed' group by 1
)
select f.*, coalesce(b.purchases, 0) as purchases, coalesce(p.passes, 0) as passes,
       round(100.0 * coalesce(b.purchases, 0) / nullif(f.finds, 0), 1) as hit_rate_pct
from f
left join b using (mission)
left join p using (mission)
order by f.finds desc;

-- 5. Why people pass on finds (feeds the learning model).
create or replace view metrics.pass_reasons as
select props->>'category' as category, props->>'reason' as reason, count(*) as passes
from public.events
where name = 'find_passed'
group by 1, 2
order by 1, passes desc;

-- 6. Notification engagement by kind and texting style.
create or replace view metrics.notification_engagement as
with s as (
  select props->>'kind' as kind, count(*) as sent,
         count(*) filter (where (props->>'heldForMorning')::boolean) as held_for_morning
  from public.events where name = 'notification_sent' group by 1
), o as (
  select props->>'kind' as kind, count(*) as opened
  from public.events where name = 'notification_opened' group by 1
)
select s.kind, s.sent, s.held_for_morning, coalesce(o.opened, 0) as opened,
       round(100.0 * coalesce(o.opened, 0) / nullif(s.sent, 0), 1) as open_rate_pct
from s left join o using (kind)
order by s.sent desc;

create or replace view metrics.notification_by_voice as
select props->>'voice' as voice, count(*) as sent
from public.events where name = 'notification_sent'
group by 1 order by 2 desc;

-- 7. Friends: invites, shares, suggestions and how often suggestions get taken.
create or replace view metrics.friend_activity as
select
  date_trunc('week', occurred_at)::date                     as week,
  count(*) filter (where name = 'friend_invited')           as invites,
  count(*) filter (where name = 'item_shared')              as shares,
  count(*) filter (where name = 'suggestion_sent')          as suggestions_sent,
  count(*) filter (where name = 'suggestion_accepted')      as suggestions_accepted,
  count(*) filter (where name = 'suggestion_passed')        as suggestions_passed,
  round(100.0 * count(*) filter (where name = 'suggestion_accepted')
        / nullif(count(*) filter (where name in ('suggestion_accepted','suggestion_passed')), 0), 1) as acceptance_pct
from public.events
where name in ('friend_invited','item_shared','suggestion_sent','suggestion_accepted','suggestion_passed')
group by 1
order by 1 desc;

-- 8. Daily active installs and sessions.
create or replace view metrics.daily_active as
select
  date_trunc('day', occurred_at)::date as day,
  count(distinct install_id)           as active_installs,
  count(distinct session_id)           as sessions,
  count(*)                             as events
from public.events
group by 1
order by 1 desc;

-- 9. Squad setup: what people deploy agents for, and how they configure them.
create or replace view metrics.agents_deployed as
select
  props->>'mission'                          as mission,
  count(*)                                   as deployed,
  round(avg((props->>'intel')::numeric), 1)  as avg_taste_profile_pct,
  count(*) filter (where props->>'mode' = 'auto')  as auto_buy,
  count(*) filter (where props->>'mode' = 'ask')   as ask_first,
  count(*) filter (where props->>'mode' = 'alert') as alert_only
from public.events
where name = 'agent_deployed'
group by 1
order by deployed desc;

-- 10. Taste photos: how many people teach agents with pictures, and how much each photo teaches.
create or replace view metrics.taste_photos as
select
  props->>'mission'                            as mission,
  count(*)                                     as photos_added,
  count(distinct install_id)                   as installs,
  round(avg((props->>'tags')::numeric), 1)     as avg_tags_kept
from public.events
where name = 'taste_photo_added'
group by 1
order by photos_added desc;

-- 11. Which Live sections people actually use.
create or replace view metrics.live_sections as
select props->>'section' as section, count(*) as views, count(distinct install_id) as installs
from public.events
where name = 'live_section_viewed'
group by 1
order by views desc;

revoke all on all tables in schema metrics from anon, authenticated;
