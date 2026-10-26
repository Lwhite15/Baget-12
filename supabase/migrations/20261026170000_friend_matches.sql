-- Taste match % for every friend at once (the Friends tab shows it under each friend). Same math as friend_profile's
-- match; only for friends where both of you share your taste.
create or replace function public.friend_matches()
returns table (friend_id uuid, match int) language sql stable security definer set search_path = public as $$
  with me as (select auth.uid() as id),
  pals as (
    select p.id from public.friendships f
      join public.profiles p on p.id = case when f.requester = (select id from me) then f.addressee else f.requester end
     where (select id from me) in (f.requester, f.addressee) and f.status = 'accepted' and p.share_taste
       and (select share_taste from public.profiles where id = (select id from me))
  )
  select pals.id, (
    with
    a as (select f, least(w, 6.0) as w from public.taste_features((select id from me)) where w > 0.5 and (f like 'b:%' or f like 't:%' or f like 'c:%')),
    b as (select f, least(w, 6.0) as w from public.taste_features(pals.id) where w > 0.5 and (f like 'b:%' or f like 't:%' or f like 'c:%')),
    j as (select coalesce(a.f, b.f) as f, coalesce(a.w, 0) as mw, coalesce(b.w, 0) as tw from a full join b on a.f = b.f),
    sim as (select case when sqrt(sum(mw * mw)) * sqrt(sum(tw * tw)) = 0 then 0
                        else sum(mw * tw) / (sqrt(sum(mw * mw)) * sqrt(sum(tw * tw))) end as s from j where f not like 'c:%'),
    cats as (select (select count(*) from j where f like 'c:%' and mw > 0 and tw > 0) as shared,
                    (select count(*) from j where f like 'c:%' and (mw > 0 or tw > 0)) as total)
    select least(99, greatest(5, round(100 * (0.8 * sqrt(coalesce(sim.s, 0))
             + 0.2 * case when cats.total = 0 then 0 else cats.shared::numeric / cats.total end))))::int from sim, cats
  ) from pals
$$;
revoke all on function public.friend_matches() from public, anon;
grant execute on function public.friend_matches() to authenticated;
