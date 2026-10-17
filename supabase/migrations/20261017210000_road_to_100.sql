-- Road to 100: the numbers investors ask about, for the owner's Stats screen.
--   users / goal     progress toward the first 100 people
--   week_pace        sign-ups in the last 7 days, to estimate when 100 lands
--   week4            installs still opening Baget 4 weeks after their first day (out of week4_base)
--   pro / paid_base  people paying for Pro now, out of everyone who isn't comped
--   with_friends     people connected to at least one friend in the app
--   feedback         notes sent from the in-app feedback form
-- Admins only, like admin_stats().

create or replace function public.road_to_100()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  demo constant uuid := '0a99e1e0-5eed-4d3e-8a00-00000000d3e0';
  result jsonb;
begin
  if not exists (select 1 from public.app_admins where user_id = auth.uid()) then
    raise exception 'not allowed' using errcode = '42501';
  end if;

  with
  people as (select id, created_at, plan, pro_until from public.profiles where id <> demo),
  installs as (select install_id, min(occurred_at) first_seen, max(occurred_at) last_seen from public.events group by install_id)
  select jsonb_build_object(
    'goal',        100,
    'users',       (select count(*) from people),
    'week_pace',   (select count(*) from people where created_at > now() - interval '7 days'),
    'week4_base',  (select count(*) from installs where first_seen < now() - interval '28 days'),
    'week4',       (select count(*) from installs where first_seen < now() - interval '28 days' and last_seen > first_seen + interval '28 days'),
    'pro',         (select count(*) from people where plan = 'pro' and pro_until > now()),
    'paid_base',   (select count(*) from people where plan <> 'comp'),
    'with_friends',(select count(distinct u) from (
                      select requester u from public.friendships where status = 'accepted'
                      union all
                      select addressee from public.friendships where status = 'accepted') f
                    where u <> demo),
    'feedback',    (select count(*) from public.feedback)
  ) into result;
  return result;
end $$;
revoke all on function public.road_to_100() from public, anon;
grant execute on function public.road_to_100() to authenticated;
